import Darwin
import Foundation

/// Script SSH_ASKPASS: repassa cada pedido do ssh (senha, passphrase, código 2FA) ao app
/// por um FIFO privado e espera a resposta por outro. O segredo nunca aparece em argumentos,
/// variáveis de ambiente ou arquivos em disco. Confirmações (yes/no) são sempre recusadas.
public enum Askpass {
    public static let script = """
    #!/bin/sh
    # Rosen askpass — conversa com o app por FIFOs privados.
    case "$1" in
      *"(yes/no"*|*fingerprint*) exit 1 ;;
    esac
    if ! { [ -p "$ROSEN_ASKPASS_REQ" ] && [ -p "$ROSEN_ASKPASS_RESP" ]; }; then
      # Sessão num terminal e o Rosen já não escuta: pergunta no próprio terminal.
      [ "$ROSEN_ASKPASS_TTY" = 1 ] || exit 1
      printf '%s' "$1" > /dev/tty 2>/dev/null || exit 1
      stty -echo < /dev/tty 2>/dev/null
      IFS= read -r line < /dev/tty; status=$?
      stty echo < /dev/tty 2>/dev/null
      printf '\n' > /dev/tty
      [ $status -eq 0 ] || exit 1
      printf '%s\n' "$line"
      exit 0
    fi
    prompt=$(printf '%s' "$1" | tr '\r\n' '  ')
    printf '%s\n' "$prompt" > "$ROSEN_ASKPASS_REQ" || exit 1
    IFS= read -r line < "$ROSEN_ASKPASS_RESP" || exit 1
    case "$line" in
      OK:*) printf '%s\n' "${line#OK:}"; exit 0 ;;
    esac
    exit 1
    """

    /// Grava (ou atualiza) o script e devolve o caminho.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("askpass.sh")
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// O que o ssh está pedindo.
public enum AskpassPrompt: Equatable, Sendable {
    case password
    /// Passphrase de uma chave; o caminho vem do texto do ssh quando disponível.
    case passphrase(keyPath: String?)
    /// Outro pedido do servidor (ex.: código de verificação 2FA). Nunca é salvo.
    case other

