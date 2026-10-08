import Darwin
import Foundation

/// Um `ssh` de túnel aberto pelo Rosen, encontrado na tabela de processos do usuário.
public struct TunnelProcess: Equatable, Sendable {
    public let pid: pid_t
    public let parentPID: pid_t
    /// Túnel de origem, pela marca no ambiente. `nil` em processos de versões que não marcavam.
    public let tunnelID: UUID?
    public let arguments: [String]

    /// Sobrou de um Rosen que fechou sem encerrá-lo (o pai virou o launchd).
    public var isOrphan: Bool { parentPID == 1 }

    /// Túnel de origem: pela marca ou, sem ela, pelo comando.
    public func tunnel(in tunnels: [Tunnel]) -> Tunnel? {
        if let id = tunnelID { return tunnels.first { $0.id == id } }
        return tunnels.first { SSHCommand.matches(arguments, tunnel: $0) }
    }
}

/// Encontra e encerra os `ssh` de túnel do Rosen, inclusive os que sobraram de uma sessão anterior.
public enum TunnelProcesses {
    /// Todos os `ssh` de túnel do Rosen deste usuário.
    public static func all() -> [TunnelProcess] {
        ProcessTable.userProcesses()
            .filter { $0.name == "ssh" }
            .compactMap { inspect($0.pid, parentPID: $0.parentPID) }
    }

    /// O processo é um `ssh` de túnel do Rosen?
    public static func inspect(_ pid: pid_t) -> TunnelProcess? {
        guard let entry = ProcessTable.userProcesses().first(where: { $0.pid == pid }), entry.name == "ssh" else { return nil }
        return inspect(pid, parentPID: entry.parentPID)
    }

    static func inspect(_ pid: pid_t, parentPID: pid_t) -> TunnelProcess? {
        guard let bytes = ProcessTable.procArgs(pid), let parsed = ProcessTable.parseProcArgs(bytes) else { return nil }
        let marker = parsed.environment[SSHCommand.tunnelMarker].flatMap(UUID.init(uuidString:))
        guard marker != nil || SSHCommand.isTunnelInvocation(parsed.arguments) else { return nil }
        return TunnelProcess(pid: pid, parentPID: parentPID, tunnelID: marker, arguments: parsed.arguments)
    }

    /// Encerra com SIGTERM e, se não sair em `grace` segundos, com SIGKILL. Bloqueia até terminar.
    @discardableResult
    public static func terminate(_ pids: [pid_t], grace: TimeInterval = 2) -> Bool {
        let targets = pids.filter { $0 > 1 }
        targets.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, targets.contains(where: isAlive) { usleep(50_000) }
        let survivors = targets.filter(isAlive)
        survivors.forEach { kill($0, SIGKILL) }
        if !survivors.isEmpty { usleep(150_000) }
        return !targets.contains(where: isAlive)
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Leitura da tabela de processos via sysctl (só os do usuário atual).
enum ProcessTable {
    struct Entry { let pid: pid_t; let parentPID: pid_t; let name: String }

    static func userProcesses() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { kp in
            var comm = kp.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(pid: kp.kp_proc.p_pid, parentPID: kp.kp_eproc.e_ppid, name: name)
        }
    }

    /// Bloco bruto de `KERN_PROCARGS2`: argc, caminho, argv e ambiente.
    static func procArgs(_ pid: pid_t) -> [UInt8]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Separa argumentos (sem o argv[0]) e ambiente de um bloco `KERN_PROCARGS2`.
    static func parseProcArgs(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var i = 4
        // Caminho do executável e o preenchimento de zeros que vem depois.
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        func next() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return s
        }

        var argv: [String] = []
        for _ in 0..<argc {
            guard let s = next() else { return nil }
            argv.append(s)
        }
        var env: [String: String] = [:]
        while let s = next(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return (Array(argv.dropFirst()), env)
    }
}
