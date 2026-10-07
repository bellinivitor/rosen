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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.apply()
        AppStore.shared.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.shutdown()
    }
}

enum DockIcon {
    static var isVisible: Bool { UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true }

    @MainActor
    static func apply() {
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
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
        }
        CommandGroup(replacing: .newItem) {
            Button("Novo túnel") { openMain(); store.newTunnel() }
                .keyboardShortcut("n")
            Button("Novo túnel a partir do clipboard") { openMain(); store.newTunnelFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandMenu("Túnel") {
            let selected = store.selection.flatMap(store.tunnel)
            let isOn = selected.flatMap { store.session($0.id)?.isOn } ?? false
            Button(isOn ? "Desconectar" : "Conectar") { if let id = selected?.id { store.toggle(id) } }
                .keyboardShortcut("r")
                .disabled(selected == nil)
            Button("Editar…") { if let id = selected?.id { store.edit(id) } }
                .keyboardShortcut("e")
                .disabled(selected == nil)
            Button("Duplicar") { if let id = selected?.id { store.duplicate(id) } }
                .keyboardShortcut("d")
                .disabled(selected == nil)
            Divider()
            Button("Copiar endereço local") { if let id = selected?.id { store.copyAddress(id) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(selected == nil)
            Button("Copiar comando ssh") { if let id = selected?.id { store.copyCommand(id) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selected == nil)
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
            Divider()
            Button("Excluir…") { if let id = selected?.id { store.requestDelete(id) } }
                .disabled(selected == nil)
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
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("notifyDrops") private var notifyDrops = true
    @AppStorage(Unlocker.graceKey) private var graceMinutes = 15
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
                Toggle("Mostrar ícone no Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in DockIcon.apply() }
                Toggle("Avisar quando um túnel cair", isOn: $notifyDrops)
            } footer: {
                Text("Sem o ícone no Dock, o Rosen continua acessível pela barra de menus.")
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
