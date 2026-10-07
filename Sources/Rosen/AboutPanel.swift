import AppKit
import SwiftUI

/// Painel "Sobre o Rosen". Próprio, e não o padrão do macOS, porque o padrão tem uma área de
/// créditos de altura fixa que rola quando há mais de umas poucas linhas.
enum AboutPanel {
    static let repository = URL(string: "https://github.com/bellinivitor/rosen")!
    static let issues = URL(string: "https://github.com/bellinivitor/rosen/issues")!
    static let coffee = URL(string: "https://buymeacoffee.com/vitorbellini")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var isBeta: Bool { version.contains("beta") }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "Rosen"
    }

    @MainActor private static var panel: NSPanel?

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: AboutView())
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.title = "Sobre o Rosen"
        panel.contentViewController = host
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 34)

            Text("Rosen")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 10)
            Text(AboutPanel.isBeta ? "Versão \(AboutPanel.version) (beta)" : "Versão \(AboutPanel.version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            VStack(spacing: 8) {
                Text("Túneis e acessos SSH para macOS.")
                    .font(.system(size: 12, weight: .medium))
                if AboutPanel.isBeta {
                    Text("Versão beta: pode ter arestas. Seus túneis, servidores e segredos ficam só neste Mac, no cofre criptografado.")
                        .foregroundStyle(.secondary)
                }
                Text("O nome vem da ponte de Einstein-Rosen, o “buraco de minhoca”.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            .padding(.horizontal, 28)

            VStack(spacing: 6) {
                Link("Código no GitHub", destination: AboutPanel.repository)
                Link("Reportar um problema", destination: AboutPanel.issues)
                Link("☕ Me pague um café", destination: AboutPanel.coffee)
            }
            .font(.system(size: 12))
            .padding(.top, 18)

            Divider()
                .padding(.top, 20)
            Text(AboutPanel.copyright)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}
