import AppKit
import RosenCore
import ServiceManagement
import SwiftUI

#if !SNAPSHOT
@main
#endif
struct RosenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("Rosen", id: WindowID.main) {
            ContentView()
                .environment(store)
                .frame(minWidth: 780, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { RosenCommands(store: store) }

        Window("Credenciais", id: WindowID.credentials) {
            CredentialsView()
                .environment(store)
                .frame(minWidth: 680, minHeight: 440)
        }
        .defaultSize(width: 780, height: 520)

        Window("Portas em uso", id: WindowID.ports) {
            PortsView()
                .environment(store)
                .frame(minWidth: 560, minHeight: 400)
        }
        .defaultSize(width: 720, height: 560)

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            MenuBarLabel().environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let credentials = "credentials"
    static let ports = "ports"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fontes de sinal mantidas vivas enquanto o app roda.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignals()
        DockIcon.observeWindows()
        AppStore.shared.bootstrap()
        // Se o app abrir sem janela (ex.: ao iniciar a sessão), fica só na barra de menus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DockIcon.apply() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.shutdown()
    }

    /// `kill`/`pkill` (e o `make run`) mandam SIGTERM, que por padrão derruba o app sem passar por
    /// `applicationWillTerminate`, deixando os `ssh` vivos e as portas presas. Aqui o sinal vira um
    /// encerramento normal. Crash e SIGKILL não têm como ser tratados: para eles há a limpeza ao abrir.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// O ícone no Dock acompanha as janelas: aparece com uma janela aberta e some quando a última
/// fecha. O Rosen continua na barra de menus, com os túneis ligados.
@MainActor
enum DockIcon {
    static let keepKey = "keepDockIcon"
    static var keepAlways: Bool { UserDefaults.standard.bool(forKey: keepKey) }

    /// Há uma janela do app aberta (principal, credenciais, ajustes), inclusive minimizada?
    /// Não contam o painel da barra de menus, o "Sobre" e o pedido de senha.
    static func hasOpenWindow(excluding closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            window !== closing
                && (window.isVisible || window.isMiniaturized)
                && window.styleMask.contains(.titled)
                && window.canBecomeMain
                && !(window is NSPanel)
        }
    }

    static func apply(excluding closing: NSWindow? = nil) {
        let policy: NSApplication.ActivationPolicy =
            keepAlways || hasOpenWindow(excluding: closing) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Ao voltar para o Dock, traz a janela para a frente.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    static func observeWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { apply(excluding: closing) }
        }
    }
}

// MARK: - Menus

