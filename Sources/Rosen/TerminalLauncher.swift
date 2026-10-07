import AppKit
import RosenCore

/// Abre o script de conexão num terminal externo.
protocol TerminalLauncher {
    var app: TerminalApp { get }
    func launch(script: URL) async throws
}

enum TerminalLaunchError: LocalizedError {
    case notInstalled(TerminalApp)
    case failed(TerminalApp, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let app): return "O \(app.title) não está instalado. Escolha outro terminal nos Ajustes."
        case .failed(let app, let reason): return "Não foi possível abrir o \(app.title): \(reason)"
        }
    }
}

/// Warp e Terminal.app executam um `.command` aberto com eles (os dois declaram o tipo
/// `com.apple.terminal.shell-script` com papel Shell). Outros terminais podem precisar de outro caminho.
struct OpenCommandLauncher: TerminalLauncher {
    let app: TerminalApp

    func launch(script: URL) async throws {
        guard let appURL = app.applicationURL else { throw TerminalLaunchError.notInstalled(app) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config)
        } catch {
            throw TerminalLaunchError.failed(app, error.localizedDescription)
        }
    }
}

extension TerminalApp {
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool { applicationURL != nil }

    var launcher: TerminalLauncher { OpenCommandLauncher(app: self) }

    static var installed: [TerminalApp] { allCases.filter(\.isInstalled) }

    // MARK: Preferência

    static let preferenceKey = "preferredTerminal"

    /// Terminal escolhido nos Ajustes; sem escolha, o Warp se estiver instalado.
    static var preferred: TerminalApp {
        if let raw = UserDefaults.standard.string(forKey: preferenceKey), let app = TerminalApp(rawValue: raw), app.isInstalled {
            return app
        }
        return TerminalApp.warp.isInstalled ? .warp : .terminal
    }
}
