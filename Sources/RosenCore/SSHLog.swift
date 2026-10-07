import Foundation

public enum SSHLogEvent: Equatable, Sendable {
    /// Autenticação concluída.
    case authenticated
    /// O encaminhamento está escutando.
    case forwardReady
    /// Erro que não adianta tentar de novo (senha errada, porta ocupada…).
    case fatal(String)
    /// Erro transitório (rede, timeout…). Vale reconectar.
    case transient(String)
    /// Aviso que não derruba o túnel (ex.: destino recusou uma conexão).
    case warning(String)
    case info(String)
    case noise
}

/// Traduz a saída verbosa do ssh em eventos e mensagens humanas.
public enum SSHLog {
    public static func classify(_ rawLine: String) -> SSHLogEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .noise }
        let l = line.lowercased()

        if l.contains("authenticated to ") { return .authenticated }
        if l.contains("local connections to") || l.contains("local forwarding listening on")
            || l.contains("remote forward success") {
            return .forwardReady
        }

        // Falhas de canal: um cliente tentou usar o túnel, mas o destino recusou.
        if l.contains("channel") && l.contains("open failed") {
            return .warning("O destino recusou uma conexão — o serviço está rodando nessa porta?")
        }

        if l.contains("remote host identification has changed") || l.contains("host key verification failed") {
            return .fatal("A identidade do servidor mudou. Se o servidor foi reinstalado, remova a entrada antiga em ~/.ssh/known_hosts; caso contrário, pode ser um ataque.")
        }
        if l.contains("too many authentication failures") || l.contains("permission denied") {
            return .fatal("Autenticação recusada. Confira o usuário e a credencial.")
        }
        if l.contains("incorrect passphrase") || l.contains("bad passphrase") {
            return .fatal("Passphrase da chave incorreta.")
        }
        if l.contains("load key") && (l.contains("invalid format") || l.contains("error in libcrypto")) {
            return .fatal("A chave privada é inválida ou está em um formato não suportado.")
        }
        if l.contains("bad permissions") || l.contains("unprotected private key file") {
            return .fatal("Permissões inseguras na chave privada. Rode: chmod 600 no arquivo da chave.")
        }
        if l.contains("no such identity") || (l.contains("identity file") && l.contains("not accessible")) {
            return .fatal("Arquivo da chave privada não encontrado.")
        }
        if l.contains("address already in use") || l.contains("cannot listen to port")
            || l.contains("could not request local forwarding") {
            return .fatal("A porta local já está em uso por outro programa.")
        }
        if l.contains("remote port forwarding failed") {
            return .fatal("O servidor recusou o encaminhamento remoto (porta ocupada ou não permitida).")
        }
        if l.contains("bad local forwarding") || l.contains("bad remote forwarding") || l.contains("bad dynamic forwarding") {
            return .fatal("Especificação de encaminhamento inválida.")
        }
        if l.contains("could not resolve hostname") {
            return .transient("Não foi possível encontrar o servidor. Confira o endereço ou sua internet.")
        }
        if l.contains("connection refused") {
            return .transient("O servidor recusou a conexão SSH (porta fechada?).")
        }
        if l.contains("timed out") {
            return .transient("Tempo esgotado tentando falar com o servidor.")
        }
        if l.contains("network is unreachable") || l.contains("no route to host") {
            return .transient("Sem rota de rede até o servidor.")
        }
        if l.contains("server not responding") || l.contains("broken pipe") || l.contains("connection reset")
            || l.contains("connection closed by") {
            return .transient("A conexão com o servidor caiu.")
        }

        if l.hasPrefix("debug") {
            let message = line.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
            let m = message.lowercased()
            if m.hasPrefix("connecting to") { return .info("Conectando a \(extractHost(message))…") }
            if m.hasPrefix("connection established") { return .info("Conexão TCP estabelecida.") }
            if m.hasPrefix("server accepts key") { return .info("Servidor aceitou a chave.") }
            if m.hasPrefix("will attempt key") || m.hasPrefix("offering public key") { return .noise }
            return .noise
        }

        if l.hasPrefix("warning: permanently added") {
            return .info("Servidor adicionado aos hosts conhecidos (~/.ssh/known_hosts).")
        }
        if l.hasPrefix("transferred:") || l.hasPrefix("bytes per second") { return .noise }
        if l.hasPrefix("openssh") || l.hasPrefix("authenticated using") { return .noise }
        return .info(line)
    }

    private static func extractHost(_ message: String) -> String {
        // "Connecting to host [1.2.3.4] port 22."
        let parts = message.split(separator: " ")
        return parts.count > 2 ? String(parts[2]) : "servidor"
    }
}
