import CryptoKit
import Foundation
import Testing
@testable import RosenCore

@Suite("Parser de comandos ssh")
struct ParserTests {
    @Test func comandoClassico() throws {
        let p = try #require(SSHCommandParser.parse("ssh -N -L 3307:127.0.0.1:3306 usuario@seu-servidor.com"))
        #expect(p.hasForward)
        #expect(p.tunnel.kind == .local)
        #expect(p.tunnel.listenPort == 3307)
        #expect(p.tunnel.targetHost == "127.0.0.1")
        #expect(p.tunnel.targetPort == 3306)
        #expect(p.tunnel.user == "usuario")
        #expect(p.tunnel.host == "seu-servidor.com")
        #expect(p.tunnel.port == 22)
        #expect(p.tunnel.bindAddress == "127.0.0.1")
    }

    @Test func flagsAgrupadasEPortaEChave() throws {
        let p = try #require(SSHCommandParser.parse("$ ssh -fNL 0.0.0.0:5433:db.internal:5432 -p2222 -i ~/.ssh/prod deploy@1.2.3.4"))
        #expect(p.tunnel.bindAddress == "0.0.0.0")
        #expect(p.tunnel.listenPort == 5433)
        #expect(p.tunnel.targetHost == "db.internal")
        #expect(p.tunnel.port == 2222)
        #expect(p.identityFile == "~/.ssh/prod")
        #expect(p.tunnel.destination == "deploy@1.2.3.4")
    }

    @Test func remotoDinamicoEOpcoes() throws {
        let r = try #require(SSHCommandParser.parse("ssh -R 8080:localhost:3000 -J bastion -o Port=2200 -o ServerAliveInterval=5 me@host"))
        #expect(r.tunnel.kind == .remote)
        #expect(r.tunnel.bindAddress == "")
        #expect(r.tunnel.port == 2200)
        #expect(r.tunnel.extraOptions == ["ProxyJump=bastion"])

        let d = try #require(SSHCommandParser.parse("ssh -D 1080 -l root example.com"))
        #expect(d.tunnel.kind == .dynamic)
        #expect(d.tunnel.listenPort == 1080)
        #expect(d.tunnel.user == "root")
    }

    @Test func opcoesDepoisDoHostEUrl() throws {
        let p = try #require(SSHCommandParser.parse("ssh ssh://admin@[::1]:2022 -N -L 6380:[fe80::1]:6379"))
        #expect(p.tunnel.host == "::1")
        #expect(p.tunnel.port == 2022)
        #expect(p.tunnel.targetHost == "fe80::1")
        #expect(p.tunnel.listenPort == 6380)
    }

    @Test func textoInvalido() {
        #expect(SSHCommandParser.parse("mysql -h 127.0.0.1") == nil)
        #expect(SSHCommandParser.parse("ssh -N") == nil)
        #expect(SSHCommandParser.parse("") == nil)
    }

    @Test func idaEVoltaPeloComandoExibido() throws {
        let t = Tunnel(host: "srv.io", port: 2222, user: "ana", listenPort: 5433, targetHost: "db", targetPort: 5432,
                       extraOptions: ["ProxyJump=bastion"])
        let shown = SSHCommand.displayString(for: t, credential: nil)
        let p = try #require(SSHCommandParser.parse(shown))
        #expect(p.tunnel.host == t.host)
        #expect(p.tunnel.port == t.port)
        #expect(p.tunnel.listenPort == t.listenPort)
        #expect(p.tunnel.targetHost == t.targetHost)
        #expect(p.tunnel.extraOptions == t.extraOptions)
    }
}

@Suite("Comando ssh")
struct CommandTests {
    @Test func argumentosComChave() {
        let t = Tunnel(host: "h", user: "u", listenPort: 3307, targetPort: 3306)
        let args = SSHCommand.arguments(for: t, auth: .identityFile("/tmp/k"))
        #expect(args.contains("-L"))
        #expect(args.contains("127.0.0.1:3307:127.0.0.1:3306"))
        #expect(args.last == "u@h")
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
    }

