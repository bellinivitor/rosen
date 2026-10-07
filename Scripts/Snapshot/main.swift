// Renderiza telas do Rosen em PNG, fora da tela, para revisão visual.
import AppKit
import RosenCore
import SwiftUI

@MainActor
func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = host.appearance
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

@MainActor
func run() {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let store = AppStore.shared
    let cred = Credential(name: "Chave de produção", kind: .keyFile, keyPath: "~/.ssh/id_ed25519",
                          passphrase: "segredo", requireUserPresence: true)
    store.credentials = [cred]
    var a = Tunnel(name: "Postgres produção", host: "db.exemplo.com", user: "deploy", listenPort: 5433,
                   targetHost: "127.0.0.1", targetPort: 5432, credentialID: cred.id, autoConnect: true, tag: .indigo)
    a.extraOptions = ["ProxyJump=bastion"]
    let b = Tunnel(name: "", host: "cache.interno", user: "ops", listenPort: 6380, targetHost: "10.0.0.12", targetPort: 6379, tag: .red)
    let c = Tunnel(name: "Proxy do escritório", host: "vpn.exemplo.com", user: "ana", kind: .dynamic, listenPort: 1080, tag: .teal)
    let d = Tunnel(name: "Postgres staging", host: "staging.exemplo.com", user: "app", listenPort: 5434, targetPort: 5432, tag: .green)
    store.tunnels = [a, b, c, d]
    let web = Server(name: "Web produção", host: "web.exemplo.com", user: "deploy", credentialID: cred.id, tag: .purple,
                     extraOptions: ["ProxyJump=bastion"])
    let lab = Server(name: "", host: "lab.local", port: 2222, user: "ana", tag: .orange)
    store.servers = [web, lab]
    store.session(a.id)?.setSnapshotState(.connected(since: Date().addingTimeInterval(-754)), logs: [
        (.info, "Conectando a deploy@db.exemplo.com…"), (.info, "Conexão TCP estabelecida."),
        (.info, "Servidor aceitou a chave."), (.info, "Autenticado."), (.success, "Túnel ativo."),
        (.warning, "O destino recusou uma conexão — o serviço está rodando nessa porta?"),
    ], latency: [24, 26, 23, 31, 27, 25, 48, 29, 26, 24, 25, nil, 27, 26, 23, 25, 24, 28, 26, 25])
    store.session(b.id)?.setSnapshotState(.failed("Autenticação recusada. Confira o usuário e a credencial."), logs: [
        (.info, "Conectando a ops@cache.interno…"), (.error, "Autenticação recusada. Confira o usuário e a credencial."),
    ])
    store.session(c.id)?.setSnapshotState(.waiting(retryAt: Date().addingTimeInterval(8), attempt: 3, reason: "A conexão com o servidor caiu."), logs: [])
    store.session(d.id)?.setSnapshotState(.unlocking, logs: [])
    store.selection = a.id

    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"
        render(TunnelDetailView(tunnelID: a.id).environment(store), size: CGSize(width: 760, height: 980), dark: dark,
               to: out.appendingPathComponent("detail-\(suffix).png"))
        render(TunnelDetailView(tunnelID: b.id).environment(store), size: CGSize(width: 760, height: 560), dark: dark,
               to: out.appendingPathComponent("failed-\(suffix).png"))
        render(TunnelDetailView(tunnelID: c.id).environment(store), size: CGSize(width: 760, height: 560), dark: dark,
               to: out.appendingPathComponent("waiting-\(suffix).png"))
        render(CredentialForm(credential: .constant(cred), usage: [a]), size: CGSize(width: 520, height: 520), dark: dark,
               to: out.appendingPathComponent("credential-locked-\(suffix).png"))
        render(TunnelDetailView(tunnelID: d.id).environment(store), size: CGSize(width: 760, height: 420), dark: dark,
               to: out.appendingPathComponent("unlocking-\(suffix).png"))
        let ask = TunnelSession.InputRequest(subject: PromptSubject(b), kind: .password, prompt: "(ops@cache.interno) Password:",
                                             retry: false, storedRejected: false,
                                             saveTarget: "como a credencial “Senha de ops@cache.interno”", keyName: nil)
        render(PromptView(request: ask) { _ in }.background(.background), size: CGSize(width: 440, height: 430), dark: dark,
               to: out.appendingPathComponent("prompt-\(suffix).png"))
        let retry = TunnelSession.InputRequest(subject: PromptSubject(a), kind: .passphrase(keyPath: "/Users/ana/.ssh/id_ed25519"),
                                               prompt: "Enter passphrase for key '/Users/ana/.ssh/id_ed25519':",
                                               retry: true, storedRejected: false,
                                               saveTarget: "na credencial “Chave de produção”", keyName: "Chave de produção")
        render(PromptView(request: retry) { _ in }.background(.background), size: CGSize(width: 440, height: 460), dark: dark,
               to: out.appendingPathComponent("prompt-retry-\(suffix).png"))
        render(AboutView().background(.background), size: CGSize(width: 300, height: 480), dark: dark,
               to: out.appendingPathComponent("about-\(suffix).png"))
        render(EmptyStateView().environment(store), size: CGSize(width: 760, height: 600), dark: dark,
               to: out.appendingPathComponent("empty-\(suffix).png"))
        render(SidebarView().environment(store).background(.background), size: CGSize(width: 300, height: 600), dark: dark,
               to: out.appendingPathComponent("sidebar-\(suffix).png"))
        render(ServersEmptyRow().environment(store).padding(.horizontal, 12).background(.background),
               size: CGSize(width: 290, height: 110), dark: dark, to: out.appendingPathComponent("servers-empty-\(suffix).png"))
        render(MenuBarView().environment(store).background(.background), size: CGSize(width: 330, height: 480), dark: dark,
               to: out.appendingPathComponent("menubar-\(suffix).png"))
        render(ServerDetailView(serverID: web.id).environment(store), size: CGSize(width: 760, height: 620), dark: dark,
               to: out.appendingPathComponent("server-\(suffix).png"))
        render(ServerEditor(request: ServerEditorRequest(server: lab, isNew: true)).environment(store),
               size: CGSize(width: 560, height: 600), dark: dark, to: out.appendingPathComponent("server-editor-\(suffix).png"))
        render(TunnelEditor(request: EditorRequest(tunnel: a, isNew: false)).environment(store),
               size: CGSize(width: 600, height: 720), dark: dark, to: out.appendingPathComponent("editor-\(suffix).png"))
    }
    print("✓ \(out.path)")
}

@main
struct SnapshotMain {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        run()
    }
}
