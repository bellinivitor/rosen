import RosenCore
import Foundation
import Observation

/// Um processo `ssh -N` vivo, com estado, logs e reconexão automática.
@MainActor
@Observable
final class TunnelSession {
    enum Status: Equatable {
        case idle
        /// Esperando Touch ID / senha do Mac para liberar a credencial.
        case unlocking
        /// O ssh pediu algo (senha, passphrase, código) e estamos esperando o usuário.
        case prompting
        case connecting
        case connected(since: Date)
        case waiting(retryAt: Date, attempt: Int, reason: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
        var isBusy: Bool {
            switch self {
            case .unlocking, .prompting, .connecting, .waiting: return true
            default: return false
            }
        }
    }

    struct LogEntry: Identifiable, Equatable {
        enum Level { case info, success, warning, error }
        let id = UUID()
        let date = Date()
        let level: Level
        let text: String
    }

    enum Event { case connected, dropped(String), failed(String) }

    /// Pedido do ssh que precisa de resposta do usuário.
    struct InputRequest: Identifiable {
        let id = UUID()
        let subject: PromptSubject
        let kind: AskpassPrompt
        /// Texto original do ssh, ex.: "(ana@host) Password:".
        let prompt: String
        /// A tentativa anterior foi recusada.
        let retry: Bool
        /// O que foi recusado era o segredo salvo no cofre.
        let storedRejected: Bool
        /// Onde o segredo seria salvo; `nil` = não oferecer salvar.
        let saveTarget: String?
        /// Nome da credencial de chave em uso, se houver.
        let keyName: String?
    }

    enum InputResponse {
        case cancel
        case submit(secret: String, save: Bool, protect: Bool)
    }

    let tunnelID: UUID
    private(set) var status: Status = .idle
    /// O usuário quer este túnel ligado.
    private(set) var isOn = false
    private(set) var logs: [LogEntry] = []

    /// Últimas medições de latência até o servidor (ms; `nil` = sem resposta). Só com túnel conectado.
    private(set) var latencySamples: [Double?] = []
    /// Dá para medir? Não, com bastion no meio ou quando o servidor ignora ping.
    private(set) var latencyAvailable = true
    var latency: Double? { Latency.smoothed(latencySamples) }

    @ObservationIgnored var resolve: () -> (Tunnel, Credential?)? = { nil }
    @ObservationIgnored var preflight: (Tunnel) -> String? = { _ in nil }
    /// Libera a credencial (Touch ID). Só é chamado quando ela exige presença do usuário.
    @ObservationIgnored var authorize: (Tunnel, Credential) async -> Bool = { _, _ in true }
    @ObservationIgnored var onEvent: (TunnelSession, Event) -> Void = { _, _ in }
    /// Mostra o pedido ao usuário (modal). A resposta volta pelo completion.
    @ObservationIgnored var requestInput: (InputRequest, @escaping (InputResponse) -> Void) -> Void = { _, done in done(.cancel) }
    /// Fecha um pedido que deixou de fazer sentido (conexão encerrada).
    @ObservationIgnored var dismissInput: (UUID) -> Void = { _ in }
    /// Onde salvar o segredo digitado (descrição), ou `nil` se não houver um lugar sensato.
    @ObservationIgnored var saveTarget: (Tunnel, AskpassPrompt) -> String? = { _, _ in nil }
    /// Salva no cofre o que o usuário digitou, depois que o servidor aceitou.
    @ObservationIgnored var rememberSecret: (Tunnel, AskpassPrompt, String, Bool) -> Void = { _, _, _, _ in }
    @ObservationIgnored var askpassPath = ""

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var workspace: ConnectionWorkspace?
    @ObservationIgnored private var broker: AskpassBroker?
    @ObservationIgnored private var launchCredential: Credential?
    @ObservationIgnored private var usedStoredSecret = false
    @ObservationIgnored private var promptCount = 0
    @ObservationIgnored private var userCancelledPrompt = false
    @ObservationIgnored private var openInputID: UUID?
    @ObservationIgnored private var pendingSave: (Tunnel, AskpassPrompt, String, Bool)?
    @ObservationIgnored private var tempKey: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    @ObservationIgnored private var fatalMessage: String?
    @ObservationIgnored private var lastTransient: String?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var currentKind: ForwardKind = .local
    @ObservationIgnored private var latencyTask: Task<Void, Never>?

