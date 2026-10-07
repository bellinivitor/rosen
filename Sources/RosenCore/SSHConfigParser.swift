import Darwin
import Foundation

/// Um `Host` do ~/.ssh/config que pode virar um servidor do Rosen.
public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }

    /// O servidor usa o alias como host: o ssh resolve HostName, chave e ProxyJump pelo próprio config.
    public var server: Server {
        Server(name: alias, host: alias, port: port ?? 22, user: user ?? "")
    }

    /// Linha curta para a tela de importação: "deploy@10.0.0.5:2222 via bastion".
    public var summary: String {
        var s = hostName ?? alias
        if let user { s = "\(user)@\(s)" }
        if let port, port != 22 { s += ":\(port)" }
        if let proxyJump { s += " via \(proxyJump)" }
        return s
    }
}

/// Lê os blocos `Host` de um ~/.ssh/config. Padrões com curinga e blocos `Match` são ignorados.
public enum SSHConfigParser {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Lê o arquivo e os `Include` dele. Devolve `nil` se o arquivo não existir.
    public static func load(from url: URL = defaultURL) -> [SSHConfigHost]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sshDir = url.deletingLastPathComponent().path
        return parse(text) { pattern in
            expandInclude(pattern, relativeTo: sshDir).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// - Parameter include: devolve o conteúdo dos arquivos de um `Include` (vazio por padrão).
    public static func parse(_ text: String, include: (String) -> [String] = { _ in [] }) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var depth = 0
        parse(text, into: &hosts, depth: &depth, include: include)
        return hosts
    }

    private static func parse(_ text: String, into hosts: inout [SSHConfigHost], depth: inout Int,
                              include: (String) -> [String]) {
        // Índices (em `hosts`) dos aliases do bloco atual; nil fora de um bloco Host válido.
        var current: [Int] = []
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (key, values) = splitLine(rawLine) else { continue }
            switch key {
            case "host":
                current = []
                for alias in values where !isPattern(alias) {
                    if let i = hosts.firstIndex(where: { $0.alias == alias }) {
                        current.append(i)
                    } else {
                        hosts.append(SSHConfigHost(alias: alias))
                        current.append(hosts.count - 1)
                    }
                }
            case "match":
                current = []
            case "include":
                guard depth < 8 else { continue }
                depth += 1
                for pattern in values {
                    for included in include(pattern) {
                        parse(included, into: &hosts, depth: &depth, include: include)
                    }
                }
                depth -= 1
            default:
                guard let value = values.first else { continue }
                // No ssh, o primeiro valor de cada opção vence.
                for i in current {
                    switch key {
                    case "hostname": hosts[i].hostName = hosts[i].hostName ?? value
                    case "user": hosts[i].user = hosts[i].user ?? value
                    case "port": hosts[i].port = hosts[i].port ?? Int(value)
                    case "identityfile": hosts[i].identityFile = hosts[i].identityFile ?? value
                    case "proxyjump": hosts[i].proxyJump = hosts[i].proxyJump ?? value
                    default: break
                    }
                }
            }
        }
    }

    /// "Chave valor", "Chave=valor" ou "Chave = \"valor com espaço\"" → (chave minúscula, valores).
    static func splitLine(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let keyEnd = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) ?? trimmed.endIndex
        let key = trimmed[..<keyEnd].lowercased()
        var rest = trimmed[keyEnd...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        let values = tokenize(String(rest))
        return key.isEmpty ? nil : (key, values)
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var inToken = false
        for ch in s {
            if ch == "\"" {
                inQuote.toggle()
                inToken = true
            } else if !inQuote, ch == "#" {
                break
            } else if !inQuote, ch == " " || ch == "\t" {
                if inToken { tokens.append(current); current = ""; inToken = false }
            } else {
                current.append(ch)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }

    /// Caminhos de um `Include`: `~` expandido, relativo a ~/.ssh, com glob.
    static func expandInclude(_ pattern: String, relativeTo sshDir: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (sshDir as NSString).appendingPathComponent(path) }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }.sorted()
    }
}
