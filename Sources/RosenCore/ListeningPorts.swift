import Darwin
import Foundation

/// Um socket TCP em escuta, como o `lsof` mostra.
public struct ListeningSocket: Equatable, Sendable {
    public let address: String
    public let port: Int
    public let pid: pid_t
    /// Nome do processo segundo o lsof.
    public let command: String
}

/// Uma porta em uso por um processo, já com quem é o dono.
public struct PortEntry: Identifiable, Equatable, Sendable {
    public enum Owner: Equatable, Sendable {
        /// `ssh` de túnel do Rosen.
        case rosen(TunnelProcess)
        /// Programa do usuário (Docker, Postgres, Node…).
        case user
        /// Serviço do macOS ou de outro usuário.
        case system
    }

    public let port: Int
    /// Endereços em que escuta (ex.: 127.0.0.1 e ::1).
    public let addresses: [String]
    /// Processos que escutam na porta (ex.: o master e os workers do nginx).
    public let pids: [pid_t]
    public let name: String
    /// Caminho do executável, quando o sistema deixa ler.
    public let path: String?
    public let owner: Owner

    public init(port: Int, addresses: [String], pids: [pid_t], name: String, path: String?, owner: Owner) {
        self.port = port
        self.addresses = addresses
        self.pids = pids
        self.name = name
        self.path = path
        self.owner = owner
    }

    /// Processo principal: o de menor PID (no nginx, o master).
    public var pid: pid_t { pids.min() ?? 0 }
    public var id: String { "\(port)-\(pid)" }

    /// Aceita conexões de outras máquinas da rede (não só deste Mac).
    public var isExposed: Bool { addresses.contains { !Self.isLoopback($0) } }

    /// O `.app` que contém o executável (ex.: o Docker para o `com.docker.backend`).
    public var appBundlePath: String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost"
    }
}

public enum ListeningPorts {
    /// Todas as portas TCP em escuta no Mac, agrupadas por porta e processo.
    /// Usa o `lsof`: dentro de um app o `netstat` não enxerga os sockets. Sem root, só aparecem
    /// os processos do próprio usuário (serviços do sistema que rodam como root ficam de fora).
    public static func scan() -> [PortEntry] {
        guard let output = run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }
        return entries(from: parseLsof(output)) { pid in
            let path = ProcessTable.executablePath(pid)
            let owner: PortEntry.Owner
            if path.map(isSystemPath) == true {
                owner = .system
            } else if let tunnel = TunnelProcesses.inspect(pid) {
                owner = .rosen(tunnel)
            } else {
                owner = .user
            }
            return (path, owner)
        }
    }

    /// Junta numa linha os sockets do mesmo programa na mesma porta (IPv4 + IPv6, master + workers).
    static func entries(from sockets: [ListeningSocket],
                        describe: (pid_t) -> (path: String?, owner: PortEntry.Owner)) -> [PortEntry] {
        var described: [pid_t: (path: String?, owner: PortEntry.Owner)] = [:]
        var order: [String] = []
        var grouped: [String: [ListeningSocket]] = [:]
        for s in sockets {
            let info = described[s.pid] ?? describe(s.pid)
            described[s.pid] = info
            let key = "\(s.port)|\(info.path ?? s.command)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(s)
        }
        return order.compactMap { key -> PortEntry? in
            guard let group = grouped[key], let first = group.first, let info = described[first.pid] else { return nil }
            var addresses: [String] = []
            var pids: [pid_t] = []
            for s in group {
                if !addresses.contains(s.address) { addresses.append(s.address) }
                if !pids.contains(s.pid) { pids.append(s.pid) }
            }
            let name = info.path.map { ($0 as NSString).lastPathComponent } ?? first.command
            return PortEntry(port: first.port, addresses: addresses, pids: pids.sorted(),
                             name: name, path: info.path, owner: info.owner)
        }
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }
    }

    // MARK: - lsof

    /// Saída de `lsof -Fpcn`: `p<pid>`, `c<comando>` e um `n<endereço:porta>` por socket.
    static func parseLsof(_ output: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        var pid: pid_t?
        var command = ""
        for raw in output.split(separator: "\n") {
            let value = String(raw.dropFirst())
            switch raw.first {
            case "p": pid = pid_t(value); command = ""
            case "c": command = value
            case "n":
                guard let pid, let (address, port) = splitAddress(value) else { continue }
                sockets.append(ListeningSocket(address: address, port: port, pid: pid, command: command))
            default: break
            }
        }
        return sockets
    }

    /// `127.0.0.1:5433` → (127.0.0.1, 5433); `*:80` → (*, 80); `[::1]:5432` → (::1, 5432).
    static func splitAddress(_ s: String) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        var address = String(s[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        return (address, port)
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension ProcessTable {
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