    init(tunnelID: UUID) { self.tunnelID = tunnelID }

    // MARK: - Controle

    func connect() {
        isOn = true
        attempt = 0
        retryTask?.cancel()

        // Credencial protegida: só entrega o segredo ao ssh depois do Touch ID.
        // Reconexões automáticas de um túnel já liberado não pedem de novo.
        if let (tunnel, credential) = resolve(), let credential, credential.needsUnlock {
            status = .unlocking
            retryTask = Task { [weak self] in
                guard let self else { return }
                let ok = await self.authorize(tunnel, credential)
                guard !Task.isCancelled, self.isOn else { return }
                if ok {
                    self.launch()
                } else {
                    self.isOn = false
                    self.status = .idle
                    self.log(.warning, "Desbloqueio cancelado. O túnel não foi conectado.")
                }
            }
            return
        }
        launch()
    }

    func disconnect() {
        let wasActive = isOn || process != nil
        isOn = false
        retryTask?.cancel()
        terminate()
        status = .idle
        if wasActive { log(.info, "Desconectado.") }
    }

    func toggle() { isOn ? disconnect() : connect() }

    /// Reinicia já (ex.: config editada, Mac acordou).
    func restart() {
        guard isOn else { return }
        retryTask?.cancel()
        terminate()
        status = .connecting
        // Dá tempo do processo antigo liberar a porta.
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, self.isOn else { return }
            self.launch()
        }
    }

    /// Se estiver esperando para reconectar, tenta agora.
    func retryNowIfWaiting() {
        guard isOn, case .waiting = status else { return }
        retryTask?.cancel()
        launch()
    }

    func clearLogs() { logs.removeAll() }

    /// Registra no log um aviso que veio de fora da sessão (ex.: conexão antiga substituída).
    func note(_ text: String) { log(.warning, text) }

    // MARK: - Processo

    private func launch() {
        guard let (tunnel, credential) = resolve() else { return }
        terminate()
        fatalMessage = nil
        lastTransient = nil
        currentKind = tunnel.kind
        status = .connecting

        if let problem = preflight(tunnel) ?? credential?.problem {
            fail(problem)
            return
        }

        do {
            let ws = try ConnectionWorkspace()
            workspace = ws
            var auth = AuthMaterial.system

            switch credential?.kind {
            case .keyFile?:
                auth = .identityFile(Paths.expand(credential!.keyPath))
            case .keyContent?:
                let file = try ws.writeKey(credential!.keyContent)
                tempKey = file
                auth = .identityFile(file.path)
            case .password?:
                auth = .password
            case .agent?, nil:
                break
            }

            generation += 1
            let gen = generation
            launchCredential = credential
            usedStoredSecret = false
            promptCount = 0
            userCancelledPrompt = false
            pendingSave = nil

            // Todo pedido do ssh (senha, passphrase, 2FA) passa pelo app.
            let b = try AskpassBroker(in: ws) { [weak self] prompt, reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { reply(nil); return }
                        self.answer(prompt: prompt, generation: gen, reply: reply)
                    }
                }
            }
            b.start()
            broker = b

