import Foundation

/// Latência até o servidor SSH, medida por ping (ICMP).
/// Não abre conexões no SSH nem no destino, então não gera logs de login nem aciona fail2ban.
public enum Latency {
    public struct Target: Equatable, Sendable {
        public let host: String
        /// Há um bastion no meio (ProxyJump/ProxyCommand): o ping mediria só até ele.
        public let viaProxy: Bool
    }

    public enum Quality: Sendable { case good, fair, poor }

    /// Argumentos do `ssh -G`, que resolve aliases do ~/.ssh/config sem conectar.
    public static func sshConfigArguments(for t: Tunnel) -> [String] {
        var args = ["-G"]
        for option in t.extraOptions where !option.isEmpty { args += ["-o", option] }
        args += ["-p", String(t.port), t.destination]
        return args
    }

    /// Lê a saída do `ssh -G` (uma opção por linha, em minúsculas).
    public static func target(fromSSHConfig output: String) -> Target? {
        var host: String?
        var viaProxy = false
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": host = parts[1]
            case "proxyjump", "proxycommand": if parts[1].lowercased() != "none" { viaProxy = true }
            default: break
            }
        }
        guard let host, !host.isEmpty else { return nil }
        return Target(host: host, viaProxy: viaProxy)
    }

    /// Argumentos do `/sbin/ping`: uma tentativa, sem DNS reverso, espera de até 2 s.
    public static func pingArguments(host: String) -> [String] {
        ["-c", "1", "-n", "-W", "2000", host]
    }

    /// Extrai o tempo da resposta: "... time=23.456 ms".
    public static func milliseconds(fromPing output: String) -> Double? {
        guard let range = output.range(of: #"time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms"#, options: .regularExpression) else {
            return nil
        }
        let match = output[range]
        let digits = match.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    public static func quality(_ ms: Double) -> Quality {
        switch ms {
        case ..<100: return .good
        case ..<250: return .fair
        default: return .poor
        }
    }

    /// Valor exibido: média das últimas medições válidas, para o número não ficar pulando.
    public static func smoothed(_ samples: [Double?], window: Int = 3) -> Double? {
        let recent = samples.suffix(window).compactMap { $0 }
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }
}
