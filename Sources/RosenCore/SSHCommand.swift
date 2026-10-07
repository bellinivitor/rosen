import Foundation

/// Como o ssh vai se autenticar.
public enum AuthMaterial: Equatable, Sendable {
    /// ssh-agent / ~/.ssh/config.
    case system
    case identityFile(String)
    case password
}

public enum SSHCommand {
    public static let executable = "/usr/bin/ssh"

    /// Argumentos reais passados ao /usr/bin/ssh. Nunca contêm segredos.
    public static func arguments(for t: Tunnel, auth: AuthMaterial) -> [String] {
        var args = ["-N", "-T", "-v"]

        // Opções do usuário primeiro: no ssh o primeiro valor de cada opção vence.
        for option in t.extraOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }

        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=3",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]

        args += authArguments(auth)
        args += ["-p", String(t.port)]
        args += [t.kind.flag, forwardSpec(for: t, omitLoopbackBind: t.kind == .remote)]
        args.append(t.destination)
        return args
    }

    /// Argumentos de uma sessão interativa (num terminal). Nunca contêm segredos.
    public static func interactiveArguments(for s: Server, auth: AuthMaterial) -> [String] {
        var args = ["-t"]
        for option in s.extraOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }
        args += [
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=3",
        ]
        args += authArguments(auth)
        args += ["-p", String(s.port)]
        args.append(s.destination)
        return args
    }

    static func authArguments(_ auth: AuthMaterial) -> [String] {
        switch auth {
        case .system:
            return []
        case .identityFile(let path):
            return ["-i", path, "-o", "IdentitiesOnly=yes"]
        case .password:
            return [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
            ]
        }
    }

    public static func forwardSpec(for t: Tunnel, omitLoopbackBind: Bool) -> String {
        let bind = t.bindAddress.trimmingCharacters(in: .whitespaces)
        let skipBind = bind.isEmpty || (omitLoopbackBind && isLoopback(bind))
        let prefix = skipBind ? "" : "\(bracket(bind)):"
        switch t.kind {
        case .local, .remote:
            return "\(prefix)\(t.listenPort):\(bracket(t.targetHost)):\(t.targetPort)"
        case .dynamic:
            return "\(prefix)\(t.listenPort)"
        }
    }

    /// Comando equivalente, legível e copiável. Segredos aparecem como marcadores.
    public static func displayString(for t: Tunnel, credential: Credential?) -> String {
        var parts = ["ssh", "-N", t.kind.flag, forwardSpec(for: t, omitLoopbackBind: true)]
        if t.port != 22 { parts += ["-p", String(t.port)] }
        parts += identityParts(credential)
        for option in t.extraOptions where !option.isEmpty { parts += ["-o", option] }
        parts.append(t.destination.isEmpty ? "usuario@servidor" : t.destination)
        return parts.map(shellQuote).joined(separator: " ")
    }

    /// Comando interativo equivalente, legível e copiável.
    public static func displayString(for s: Server, credential: Credential?) -> String {
        var parts = ["ssh"]
        if s.port != 22 { parts += ["-p", String(s.port)] }
        parts += identityParts(credential)
        for option in s.extraOptions where !option.isEmpty { parts += ["-o", option] }
        parts.append(s.destination.isEmpty ? "usuario@servidor" : s.destination)
        return parts.map(shellQuote).joined(separator: " ")
    }

    static func identityParts(_ credential: Credential?) -> [String] {
        switch credential?.kind {
        case .keyFile?:
            if let path = credential?.keyPath, !path.isEmpty { return ["-i", Paths.abbreviate(path)] }
            return []
        case .keyContent?:
            return ["-i", "<chave-do-cofre>"]
        default:
            return []
        }
    }

    public static func isLoopback(_ address: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(address.lowercased())
    }

    static func bracket(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_~[]<>")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
