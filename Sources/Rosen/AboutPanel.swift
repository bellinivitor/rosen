import AppKit

/// Painel "Sobre o Rosen": o padrão do macOS com descrição, aviso de beta e links.
enum AboutPanel {
    static let repository = URL(string: "https://github.com/bellinivitor/rosen")!
    static let issues = URL(string: "https://github.com/bellinivitor/rosen/issues")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var isBeta: Bool { version.contains("beta") }

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: isBeta ? "Versão \(version) (beta)" : "Versão \(version)",
            .version: "",
            .credits: credits,
        ])
    }

    private static var credits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        let note: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Gerenciador de túneis SSH para macOS.\n", attributes: body))
        if isBeta {
            text.append(NSAttributedString(
                string: "Versão beta: pode ter arestas. Seus túneis e segredos ficam só neste Mac, no cofre criptografado.\n",
                attributes: note))
        }
        text.append(NSAttributedString(
            string: "O nome vem da ponte de Einstein-Rosen, o “buraco de minhoca”.\n\n",
            attributes: note))

        var link = body
        link[.link] = repository
        text.append(NSAttributedString(string: "github.com/bellinivitor/rosen", attributes: link))
        text.append(NSAttributedString(string: "  ·  ", attributes: note))
        link[.link] = issues
        text.append(NSAttributedString(string: "Reportar um problema", attributes: link))
        return text
    }
}