            var env = ProcessInfo.processInfo.environment
            // O app herda o PATH mínimo do launchd: sem isto um ProxyCommand do ~/.ssh/config
            // (cloudflared, nc, um bastion) não é encontrado.
            env["PATH"] = UserPath.augmented(env["PATH"])
            env["SSH_ASKPASS"] = askpassPath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[SSHCommand.tunnelMarker] = tunnelID.uuidString
            for (key, value) in b.environment { env[key] = value }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: SSHCommand.executable)
            p.arguments = SSHCommand.arguments(for: tunnel, auth: auth)
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.consume(data, generation: gen) }
                }
            }
            p.terminationHandler = { [weak self] proc in
                let code = proc.terminationStatus
                // Pequeno atraso para o último pedaço do stderr chegar antes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { self?.handleExit(code: code, generation: gen) }
                }
            }

            try p.run()
            process = p
            log(.info, attempt == 0 ? "Conectando a \(tunnel.destination)…" : "Tentando novamente (tentativa \(attempt + 1))…")
        } catch {
            cleanup()
            fail("Não foi possível iniciar o ssh: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: String(decoding: lineData, as: UTF8.self))
        }
    }

    private func handle(line: String) {
        switch SSHLog.classify(line) {
        case .noise:
            break
        case .authenticated:
            log(.info, "Autenticado.")
            if let key = tempKey { workspace?.remove(key); tempKey = nil } // a chave já foi lida
            if let save = pendingSave {
                pendingSave = nil
                rememberSecret(save.0, save.1, save.2, save.3)
            }
            // Fallback caso a linha de "listening" não apareça.
            readyTask?.cancel()
            readyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled, self.status == .connecting, self.process?.isRunning == true else { return }
                self.markConnected()
            }
        case .forwardReady:
            if status == .connecting { markConnected() }
        case .fatal(let message):
            if fatalMessage == nil { fatalMessage = message; log(.error, message) }
        case .transient(let message):
            if lastTransient != message { log(.warning, message) }
            lastTransient = message
        case .warning(let message):
            log(.warning, message)
        case .info(let message):
            log(.info, message)
        }
    }

    // MARK: - Pedidos do ssh

    private func answer(prompt: String, generation gen: Int, reply: @escaping @Sendable (String?) -> Void) {
        guard gen == generation, isOn, let (tunnel, _) = resolve() else { reply(nil); return }
        var kind = AskpassPrompt.classify(prompt)
        // Chave do cofre: o ssh cita o arquivo temporário; para o usuário vale o nome da credencial.
        if case .passphrase = kind, let c = launchCredential, c.kind == .keyContent {
            kind = .passphrase(keyPath: nil)
        }
        promptCount += 1

        // 1) Segredo guardado no cofre: usa uma vez por tentativa de conexão.
        if !usedStoredSecret, let stored = storedSecret(for: kind) {
            usedStoredSecret = true
            reply(stored)
            return
        }

        // 2) Pergunta ao usuário.
        let request = InputRequest(
            subject: PromptSubject(tunnel), kind: kind, prompt: prompt,
            retry: promptCount > 1,
            storedRejected: usedStoredSecret && promptCount == 2,
            saveTarget: kind == .other ? nil : saveTarget(tunnel, kind),
            keyName: launchCredential.flatMap { $0.kind == .keyFile || $0.kind == .keyContent ? $0.displayName : nil }
        )
        openInputID = request.id
        status = .prompting
        switch kind {
        case .password: log(.info, "O servidor pediu a senha.")
        case .passphrase: log(.info, "A chave pediu a passphrase.")
        case .other: log(.info, "O servidor pediu: \(prompt)")
        }

        requestInput(request) { [weak self] response in
            guard let self, gen == self.generation else { reply(nil); return }
            self.openInputID = nil
            if self.status == .prompting { self.status = .connecting }
            switch response {
            case .cancel:
                self.userCancelledPrompt = true
                reply(nil)
            case .submit(let secret, let save, let protect):
                if save, request.saveTarget != nil { self.pendingSave = (tunnel, kind, secret, protect) }
                reply(secret)
            }
        }
    }

    private func storedSecret(for kind: AskpassPrompt) -> String? {
        guard let c = launchCredential else { return nil }
        let value: String
        switch (kind, c.kind) {
        case (.passphrase, .keyFile), (.passphrase, .keyContent): value = c.passphrase
        case (.password, .password): value = c.password
        default: return nil
        }
        return value.isEmpty ? nil : value
    }

    private func markConnected() {
        readyTask?.cancel()
        attempt = 0
        status = .connected(since: Date())
        log(.success, "Túnel ativo.")
        if let (tunnel, _) = resolve() { startLatency(for: tunnel) }
        onEvent(self, .connected)
    }

    private func handleExit(code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        let wasConnected = status.isConnected
        process = nil
        cleanup()

        guard isOn else { status = .idle; return }

        if userCancelledPrompt {
            isOn = false
            retryTask?.cancel()
            status = .idle
            log(.warning, "Conexão cancelada: o pedido do servidor ficou sem resposta.")
            return
        }

        if let fatal = fatalMessage {
            fail(fatal)
            return
        }

        let reason = lastTransient ?? (wasConnected ? "A conexão foi encerrada." : "O ssh encerrou com código \(code).")
        if wasConnected { log(.warning, reason) }

        guard let (tunnel, _) = resolve(), tunnel.autoReconnect else {
            fail(reason)
            return
        }

        attempt += 1
        let delay = min(30.0, pow(2.0, Double(attempt - 1)))
        let retryAt = Date().addingTimeInterval(delay)
        status = .waiting(retryAt: retryAt, attempt: attempt, reason: reason)
        if wasConnected { onEvent(self, .dropped(reason)) }

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isOn else { return }
            self.launch()
        }
    }

    private func fail(_ message: String) {
        isOn = false
        retryTask?.cancel()
        status = .failed(message)
        if logs.last?.text != message { log(.error, message) }
        onEvent(self, .failed(message))
    }

    private func terminate() {
        generation += 1
        readyTask?.cancel()
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        process = nil
        cleanup()
    }

    // MARK: - Latência

    private func startLatency(for tunnel: Tunnel) {
        latencyTask?.cancel()
        latencySamples = []
        latencyAvailable = true
        latencyTask = Task { [weak self] in
            guard let target = await Self.resolveTarget(tunnel) else { return }
            guard let self, !Task.isCancelled else { return }
            if target.viaProxy {
                self.latencyAvailable = false // o ping mediria só até o bastion
                return
            }
            var failures = 0
            while !Task.isCancelled {
                let ms = await Self.ping(target.host)
                guard !Task.isCancelled else { return }
                self.latencySamples.append(ms)
                if self.latencySamples.count > 30 { self.latencySamples.removeFirst() }
                failures = ms == nil ? failures + 1 : 0
                self.latencyAvailable = failures < 3
                // Servidor que não responde a ping: tenta bem menos.
                try? await Task.sleep(for: .seconds(failures >= 3 ? 30 : 5))
            }
        }
    }

    private func stopLatency() {
        latencyTask?.cancel()
        latencyTask = nil
        latencySamples = []
        latencyAvailable = true
    }

    nonisolated static func resolveTarget(_ tunnel: Tunnel) async -> Latency.Target? {
        await Task.detached(priority: .utility) {
            let out = run("/usr/bin/ssh", Latency.sshConfigArguments(for: tunnel))
            return out.flatMap(Latency.target(fromSSHConfig:))
        }.value
    }

    nonisolated static func ping(_ host: String) async -> Double? {
        await Task.detached(priority: .utility) {
            run("/sbin/ping", Latency.pingArguments(host: host)).flatMap(Latency.milliseconds(fromPing:))
        }.value
    }

    /// Roda um comando curto e devolve a saída padrão.
    private nonisolated static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func cleanup() {
        stopLatency()
        broker?.cancel(); broker = nil
        if let id = openInputID { openInputID = nil; dismissInput(id) }
        pendingSave = nil
        workspace?.destroy(); workspace = nil
        tempKey = nil
        buffer.removeAll()
    }

    /// Encerramento síncrono ao sair do app.
    func shutdown() {
        isOn = false
        retryTask?.cancel()
        terminate()
    }

    private func log(_ level: LogEntry.Level, _ text: String) {
        logs.append(LogEntry(level: level, text: text))
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}

#if SNAPSHOT
extension TunnelSession {
    /// Só para o gerador de capturas (Scripts/build.sh snapshot).
    func setSnapshotState(_ status: Status, logs: [(LogEntry.Level, String)], latency: [Double?] = []) {
        self.status = status
        self.latencySamples = latency
        self.isOn = status != .idle && !{ if case .failed = status { return true }; return false }()
        self.logs = logs.map { LogEntry(level: $0.0, text: $0.1) }
    }
}
#endif