    @Test func argumentosComSenhaNaoTemSegredo() {
        let t = Tunnel(host: "h", user: "u")
        let args = SSHCommand.arguments(for: t, auth: .password)
        #expect(args.contains("PubkeyAuthentication=no"))
        #expect(!args.joined().contains("segredo"))
    }

    @Test func opcoesDoUsuarioVemAntes() throws {
        let t = Tunnel(host: "h", extraOptions: ["ServerAliveInterval=60"])
        let args = SSHCommand.arguments(for: t, auth: .system)
        let user = try #require(args.firstIndex(of: "ServerAliveInterval=60"))
        let ours = try #require(args.firstIndex(of: "ServerAliveInterval=15"))
        #expect(user < ours)
    }

    @Test func remotoOmiteBindLoopback() {
        let t = Tunnel(host: "h", kind: .remote, bindAddress: "127.0.0.1", listenPort: 8080, targetHost: "localhost", targetPort: 3000)
        #expect(SSHCommand.forwardSpec(for: t, omitLoopbackBind: true) == "8080:localhost:3000")
    }
}

@Suite("Cofre criptografado")
struct VaultTests {
    @Test func idaEVolta() throws {
        let key = SymmetricKey(size: .bits256)
        let payload = VaultPayload(
            tunnels: [Tunnel(name: "Prod", host: "x")],
            credentials: [Credential(name: "c", kind: .password, password: "s3nh@")]
        )
        let sealed = try Vault.seal(payload, key: key)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("s3nh@"))
        let opened = try Vault.open(sealed, key: key)
        #expect(opened.credentials.first?.password == "s3nh@")
        #expect(opened.tunnels.first?.name == "Prod")
    }

    @Test func chaveErradaOuAdulterado() throws {
        let sealed = try Vault.seal(VaultPayload(), key: SymmetricKey(size: .bits256))
        #expect(throws: VaultError.corrupted) { try Vault.open(sealed, key: SymmetricKey(size: .bits256)) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: VaultError.self) { try Vault.open(tampered, key: SymmetricKey(size: .bits256)) }
    }

    @Test func protecaoPorDigital() throws {
        // Cofres antigos não têm o campo: continua desprotegido.
        let old = try JSONDecoder().decode(Credential.self, from: Data(#"{"name":"x","kind":"password","password":"p"}"#.utf8))
        #expect(old.requireUserPresence == false)
        #expect(old.needsUnlock == false)

        var c = Credential(kind: .keyFile, keyPath: "~/.ssh/id", requireUserPresence: true)
        #expect(c.needsUnlock == false) // arquivo sem passphrase: nada guardado
        c.passphrase = "frase"
        #expect(c.needsUnlock)
        let key = SymmetricKey(size: .bits256)
        let opened = try Vault.open(Vault.seal(VaultPayload(credentials: [c]), key: key), key: key)
        #expect(opened.credentials.first?.requireUserPresence == true)
    }

    @Test func migraCofreAntigo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = Vault(url: dir.appendingPathComponent("old/vault.burrow"), keyProvider: StaticKeyProvider(key: SymmetricKey(size: .bits256)))
        let fresh = Vault(url: dir.appendingPathComponent("new/vault.rosen"), keyProvider: StaticKeyProvider(key: SymmetricKey(size: .bits256)))
        #expect(try fresh.migrate(from: legacy) == nil) // nada para migrar

        let payload = VaultPayload(tunnels: [Tunnel(name: "Prod", host: "db")],
                                   credentials: [Credential(kind: .password, password: "x", requireUserPresence: true)])
        try legacy.save(payload)
        let stored = try #require(try legacy.load()) // datas com a precisão do disco
        #expect(stored.tunnels.map(\.id) == payload.tunnels.map(\.id))
        #expect(try fresh.migrate(from: legacy) == stored)
        #expect(try fresh.load() == stored)
        #expect(try fresh.migrate(from: legacy) == nil) // não sobrescreve um cofre que já existe
    }

    @Test func arquivoNoDisco() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = Vault(url: dir.appendingPathComponent("v.rosen"), keyProvider: StaticKeyProvider(key: SymmetricKey(size: .bits256)))
        #expect(try vault.load() == nil)
        try vault.save(VaultPayload(tunnels: [Tunnel(host: "a")]))
        #expect(try vault.load()?.tunnels.count == 1)
        let perms = try FileManager.default.attributesOfItem(atPath: vault.url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("Logs do ssh")
struct LogTests {
    @Test func eventos() {
        #expect(SSHLog.classify("Authenticated to srv ([1.2.3.4]:22) using \"publickey\".") == .authenticated)
        #expect(SSHLog.classify("debug1: Local connections to LOCALHOST:3307 forwarded to remote address 127.0.0.1:3306") == .forwardReady)
        if case .fatal = SSHLog.classify("u@h: Permission denied (publickey,password).") {} else { Issue.record("esperava fatal") }
        if case .transient = SSHLog.classify("ssh: Could not resolve hostname nope: nodename nor servname provided") {} else { Issue.record("esperava transient") }
        if case .warning = SSHLog.classify("channel 2: open failed: connect failed: Connection refused") {} else { Issue.record("esperava warning") }
        #expect(SSHLog.classify("debug1: Reading configuration data /etc/ssh/ssh_config") == .noise)
    }
}

@Suite("Infra")
struct InfraTests {
    /// Roda o askpass como o ssh faria e devolve (saída, código de saída).
    private func ask(_ script: URL, _ prompt: String, env: [String: String]) throws -> (String, Int32) {
        let p = Process()
        p.executableURL = script
        p.arguments = [prompt]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }

    @Test func askpassConversaComOApp() throws {
        let ws = try ConnectionWorkspace()
        defer { ws.destroy() }
        let seen = Locked<[String]>([])
        let broker = try AskpassBroker(in: ws) { prompt, reply in
            seen.mutate { $0.append(prompt) }
            reply(prompt.contains("Password") ? "s3nh@ com espaço" : nil)
        }
        broker.start()
        defer { broker.cancel() }
        let script = try Askpass.install(in: ws.url)

        let (out, code) = try ask(script, "(ana@host) Password:", env: broker.environment)
        #expect(code == 0)
        #expect(out == "s3nh@ com espaço\n")

        // O app recusou → askpass falha.
        let (_, refused) = try ask(script, "Verification code:", env: broker.environment)
        #expect(refused == 1)

        // Confirmação de host: recusada sem nem perguntar ao app.
        let (_, confirm) = try ask(script, "Are you sure you want to continue connecting (yes/no/[fingerprint])?", env: broker.environment)
        #expect(confirm == 1)
        #expect(seen.value == ["(ana@host) Password:", "Verification code:"])
    }

    @Test func classificaPedidos() {
        #expect(AskpassPrompt.classify("(ana@host) Password:") == .password)
        #expect(AskpassPrompt.classify("Enter passphrase for key '/Users/ana/.ssh/id_ed25519': ")
                == .passphrase(keyPath: "/Users/ana/.ssh/id_ed25519"))
        #expect(AskpassPrompt.classify("Enter passphrase:") == .passphrase(keyPath: nil))
        #expect(AskpassPrompt.classify("Bad passphrase, try again for /Users/ana/.ssh/id_rsa: ")
                == .passphrase(keyPath: "/Users/ana/.ssh/id_rsa"))
        #expect(AskpassPrompt.classify("Verification code:") == .other)
    }

    @Test func portaOcupada() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        #expect(PortProbe.occupant(address: "127.0.0.1", port: port) != nil)
    }
}

/// Caixinha thread-safe para os testes.
final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
