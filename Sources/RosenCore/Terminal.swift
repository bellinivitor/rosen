import Foundation

/// Terminais onde o Rosen abre sessões interativas.
public enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case warp, terminal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .warp: return "Warp"
        case .terminal: return "Terminal"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .warp: return "dev.warp.Warp-Stable"
        case .terminal: return "com.apple.Terminal"
        }
    }
}

/// Script `.command` que o terminal executa: prepara o askpass e troca de processo pelo ssh.
/// Não contém segredos, só caminhos de FIFOs e os argumentos do ssh.
public enum ConnectScript {
    public static let fileName = "connect.command"

    public static func make(title: String, arguments: [String], environment: [String: String]) -> String {
        var lines = [
            "#!/bin/sh",
            "# Rosen: sessão SSH. Este arquivo se apaga ao iniciar.",
            "rm -f \"$0\"",
        ]
        for key in environment.keys.sorted() {
            lines.append("export \(key)=\(SSHCommand.shellQuote(environment[key]!))")
        }
        let safeTitle = title.replacingOccurrences(of: "\u{1B}", with: "").replacingOccurrences(of: "\u{07}", with: "")
        lines.append("printf '\\033]0;%s\\007' \(SSHCommand.shellQuote(safeTitle))")
        lines.append((["exec", SSHCommand.executable] + arguments).map(SSHCommand.shellQuote).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Variáveis para o ssh perguntar ao Rosen (via askpass) em vez de ao terminal.
    public static func askpassEnvironment(askpassPath: String, broker: [String: String]) -> [String: String] {
        var env = broker
        env["SSH_ASKPASS"] = askpassPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        // Se o Rosen não estiver mais escutando, o askpass pergunta no próprio terminal.
        env["ROSEN_ASKPASS_TTY"] = "1"
        return env
    }

    /// Grava o script (0700) no diretório da conexão.
    @discardableResult
    public static func write(_ script: String, in workspace: ConnectionWorkspace) throws -> URL {
        let url = workspace.url.appendingPathComponent(fileName)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
