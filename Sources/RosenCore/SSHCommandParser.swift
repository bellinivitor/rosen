import Foundation

public struct ParsedSSHCommand: Equatable, Sendable {
    public var tunnel: Tunnel
    public var identityFile: String?
    public var hasForward: Bool

    /// O destino do comando como servidor (encaminhamentos são ignorados).
    public var server: Server {
        Server(host: tunnel.host, port: tunnel.port, user: tunnel.user, extraOptions: tunnel.extraOptions)
    }
}

/// Entende comandos como `ssh -N -L 5433:127.0.0.1:5432 usuario@servidor.com`
/// e transforma em um `Tunnel`.
public enum SSHCommandParser {
    private static let flagsWithArgument: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
        "m", "O", "o", "p", "Q", "R", "S", "W", "w",
    ]

    /// Opções que o Rosen controla e por isso não vale a pena guardar.
    private static let managedOptions: Set<String> = [
        "exitonforwardfailure", "serveraliveinterval", "serveralivecountmax",
        "stricthostkeychecking", "batchmode", "numberofpasswordprompts",
        "controlmaster", "controlpath", "controlpersist", "identitiesonly",
        "localforward", "remoteforward", "dynamicforward", "requesttty", "sessiontype",
    ]

    public static func parse(_ input: String) -> ParsedSSHCommand? {
        var tokens = tokenize(normalize(input))
        if let sshIndex = tokens.firstIndex(where: { $0 == "ssh" || $0.hasSuffix("/ssh") }) {
            tokens = Array(tokens[(sshIndex + 1)...])
        } else {
            return nil
        }

        var tunnel = Tunnel()
        var identity: String?
        var hasForward = false
        var host: String?
        var user: String?
        var port: Int?
        var options: [String] = []

        func handle(_ flag: Character, _ value: String) {
            switch flag {
            case "L", "R":
                guard !hasForward, let f = parseForward(value, kind: flag == "L" ? .local : .remote) else { return }
                tunnel.kind = flag == "L" ? .local : .remote
                tunnel.bindAddress = f.bind
                tunnel.listenPort = f.listen
                tunnel.targetHost = f.host
                tunnel.targetPort = f.hostPort
                hasForward = true
            case "D":
                guard !hasForward else { return }
                let parts = splitSpec(value)
                if parts.count == 1, let p = Int(parts[0]) {
                    tunnel.kind = .dynamic; tunnel.bindAddress = "127.0.0.1"; tunnel.listenPort = p; hasForward = true
                } else if parts.count == 2, let p = Int(parts[1]) {
                    tunnel.kind = .dynamic; tunnel.bindAddress = parts[0].isEmpty ? "*" : parts[0]; tunnel.listenPort = p; hasForward = true
                }
            case "p":
                port = Int(value)
            case "i":
                identity = value
            case "l":
                user = value
            case "J":
                options.append("ProxyJump=\(value)")
            case "o":
                let pair = splitOption(value)
                switch pair.key.lowercased() {
                case "port": port = Int(pair.value)
                case "user": user = pair.value
                case "identityfile": identity = pair.value
                case "hostname": host = host ?? pair.value
                case let key where managedOptions.contains(key): break
                default: options.append("\(pair.key)=\(pair.value)")
                }
            default:
                break
            }
        }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                // fim das opções
            } else if token.hasPrefix("-"), token.count > 1 {
                let chars = Array(token.dropFirst())
                var j = 0
                while j < chars.count {
                    let flag = chars[j]
                    if flagsWithArgument.contains(flag) {
                        var value = String(chars[(j + 1)...])
                        if value.isEmpty {
                            i += 1
                            value = i < tokens.count ? tokens[i] : ""
                        }
                        handle(flag, value)
                        break
                    }
                    j += 1
                }
            } else if host == nil {
                let dest = parseDestination(token)
                host = dest.host
                if let u = dest.user { user = user ?? u }
                if let p = dest.port { port = port ?? p }
            } else {
                break // daqui em diante é o comando remoto
            }
            i += 1
        }

        guard let resolvedHost = host, !resolvedHost.isEmpty else { return nil }
        tunnel.host = resolvedHost
        tunnel.user = user ?? ""
        tunnel.port = port ?? 22
        tunnel.extraOptions = options
        return ParsedSSHCommand(tunnel: tunnel, identityFile: identity, hasForward: hasForward)
    }

    // MARK: - Partes

    struct Forward { var bind: String; var listen: Int; var host: String; var hostPort: Int }

    static func parseForward(_ spec: String, kind: ForwardKind) -> Forward? {
        let parts = splitSpec(spec)
        switch parts.count {
        case 3:
            guard let l = Int(parts[0]), let hp = Int(parts[2]) else { return nil }
            return Forward(bind: kind == .remote ? "" : "127.0.0.1", listen: l, host: parts[1], hostPort: hp)
        case 4:
            guard let l = Int(parts[1]), let hp = Int(parts[3]) else { return nil }
            return Forward(bind: parts[0].isEmpty ? "*" : parts[0], listen: l, host: parts[2], hostPort: hp)
        default:
            return nil
        }
    }

    static func parseDestination(_ token: String) -> (user: String?, host: String, port: Int?) {
        var rest = token
        var port: Int?
        if rest.lowercased().hasPrefix("ssh://") {
            rest = String(rest.dropFirst(6))
            if rest.hasSuffix("/") { rest.removeLast() }
            if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) {
                port = p
                rest = String(rest[..<colon])
            }
        }
        if let at = rest.lastIndex(of: "@") {
            let user = String(rest[..<at])
            let host = String(rest[rest.index(after: at)...])
            return (user.isEmpty ? nil : user, unbracket(host), port)
        }
        return (nil, unbracket(rest), port)
    }

    static func splitSpec(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            switch ch {
            case "[": depth += 1
            case "]": depth -= 1
            case ":" where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    static func splitOption(_ s: String) -> (key: String, value: String) {
        if let eq = s.firstIndex(of: "=") {
            return (String(s[..<eq]).trimmingCharacters(in: .whitespaces),
                    String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        let pieces = s.split(separator: " ", maxSplits: 1).map(String.init)
        return (pieces.first ?? "", pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : "")
    }

    static func unbracket(_ s: String) -> String {
        s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
    }

    static func normalize(_ input: String) -> String {
        var s = input
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$ ") { s.removeFirst(2) }
        return s
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\", q == "\"", i + 1 < chars.count {
                    i += 1
                    current.append(chars[i])
                } else {
                    current.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inToken = true
            } else if ch == "\\" {
                if i + 1 < chars.count {
                    i += 1
                    if chars[i] != "\n" {
                        current.append(chars[i])
                        inToken = true
                    }
                }
            } else if ch.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
            } else {
                current.append(ch)
                inToken = true
            }
            i += 1
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