    public static func classify(_ prompt: String) -> AskpassPrompt {
        let l = prompt.lowercased()
        if l.contains("passphrase") {
            // "Enter passphrase for key '/Users/x/.ssh/id_ed25519':"
            if let start = prompt.range(of: "'"), let end = prompt.range(of: "'", options: .backwards),
               start.upperBound < end.lowerBound {
                return .passphrase(keyPath: String(prompt[start.upperBound..<end.lowerBound]))
            }
            // "Enter passphrase for /Users/x/.ssh/id_ed25519:" (sem aspas)
            if let forRange = prompt.range(of: " for ", options: .backwards) {
                var path = String(prompt[forRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("key ") { path.removeFirst(4) }
                if path.hasSuffix(":") { path.removeLast() }
                if path.hasPrefix("/") || path.hasPrefix("~") { return .passphrase(keyPath: path) }
            }
            return .passphrase(keyPath: nil)
        }
        if l.contains("password") || l.contains("senha") { return .password }
        return .other
    }

    /// Sem ver a saída do ssh (sessão num terminal), o próximo pedido diz se o anterior deu certo:
    /// o mesmo pedido de novo é uma recusa; um pedido diferente (ex.: senha → código 2FA) é um aceite.
    public static func previousWasAccepted(previous: AskpassPrompt, next: AskpassPrompt) -> Bool {
        switch (previous, next) {
        case (.password, .password), (.other, .other): return false
        case (.passphrase(let a), .passphrase(let b)): return a != b
        default: return true
        }
    }
}

/// Diretório temporário privado (0700) para uma conexão.
public final class ConnectionWorkspace: @unchecked Sendable {
    public let url: URL

    public init() throws {
        let base = FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("rosen-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Grava uma chave privada temporária (0600).
    public func writeKey(_ content: String) throws -> URL {
        let file = url.appendingPathComponent("id_\(UUID().uuidString.prefix(6))")
        var text = content.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n"
        FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return file
    }

    public func remove(_ file: URL) {
        // Sobrescreve antes de apagar.
        if let handle = FileHandle(forWritingAtPath: file.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            handle.write(Data(repeating: 0, count: size))
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: file)
    }

    public func destroy() {
        if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            items.forEach(remove)
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Lado do app da conversa com o askpass: recebe os pedidos e devolve as respostas.
public final class AskpassBroker: @unchecked Sendable {
    /// Recebe o texto do pedido e uma função para responder (`nil` = recusar).
    public typealias Handler = @Sendable (_ prompt: String, _ reply: @escaping @Sendable (String?) -> Void) -> Void

    public let requestPath: String
    public let responsePath: String
    private let handler: Handler
    private let lock = NSLock()
    private var cancelled = false
    private var requestFD: Int32 = -1

    public init(in workspace: ConnectionWorkspace, handler: @escaping Handler) throws {
        requestPath = workspace.url.appendingPathComponent("ask.req").path
        responsePath = workspace.url.appendingPathComponent("ask.resp").path
        self.handler = handler
        for path in [requestPath, responsePath] {
            unlink(path)
            guard mkfifo(path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        // O_RDWR num FIFO não bloqueia e mantém um escritor aberto: o read() espera por linhas.
        requestFD = open(requestPath, O_RDWR)
        guard requestFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Variáveis que o ssh (e o askpass) precisam.
    public var environment: [String: String] {
        ["ROSEN_ASKPASS_REQ": requestPath, "ROSEN_ASKPASS_RESP": responsePath]
    }

    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "rosen.askpass"
        thread.start()
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let fd = requestFD
        lock.unlock()
        // Acorda o read() bloqueado.
        if fd >= 0 { _ = "\n".withCString { write(fd, $0, 1) } }
        // Libera um askpass que ainda esteja esperando resposta.
        send("CANCEL", timeout: 0.2)
        unlink(requestPath)
        unlink(responsePath)
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !isCancelled {
            let n = read(requestFD, &chunk, chunk.count)
            if n <= 0 { if errno == EINTR { continue }; break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !isCancelled else { break }
                let prompt = line.trimmingCharacters(in: .whitespaces)
                guard !prompt.isEmpty else { continue }
                handler(prompt) { [weak self] answer in
                    DispatchQueue.global(qos: .userInitiated).async {
                        self?.send(answer.map { "OK:" + $0 } ?? "CANCEL", timeout: 15)
                    }
                }
            }
        }
        close(requestFD)
    }

    /// Escreve uma linha no FIFO de resposta, esperando o askpass abrir para leitura.
    private func send(_ line: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var fd: Int32 = -1
        while fd < 0 && Date() < deadline {
            fd = open(responsePath, O_WRONLY | O_NONBLOCK)
            if fd < 0 { usleep(40_000) }
        }
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let data = Data((line.replacingOccurrences(of: "\n", with: "") + "\n").utf8)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        close(fd)
    }
}

public struct PortOccupant: Equatable, Sendable {
    /// `nil` quando o processo é de outro usuário (o lsof não o enxerga).
    public let pid: pid_t?
    public let name: String
}

public enum PortProbe {
    /// Se a porta estiver ocupada, devolve o nome do processo que a usa (ou "outro programa").
    public static func occupant(address: String, port: Int) -> String? {
        listener(address: address, port: port)?.name
    }

    /// Quem está escutando na porta, ou `nil` se ela estiver livre.
    public static func listener(address: String, port: Int) -> PortOccupant? {
        guard isBound(address: address, port: port) else { return nil }
        return processListening(on: port) ?? PortOccupant(pid: nil, name: "outro programa")
    }

    public static func isFree(_ port: Int) -> Bool {
        !isBound(address: "127.0.0.1", port: port)
    }

    /// Tenta dar bind na porta; se falhar com EADDRINUSE, alguém já está nela.
    public static func isBound(address: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let host: String
        switch address.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "*", "0.0.0.0": host = "0.0.0.0"
        case "localhost": host = "127.0.0.1"
        default: host = address
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false } // IPv6/hostname: não checamos

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }

    static func processListening(on port: Int) -> PortOccupant? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseLsof(String(decoding: data, as: UTF8.self))
    }

    /// Primeiro processo da saída `lsof -Fpc` (linhas `p<pid>` e `c<comando>`).
    static func parseLsof(_ output: String) -> PortOccupant? {
        var pid: pid_t?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) }
            if line.hasPrefix("c") { return PortOccupant(pid: pid, name: String(line.dropFirst())) }
        }
        return nil
    }
}
