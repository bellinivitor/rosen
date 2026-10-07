import AppKit
import RosenCore
import Foundation
import Network
import Observation
import UserNotifications

struct ServerEditorRequest: Identifiable {
    let id = UUID()
    var server: Server
    var isNew: Bool
}

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
    var servers: [Server] = [] { didSet { scheduleSave() } }
    private(set) var sessions: [UUID: TunnelSession] = [:]
    /// Sessões de servidor ainda escutando o askpass (por id da conexão).
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    /// Servidores com o terminal sendo aberto agora (Touch ID, preparação).
    private(set) var openingServers: Set<UUID> = []
    private(set) var loadState: LoadState = .loading

    // Estado de UI compartilhado entre janela, menus e barra de menus.
    var selection: UUID?
    var editorRequest: EditorRequest?
    var serverEditorRequest: ServerEditorRequest?
    var pendingDeletion: Tunnel?
    var pendingServerDeletion: Server?
    var showingSSHConfigImport = false
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
            servers = payload.servers
            loadState = .ready
            if selection == nil { selection = tunnels.first?.id ?? servers.first?.id }
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
        connections.values.forEach { $0.finish() }
    }

    private var payload: VaultPayload { VaultPayload(tunnels: tunnels, credentials: credentials, servers: servers) }

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
    func serverUsage(of credentialID: UUID) -> [Server] { servers.filter { $0.credentialID == credentialID } }

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
        for i in servers.indices where servers[i].credentialID == id { servers[i].credentialID = nil }
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
        saveTarget(credentialID: tunnel.credentialID, destination: tunnel.destination, kind: kind)
    }

    private func saveTarget(credentialID: UUID?, destination: String, kind: AskpassPrompt) -> String? {
        let current = credentialID.flatMap(credential)
        switch kind {
        case .other:
            return nil
        case .password:
            if let c = current, c.kind == .password { return "na credencial “\(c.displayName)”" }
            if let c = current, c.kind == .keyFile || c.kind == .keyContent { return nil } // não troca a chave por senha
            return "como a credencial “Senha de \(destination)”"
        case .passphrase(let keyPath):
            if let c = current, c.kind == .keyFile || c.kind == .keyContent { return "na credencial “\(c.displayName)”" }
            guard let keyPath else { return nil }
            return "como a credencial “\((keyPath as NSString).lastPathComponent)”"
        }
    }

    /// Guarda o segredo que o usuário digitou (chamado só depois que o servidor aceitou).
    func rememberSecret(_ secret: String, kind: AskpassPrompt, for tunnelID: UUID, protect: Bool) {
        guard let tunnel = tunnel(tunnelID),
              let id = storeSecret(secret, kind: kind, credentialID: tunnel.credentialID, destination: tunnel.destination, protect: protect)
        else { return }
        // Liga a credencial ao túnel sem reiniciar a conexão que acabou de autenticar.
        if let i = tunnels.firstIndex(where: { $0.id == tunnelID }), tunnels[i].credentialID != id {
            tunnels[i].credentialID = id
        }
    }

    func rememberSecret(_ secret: String, kind: AskpassPrompt, forServer serverID: UUID, protect: Bool) {
        guard let server = server(serverID),
              let id = storeSecret(secret, kind: kind, credentialID: server.credentialID, destination: server.destination, protect: protect)
        else { return }
        if let i = servers.firstIndex(where: { $0.id == serverID }), servers[i].credentialID != id {
            servers[i].credentialID = id
        }
    }

    /// Grava o segredo na credencial certa (existente ou nova) e devolve o id dela.
    private func storeSecret(_ secret: String, kind: AskpassPrompt, credentialID currentID: UUID?, destination: String, protect: Bool) -> UUID? {
        var target: Credential
        if let c = currentID.flatMap(credential),
           saveTarget(credentialID: currentID, destination: destination, kind: kind)?.hasPrefix("na credencial") == true {
            target = c
        } else {
            switch kind {
            case .password:
                target = Credential(name: "Senha de \(destination)", kind: .password)
            case .passphrase(let keyPath?):
                let id = credentialID(forIdentityFile: keyPath)
                target = credential(id) ?? Credential(kind: .keyFile, keyPath: Paths.abbreviate(keyPath))
            default:
                return nil
            }
        }
        switch kind {
        case .password: target.password = secret
        case .passphrase: target.passphrase = secret
        case .other: return nil
        }
        target.requireUserPresence = protect
        upsert(target)
        showToast(protect ? "Salvo no cofre, protegido por \(Unlocker.methodName)" : "Salvo no cofre")
        return target.id
    }

    // MARK: - Servidores

    func server(_ id: UUID) -> Server? { servers.first { $0.id == id } }

    func newServer(prefill: String = "") {
        var s = Server(tag: TagColor.allCases[servers.count % (TagColor.allCases.count - 1)])
        if let parsed = SSHCommandParser.parse(prefill) {
            s = parsed.server
            s.tag = TagColor.allCases[servers.count % (TagColor.allCases.count - 1)]
            if let identity = parsed.identityFile { s.credentialID = credentialID(forIdentityFile: identity) }
        }
        serverEditorRequest = ServerEditorRequest(server: s, isNew: true)
    }

    func editServer(_ id: UUID) {
        guard let s = server(id) else { return }
        serverEditorRequest = ServerEditorRequest(server: s, isNew: false)
    }

    func save(_ server: Server) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        selection = server.id
    }

    func duplicateServer(_ id: UUID) {
        guard var copy = server(id) else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " (cópia)"
        copy.createdAt = Date()
        if let i = servers.firstIndex(where: { $0.id == id }) { servers.insert(copy, at: i + 1) } else { servers.append(copy) }
        selection = copy.id
    }

    func requestDeleteServer(_ id: UUID) { pendingServerDeletion = server(id) }

    func deleteServer(_ id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers.remove(at: i)
        if selection == id { selection = servers.indices.contains(i) ? servers[i].id : servers.last?.id ?? tunnels.first?.id }
    }

    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
    }

    func copyServerCommand(_ id: UUID) {
        guard let s = server(id) else { return }
        copy(SSHCommand.displayString(for: s, credential: s.credentialID.flatMap(credential)), message: "Comando copiado")
    }

    /// Importa hosts do ~/.ssh/config, sem duplicar os que já existem. Devolve quantos entraram.
    @discardableResult
    func importHosts(_ hosts: [SSHConfigHost]) -> Int {
        let existing = Set(servers.map { $0.host.lowercased() })
        var added: [Server] = []
        for (n, host) in hosts.enumerated() where !existing.contains(host.alias.lowercased()) {
            var s = host.server
            s.tag = TagColor.allCases[(servers.count + n) % (TagColor.allCases.count - 1)]
            added.append(s)
        }
        servers += added
        if let first = added.first { selection = first.id }
        return added.count
    }

    func isImported(_ host: SSHConfigHost) -> Bool {
        servers.contains { $0.host.caseInsensitiveCompare(host.alias) == .orderedSame }
    }

    /// Abre um túnel novo já apontando para o servidor.
    func newTunnel(from serverID: UUID) {
        guard let s = server(serverID) else { return }
        var t = s.makeTunnel()
        t.tag = s.tag
        t.listenPort = suggestedListenPort(for: t.targetPort, excluding: nil)
        editorRequest = EditorRequest(tunnel: t, isNew: true)
    }

    /// Abre uma sessão SSH interativa no terminal escolhido nos Ajustes.
    func openServer(_ id: UUID) {
        guard server(id) != nil, !openingServers.contains(id) else { return }
        let terminal = TerminalApp.preferred
        let c = ServerConnection(serverID: id)
        c.askpassPath = askpassPath
        c.resolve = { [weak self] in
            guard let self, let s = self.server(id) else { return nil }
            return (s, s.credentialID.flatMap(self.credential))
        }
        c.authorize = { server, credential in
            await Unlocker.shared.authorize(reason: "usar “\(credential.displayName)” para abrir “\(server.displayName)”")
        }
        c.requestInput = { request, done in PromptPresenter.shared.present(request, completion: done) }
        c.dismissInput = { id in PromptPresenter.shared.dismiss(id) }
        c.saveTarget = { [weak self] server, kind in
            self?.saveTarget(credentialID: server.credentialID, destination: server.destination, kind: kind)
        }
        c.rememberSecret = { [weak self] server, kind, secret, protect in
            self?.rememberSecret(secret, kind: kind, forServer: server.id, protect: protect)
        }
        c.onFinish = { [weak self] c in self?.connections.removeValue(forKey: c.id) }
        connections[c.id] = c
        openingServers.insert(id)
        Task {
            defer { openingServers.remove(id) }
            do {
                try await c.start(in: terminal)
            } catch ServerConnection.LaunchError.unlockCancelled {
                showToast("Desbloqueio cancelado")
            } catch {
                showToast(error.localizedDescription)
            }
        }
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