struct RosenCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Sobre o Rosen") { AboutPanel.show() }
        }
        CommandGroup(replacing: .help) {
            Button("Rosen no GitHub") { NSWorkspace.shared.open(AboutPanel.repository) }
            Button("Reportar um problema…") { NSWorkspace.shared.open(AboutPanel.issues) }
            Divider()
            Button("Me pague um café ☕") { NSWorkspace.shared.open(AboutPanel.coffee) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Novo túnel") { openMain(); store.newTunnel() }
                .keyboardShortcut("n")
            Button("Novo túnel a partir do clipboard") { openMain(); store.newTunnelFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Novo servidor") { openMain(); store.newServer() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Importar servidores do ~/.ssh/config…") { openMain(); store.showingSSHConfigImport = true }
        }

        CommandMenu("Conexão") {
            let selected = store.selection.flatMap(store.tunnel)
            let server = store.selection.flatMap(store.server)
            let hasSelection = selected != nil || server != nil
            let isOn = selected.flatMap { store.session($0.id)?.isOn } ?? false
            Button(server != nil ? "Abrir no \(TerminalApp.preferred.title)" : isOn ? "Desconectar" : "Conectar") {
                if let id = selected?.id { store.toggle(id) } else if let id = server?.id { store.openServer(id) }
            }
                .keyboardShortcut("r")
                .disabled(!hasSelection)
            Button("Editar…") { if let id = selected?.id { store.edit(id) } else if let id = server?.id { store.editServer(id) } }
                .keyboardShortcut("e")
                .disabled(!hasSelection)
            Button("Duplicar") { if let id = selected?.id { store.duplicate(id) } else if let id = server?.id { store.duplicateServer(id) } }
                .keyboardShortcut("d")
                .disabled(!hasSelection)
            Divider()
            Button("Copiar endereço local") { if let id = selected?.id { store.copyAddress(id) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(selected == nil)
            Button("Copiar comando ssh") { if let id = selected?.id { store.copyCommand(id) } else if let id = server?.id { store.copyServerCommand(id) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            if let id = server?.id {
                Button("Criar túnel a partir deste servidor…") { store.newTunnel(from: id) }
            }
            Divider()
            Button("Conectar todos") { store.connectAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.tunnels.isEmpty)
            Button("Desconectar todos") { store.disconnectAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(store.activeCount == 0)
            Divider()
            Button("Gerenciar credenciais…") { openWindow(id: WindowID.credentials) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Bloquear credenciais") { Unlocker.shared.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!Unlocker.shared.isUnlocked)
            Button("Portas em uso…") { openWindow(id: WindowID.ports) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Excluir…") { if let id = selected?.id { store.requestDelete(id) } else if let id = server?.id { store.requestDeleteServer(id) } }
                .disabled(!hasSelection)
        }
    }

    private func openMain() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(DockIcon.keepKey) private var keepDockIcon = false
    @AppStorage("notifyDrops") private var notifyDrops = true
    @AppStorage(Unlocker.graceKey) private var graceMinutes = 15
    @AppStorage(TerminalApp.preferenceKey) private var terminalChoice = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Abrir o Rosen ao iniciar a sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Mova o Rosen para /Applications para ativar isso. (\(error.localizedDescription))"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Manter no Dock com a janela fechada", isOn: $keepDockIcon)
                    .onChange(of: keepDockIcon) { _, _ in DockIcon.apply() }
                Toggle("Avisar quando um túnel cair", isOn: $notifyDrops)
            } footer: {
                Text("Ao fechar a janela, o Rosen fica só na barra de menus e os túneis continuam ligados. ⌘Q sai de vez.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Abrir servidores no", selection: Binding(
                    get: { TerminalApp.preferred },
                    set: { terminalChoice = $0.rawValue }
                )) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isInstalled ? app.title : "\(app.title) (não instalado)")
                            .tag(app)
                            .disabled(!app.isInstalled)
                    }
                }
                if !terminalChoice.isEmpty, let chosen = TerminalApp(rawValue: terminalChoice), !chosen.isInstalled {
                    Text("O \(chosen.title) não foi encontrado. Usando o \(TerminalApp.preferred.title).")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Cada servidor abre numa aba nova com o ssh já rodando. O Rosen entrega senhas salvas pelo askpass, sem digitar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Pedir \(Unlocker.methodName) de novo", selection: $graceMinutes) {
                    ForEach(Unlocker.graceOptions, id: \.minutes) { option in
                        Text(option.title).tag(option.minutes)
                    }
                }
                HStack {
                    Label(Unlocker.shared.isUnlocked ? "Credenciais desbloqueadas" : "Credenciais bloqueadas",
                          systemImage: Unlocker.shared.isUnlocked ? "lock.open" : "lock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Bloquear agora") { Unlocker.shared.lock() }
                        .disabled(!Unlocker.shared.isUnlocked)
                }
            } header: {
                Text("Desbloqueio")
            } footer: {
                Text("Vale para credenciais marcadas com “Pedir \(Unlocker.methodName) para usar”. Bloquear o Mac ou colocá-lo para dormir sempre bloqueia de novo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Segurança") {
                LabeledContent("Cofre") {
                    Text("AES-256-GCM").font(.callout.monospaced())
                }
                LabeledContent("Chave mestra") {
                    Text("Keychain do macOS (só neste Mac)").foregroundStyle(.secondary)
                }
                HStack {
                    Text(Paths.abbreviate(store.vaultURL.path))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.vaultURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
