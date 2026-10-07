import AppKit
import RosenCore
import Foundation
import Network
import Observation
import UserNotifications

struct EditorRequest: Identifiable {
    let id = UUID()
    var tunnel: Tunnel
    var isNew: Bool
    var pastedCommand: String = ""
}

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    enum LoadState: Equatable { case loading, ready, failed(String) }

    var tunnels: [Tunnel] = [] { didSet { syncSessions(); scheduleSave() } }
    var credentials: [Credential] = [] { didSet { scheduleSave() } }
    private(set) var sessions: [UUID: TunnelSession] = [:]
    private(set) var loadState: LoadState = .loading

    // Estado de UI compartilhado entre janela, menus e barra de menus.
    var selection: UUID?
    var editorRequest: EditorRequest?
    var pendingDeletion: Tunnel?
    var toast: String?

    @ObservationIgnored private let vault = Vault(url: Vault.defaultURL, keyProvider: KeychainKeyProvider())
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var askpassPath = ""
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var bootstrapped = false

    var vaultURL: URL { vault.url }

    // MARK: - Ciclo de vida

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            askpassPath = try Askpass.install(in: vault.url.deletingLastPathComponent()).path
        } catch {
            NSLog("Rosen: falha ao instalar askpass: \(error)")
        }
        load()
        observeSystem()
        Notifier.requestAuthorization()
        for t in tunnels where t.autoConnect { connect(t.id) }
    }

    func load() {
        loadState = .loading
        migrateFromBurrow()
        do {
            let payload = try vault.load() ?? VaultPayload()
            credentials = payload.credentials
            tunnels = payload.tunnels
            loadState = .ready
            if selection == nil { selection = tunnels.first?.id }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// O app se chamava Burrow. Traz cofre, chave e ajustes para o Rosen, uma única vez.
    private func migrateFromBurrow() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDir = support.appendingPathComponent("Burrow", isDirectory: true)
        let legacyKey = KeychainKeyProvider(service: "app.burrow.vault")
        let legacy = Vault(url: legacyDir.appendingPathComponent("vault.burrow"), keyProvider: legacyKey)
        guard legacy.exists, !vault.exists else { return }
        do {
            if let payload = try vault.migrate(from: legacy) {
                try? FileManager.default.removeItem(at: legacyDir)
                legacyKey.deleteKey()
                let n = payload.tunnels.count
                showToast("Trouxe \(n) túne\(n == 1 ? "l" : "is") do Burrow")
            }
        } catch {
            NSLog("Rosen: migração do Burrow falhou, cofre antigo mantido: \(error)")
        }
        // Ajustes
        if let old = UserDefaults(suiteName: "app.burrow.mac") {
            for key in ["showDockIcon", "notifyDrops", Unlocker.graceKey]
            where UserDefaults.standard.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
            }
        }
    }

    func shutdown() {
        saveTask?.cancel()
        if loadState == .ready { try? vault.save(payload) }
        sessions.values.forEach { $0.shutdown() }
    }

    private var payload: VaultPayload { VaultPayload(tunnels: tunnels, credentials: credentials) }

    private func scheduleSave() {
        guard loadState == .ready else { return }
        saveTask?.cancel()
        let snapshot = payload
        let vault = vault
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do { try vault.save(snapshot) } catch {
                await MainActor.run { AppStore.shared.showToast("Erro ao salvar: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Sessões

    func session(_ id: UUID) -> TunnelSession? { sessions[id] }

    private func syncSessions() {
        let ids = Set(tunnels.map(\.id))
        for (id, s) in sessions where !ids.contains(id) {
            s.shutdown()
            sessions.removeValue(forKey: id)
        }
        for t in tunnels where sessions[t.id] == nil {
            let s = TunnelSession(tunnelID: t.id)
            let id = t.id
            s.askpassPath = askpassPath
            s.resolve = { [weak self] in
                guard let self, let tunnel = self.tunnel(id) else { return nil }
                return (tunnel, tunnel.credentialID.flatMap(self.credential))
            }
            s.preflight = { [weak self] tunnel in self?.preflight(tunnel) }
            s.authorize = { tunnel, credential in
                await Unlocker.shared.authorize(
                    reason: "usar “\(credential.displayName)” para conectar “\(tunnel.displayName)”")
            }
            s.onEvent = { [weak self] session, event in self?.handle(event, from: session) }
            s.requestInput = { request, done in PromptPresenter.shared.present(request, completion: done) }
            s.dismissInput = { id in PromptPresenter.shared.dismiss(id) }
            s.saveTarget = { [weak self] tunnel, kind in self?.saveTarget(for: tunnel, kind: kind) }
            s.rememberSecret = { [weak self] tunnel, kind, secret, protect in
                self?.rememberSecret(secret, kind: kind, for: tunnel.id, protect: protect)
            }
            sessions[t.id] = s
        }
    }

    private func preflight(_ t: Tunnel) -> String? {
        if t.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Defina o host do servidor." }
        if let id = t.credentialID, credential(id) == nil { return "A credencial deste túnel foi removida. Edite o túnel e escolha outra." }
        guard t.kind != .remote else { return nil }
        if let other = tunnels.first(where: { $0.conflicts(with: t) && sessions[$0.id]?.isOn == true }) {
            return "A porta \(t.listenPort) já está sendo usada pelo túnel “\(other.displayName)”."
        }
        if let occupant = PortProbe.occupant(address: t.bindAddress, port: t.listenPort) {
            return "A porta \(t.listenPort) já está em uso por \(occupant). Escolha outra porta local."
        }
        return nil
    }

    private func handle(_ event: TunnelSession.Event, from session: TunnelSession) {
        guard let t = tunnel(session.tunnelID) else { return }
        let notify = UserDefaults.standard.object(forKey: "notifyDrops") as? Bool ?? true
        switch event {
        case .connected:
            break
        case .dropped(let reason):
            if notify { Notifier.post(title: "\(t.displayName) caiu", body: "\(reason) Reconectando…") }
        case .failed(let reason):
            if notify, !NSApp.isActive { Notifier.post(title: "\(t.displayName) não conectou", body: reason) }
        }
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Após acordar, as conexões TCP antigas costumam estar mortas.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { AppStore.shared.sessions.values.forEach { $0.restart() } }
                }
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppStore.shared.sessions.values.forEach { $0.retryNowIfWaiting() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "rosen.network"))
        pathMonitor = monitor
    }

    // MARK: - Consultas

    func tunnel(_ id: UUID) -> Tunnel? { tunnels.first { $0.id == id } }
    func credential(_ id: UUID) -> Credential? { credentials.first { $0.id == id } }

    var connectedCount: Int { sessions.values.filter { $0.status.isConnected }.count }
    var activeCount: Int { sessions.values.filter(\.isOn).count }

    func usage(of credentialID: UUID) -> [Tunnel] { tunnels.filter { $0.credentialID == credentialID } }

    func conflict(for draft: Tunnel) -> Tunnel? { tunnels.first { $0.conflicts(with: draft) } }

    /// Sugere uma porta local livre próxima da porta de destino (5432 → 5433).
    func suggestedListenPort(for targetPort: Int, excluding id: UUID?) -> Int {
        let used = Set(tunnels.filter { $0.id != id && $0.kind != .remote }.map(\.listenPort))
        var candidate = targetPort < 1024 ? targetPort + 10000 : targetPort + 1
        if candidate > 65535 { candidate = 10000 }
        for _ in 0..<200 {
            if !used.contains(candidate), PortProbe.isFree(candidate) { return candidate }
            candidate = candidate >= 65535 ? 10000 : candidate + 1
        }
        return candidate
    }

    // MARK: - Ações de túnel

    func connect(_ id: UUID) { sessions[id]?.connect() }
    func disconnect(_ id: UUID) { sessions[id]?.disconnect() }
    func toggle(_ id: UUID) { sessions[id]?.toggle() }

    func connectAll() { tunnels.forEach { if sessions[$0.id]?.isOn == false { connect($0.id) } } }
    func disconnectAll() { sessions.values.forEach { if $0.isOn { $0.disconnect() } } }

    func newTunnel(prefill: String = "") {
        var t = Tunnel(tag: TagColor.allCases[tunnels.count % (TagColor.allCases.count - 1)])
        t.listenPort = suggestedListenPort(for: t.targetPort, excluding: nil)
        editorRequest = EditorRequest(tunnel: t, isNew: true, pastedCommand: prefill)
    }

    func newTunnelFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if SSHCommandParser.parse(text) != nil {
            newTunnel(prefill: text)
        } else {
            newTunnel()
            showToast("O clipboard não tem um comando ssh — preencha manualmente.")
        }
    }

    var clipboardHasSSHCommand: Bool {
        SSHCommandParser.parse(NSPasteboard.general.string(forType: .string) ?? "")?.hasForward == true
    }

    func edit(_ id: UUID) {
        guard let t = tunnel(id) else { return }
        editorRequest = EditorRequest(tunnel: t, isNew: false)
    }

    func save(_ tunnel: Tunnel, connectAfter: Bool) {
        if let i = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            let changed = tunnels[i] != tunnel
            tunnels[i] = tunnel
            if changed, sessions[tunnel.id]?.isOn == true { sessions[tunnel.id]?.restart() }
        } else {
            tunnels.append(tunnel)
        }
        selection = tunnel.id
        if connectAfter, sessions[tunnel.id]?.isOn == false { connect(tunnel.id) }
    }

    func duplicate(_ id: UUID) {
        guard var copy = tunnel(id) else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " (cópia)"
        copy.createdAt = Date()
        copy.listenPort = suggestedListenPort(for: copy.listenPort - 1, excluding: copy.id)
        copy.autoConnect = false
        if let i = tunnels.firstIndex(where: { $0.id == id }) { tunnels.insert(copy, at: i + 1) } else { tunnels.append(copy) }
        selection = copy.id
    }

    func requestDelete(_ id: UUID) { pendingDeletion = tunnel(id) }

    func delete(_ id: UUID) {
        guard let i = tunnels.firstIndex(where: { $0.id == id }) else { return }
        sessions[id]?.shutdown()
        tunnels.remove(at: i)
        if selection == id { selection = tunnels.indices.contains(i) ? tunnels[i].id : tunnels.last?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        tunnels.move(fromOffsets: source, toOffset: destination)
    }

    func copyCommand(_ id: UUID) {
        guard let t = tunnel(id) else { return }
        copy(SSHCommand.displayString(for: t, credential: t.credentialID.flatMap(credential)), message: "Comando copiado")
    }

    func copyAddress(_ id: UUID) {
        guard let t = tunnel(id) else { return }
        copy(t.kind == .remote ? t.targetAddress : t.clientAddress, message: "Endereço copiado")
    }

    func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("\(message): \(text)")
    }

    // MARK: - Credenciais

    @discardableResult
    func upsert(_ credential: Credential) -> UUID {
        if let i = credentials.firstIndex(where: { $0.id == credential.id }) {
            if credentials[i] != credential { credentials[i] = credential }
        } else {
            credentials.append(credential)
        }
        return credential.id
    }

    func deleteCredential(_ id: UUID) {
        for i in tunnels.indices where tunnels[i].credentialID == id { tunnels[i].credentialID = nil }
        credentials.removeAll { $0.id == id }
    }

    /// Encontra (ou cria) a credencial para um `-i caminho` vindo de um comando colado.
    func credentialID(forIdentityFile path: String) -> UUID {
        if let existing = existingCredentialID(forIdentityFile: path) { return existing }
        let expanded = Paths.expand(path)
        let c = Credential(name: (path as NSString).lastPathComponent, kind: .keyFile, keyPath: Paths.abbreviate(expanded),
                           requireUserPresence: true)
        return upsert(c)
    }

    func existingCredentialID(forIdentityFile path: String) -> UUID? {
        let expanded = Paths.expand(path)
        return credentials.first { $0.kind == .keyFile && Paths.expand($0.keyPath) == expanded }?.id
    }

    // MARK: - Segredos digitados na hora

    /// Descrição de onde o segredo seria salvo, ou `nil` se não houver lugar sensato.
    func saveTarget(for tunnel: Tunnel, kind: AskpassPrompt) -> String? {
        let current = tunnel.credentialID.flatMap(credential)
        switch kind {
        case .other:
            return nil
        case .password:
            if let c = current, c.kind == .password { return "na credencial “\(c.displayName)”" }
            if let c = current, c.kind == .keyFile || c.kind == .keyContent { return nil } // não troca a chave por senha
            return "como a credencial “Senha de \(tunnel.destination)”"
        case .passphrase(let keyPath):
            if let c = current, c.kind == .keyFile || c.kind == .keyContent { return "na credencial “\(c.displayName)”" }
            guard let keyPath else { return nil }
            return "como a credencial “\((keyPath as NSString).lastPathComponent)”"
        }
    }

    /// Guarda o segredo que o usuário digitou (chamado só depois que o servidor aceitou).
    func rememberSecret(_ secret: String, kind: AskpassPrompt, for tunnelID: UUID, protect: Bool) {
        guard let tunnel = tunnel(tunnelID) else { return }
        var target: Credential
        if let c = tunnel.credentialID.flatMap(credential), saveTarget(for: tunnel, kind: kind)?.hasPrefix("na credencial") == true {
            target = c
        } else {
            switch kind {
            case .password:
                target = Credential(name: "Senha de \(tunnel.destination)", kind: .password)
            case .passphrase(let keyPath?):
                let id = credentialID(forIdentityFile: keyPath)
                target = credential(id) ?? Credential(kind: .keyFile, keyPath: Paths.abbreviate(keyPath))
            default:
                return
            }
        }
        switch kind {
        case .password: target.password = secret
        case .passphrase: target.passphrase = secret
        case .other: return
        }
        target.requireUserPresence = protect
        upsert(target)
        // Liga a credencial ao túnel sem reiniciar a conexão que acabou de autenticar.
        if let i = tunnels.firstIndex(where: { $0.id == tunnelID }), tunnels[i].credentialID != target.id {
            tunnels[i].credentialID = target.id
        }
        showToast(protect ? "Salvo no cofre, protegido por \(Unlocker.methodName)" : "Salvo no cofre")
    }

    // MARK: - Toast

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

// MARK: - Notificações

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
