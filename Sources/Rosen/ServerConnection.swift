import Foundation
import RosenCore

/// Uma sessão interativa aberta num terminal externo. O Rosen não vê a saída do ssh:
/// só prepara o script, responde aos pedidos do askpass e limpa o diretório temporário depois.
@MainActor
final class ServerConnection {
    enum LaunchError: LocalizedError {
        case problem(String)
        case unlockCancelled

        var errorDescription: String? {
            switch self {
            case .problem(let message): return message
            case .unlockCancelled: return "Desbloqueio cancelado. A sessão não foi aberta."
            }
        }
    }

    /// Quanto tempo o Rosen fica escutando o askpass depois da última atividade.
    static let listenWindow: Duration = .seconds(120)
    /// A chave temporária some este tempo depois do último pedido respondido (ou da abertura).
    static let keyLifetime: Duration = .seconds(20)
    /// Sem novo pedido nesse intervalo, consideramos que o servidor aceitou o segredo digitado.
    static let acceptanceDelay: Duration = .seconds(6)

    let id = UUID()
    let serverID: UUID

    var askpassPath = ""
    var resolve: () -> (Server, Credential?)? = { nil }
    var authorize: (Server, Credential) async -> Bool = { _, _ in true }
    var requestInput: (TunnelSession.InputRequest, @escaping (TunnelSession.InputResponse) -> Void) -> Void = { _, done in done(.cancel) }
    var dismissInput: (UUID) -> Void = { _ in }
    var saveTarget: (Server, AskpassPrompt) -> String? = { _, _ in nil }
    var rememberSecret: (Server, AskpassPrompt, String, Bool) -> Void = { _, _, _, _ in }
    /// Chamado quando a conexão terminou o trabalho dela (limpeza feita).
    var onFinish: (ServerConnection) -> Void = { _ in }

    private var workspace: ConnectionWorkspace?
    private var broker: AskpassBroker?
    private var tempKey: URL?
    private var credential: Credential?
    private var usedStoredSecret = false
    private var promptCount = 0
    private var lastKind: AskpassPrompt?
    private var openInputID: UUID?
    private var pendingSave: (Server, AskpassPrompt, String, Bool)?
    private var saveTask: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var finished = false

    init(serverID: UUID) { self.serverID = serverID }

    /// Prepara tudo e abre o terminal. Erros já vêm em português para mostrar ao usuário.
    func start(in terminal: TerminalApp) async throws {
        guard let (server, credential) = resolve() else { throw LaunchError.problem("O servidor foi removido.") }
        if server.host.trimmingCharacters(in: .whitespaces).isEmpty { throw LaunchError.problem("Defina o host do servidor.") }
        if let problem = credential?.problem { throw LaunchError.problem(problem) }
        guard terminal.isInstalled else { throw TerminalLaunchError.notInstalled(terminal) }

        if let credential, credential.needsUnlock {
            guard await authorize(server, credential) else { throw LaunchError.unlockCancelled }
        }
        self.credential = credential

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

            // Com ssh-agent (ou sem credencial) o ssh pergunta no próprio terminal, como de costume.
            var environment: [String: String] = [:]
            if let credential, credential.kind != .agent {
                let b = try AskpassBroker(in: ws) { [weak self] prompt, reply in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { reply(nil); return }
                            self.answer(prompt: prompt, reply: reply)
                        }
                    }
                }
                b.start()
                broker = b
                environment = ConnectScript.askpassEnvironment(askpassPath: askpassPath, broker: b.environment)
            }

            let script = ConnectScript.make(title: server.displayName,
                                            arguments: SSHCommand.interactiveArguments(for: server, auth: auth),
                                            environment: environment)
            let url = try ConnectScript.write(script, in: ws)
            try await terminal.launcher.launch(script: url)
        } catch {
            finish()
            throw error
        }

        scheduleKeyRemoval()
        scheduleIdle()
    }

    // MARK: - Pedidos do ssh

    private func answer(prompt: String, reply: @escaping @Sendable (String?) -> Void) {
        guard !finished, let (server, _) = resolve() else { reply(nil); return }
        var kind = AskpassPrompt.classify(prompt)
        if case .passphrase = kind, credential?.kind == .keyContent { kind = .passphrase(keyPath: nil) }

        // O pedido anterior foi aceito ou recusado? Decide o destino do segredo digitado.
        if let previous = lastKind {
            saveTask?.cancel()
            if let save = pendingSave {
                pendingSave = nil
                if AskpassPrompt.previousWasAccepted(previous: previous, next: kind) { rememberSecret(save.0, save.1, save.2, save.3) }
            }
        }
        lastKind = kind
        promptCount += 1
        keyTask?.cancel()
        idleTask?.cancel()

        if !usedStoredSecret, let stored = storedSecret(for: kind) {
            usedStoredSecret = true
            reply(stored)
            afterAnswer()
            return
        }

        let request = TunnelSession.InputRequest(
            subject: PromptSubject(server), kind: kind, prompt: prompt,
            retry: promptCount > 1 && kind != .other,
            storedRejected: usedStoredSecret && promptCount == 2,
            saveTarget: kind == .other ? nil : saveTarget(server, kind),
            keyName: credential.flatMap { $0.kind == .keyFile || $0.kind == .keyContent ? $0.displayName : nil }
        )
        openInputID = request.id
        requestInput(request) { [weak self] response in
            guard let self, !self.finished else { reply(nil); return }
            self.openInputID = nil
            switch response {
            case .cancel:
                reply(nil)
            case .submit(let secret, let save, let protect):
                if save, request.saveTarget != nil {
                    self.pendingSave = (server, kind, secret, protect)
                    self.scheduleSave()
                }
                reply(secret)
            }
            self.afterAnswer()
        }
    }

    private func storedSecret(for kind: AskpassPrompt) -> String? {
        guard let c = credential else { return nil }
        let value: String
        switch (kind, c.kind) {
        case (.passphrase, .keyFile), (.passphrase, .keyContent): value = c.passphrase
        case (.password, .password): value = c.password
        default: return nil
        }
        return value.isEmpty ? nil : value
    }

    private func afterAnswer() {
        scheduleKeyRemoval()
        scheduleIdle()
    }

    // MARK: - Tempos

    /// Sem outro pedido logo em seguida, o servidor aceitou: guarda o segredo digitado.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.acceptanceDelay)
            guard let self, !Task.isCancelled, let save = self.pendingSave else { return }
            self.pendingSave = nil
            self.rememberSecret(save.0, save.1, save.2, save.3)
        }
    }

    private func scheduleKeyRemoval() {
        guard tempKey != nil else { return }
        keyTask?.cancel()
        keyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keyLifetime)
            guard let self, !Task.isCancelled, self.openInputID == nil, let key = self.tempKey else { return }
            self.workspace?.remove(key)
            self.tempKey = nil
        }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.listenWindow)
            guard let self, !Task.isCancelled, self.openInputID == nil else { return }
            self.finish()
        }
    }

    /// Para de escutar, apaga o diretório temporário (chave incluída) e avisa o dono.
    func finish() {
        guard !finished else { return }
        finished = true
        saveTask?.cancel(); keyTask?.cancel(); idleTask?.cancel()
        if let id = openInputID { openInputID = nil; dismissInput(id) }
        pendingSave = nil
        broker?.cancel(); broker = nil
        workspace?.destroy(); workspace = nil
        tempKey = nil
        onFinish(self)
    }
}
