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

@Suite("Servidores")
struct ServerTests {
    @Test func cofreAntigoSemServidores() throws {
        let json = #"{"version":1,"tunnels":[{"name":"Prod","host":"db"}],"credentials":[]}"#
        let payload = try JSONDecoder().decode(VaultPayload.self, from: Data(json.utf8))
        #expect(payload.servers.isEmpty)
        #expect(payload.tunnels.first?.name == "Prod")
    }

    @Test func idaEVoltaNoCofre() throws {
        let key = SymmetricKey(size: .bits256)
        let cred = UUID()
        let s = Server(name: "Web", host: "srv.io", port: 2222, user: "ana", credentialID: cred,
                       tag: .green, extraOptions: ["ProxyJump=bastion"])
        let opened = try Vault.open(Vault.seal(VaultPayload(servers: [s]), key: key), key: key)
        let back = try #require(opened.servers.first)
        #expect(back.id == s.id)
        #expect(back.host == "srv.io")
        #expect(back.port == 2222)
        #expect(back.user == "ana")
        #expect(back.credentialID == cred)
        #expect(back.tag == .green)
        #expect(back.extraOptions == ["ProxyJump=bastion"])
    }

    @Test func servidorParcialUsaPadroes() throws {
        let s = try JSONDecoder().decode(Server.self, from: Data(#"{"host":"x"}"#.utf8))
        #expect(s.port == 22)
        #expect(s.user == "")
        #expect(s.credentialID == nil)
        #expect(s.extraOptions.isEmpty)
    }

    @Test func nomesEResumo() {
        #expect(Server().displayName == "Novo servidor")
        #expect(Server(host: "srv.io").displayName == "srv.io")
        #expect(Server(host: "srv.io", user: "ana").displayName == "ana@srv.io")
        #expect(Server(name: " Web ", host: "srv.io").displayName == "Web")
        #expect(Server(host: "srv.io", user: "ana").summary == "ana@srv.io")
        #expect(Server(host: "srv.io", port: 2222).summary == "srv.io:2222")
    }

    @Test func tunelAPartirDoServidor() {
        let cred = UUID()
        let s = Server(host: "srv.io", port: 2222, user: "ana", credentialID: cred, tag: .red, extraOptions: ["A=b"])
        let t = s.makeTunnel()
        #expect(t.host == "srv.io")
        #expect(t.port == 2222)
        #expect(t.user == "ana")
        #expect(t.credentialID == cred)
        #expect(t.tag == .red)
        #expect(t.extraOptions == ["A=b"])
        #expect(t.id != s.id)
    }
}

@Suite("Sessão interativa")
struct InteractiveTests {
    @Test func argumentosInterativos() {
        let s = Server(host: "srv.io", port: 2222, user: "ana", extraOptions: ["ProxyJump=bastion"])
        let args = SSHCommand.interactiveArguments(for: s, auth: .identityFile("/tmp/k"))
        #expect(args.first == "-t")
        #expect(!args.contains("-N"))
        #expect(!args.contains("-v"))
        #expect(!args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.suffix(3) == ["-p", "2222", "ana@srv.io"])
        let i = try! #require(args.firstIndex(of: "-i"))
        #expect(args[i + 1] == "/tmp/k")
        #expect(args.contains("IdentitiesOnly=yes"))
        // Opções do usuário vêm antes das do Rosen.
        #expect(args.firstIndex(of: "ProxyJump=bastion")! < args.firstIndex(of: "ServerAliveInterval=15")!)
    }

    @Test func argumentosComSenhaOuAgente() {
        let s = Server(host: "h")
        let pw = SSHCommand.interactiveArguments(for: s, auth: .password)
        #expect(pw.contains("PubkeyAuthentication=no"))
        #expect(!pw.contains("-i"))
        let agent = SSHCommand.interactiveArguments(for: s, auth: .system)
        #expect(!agent.contains("-i"))
        #expect(!agent.contains("PubkeyAuthentication=no"))
        #expect(agent.last == "h")
    }

    @Test func comandoExibido() {
        let s = Server(host: "srv.io", port: 2222, user: "ana", extraOptions: ["ProxyJump=bastion"])
        let key = Credential(kind: .keyFile, keyPath: "/tmp/minha chave")
        #expect(SSHCommand.displayString(for: s, credential: key) == "ssh -p 2222 -i '/tmp/minha chave' -o ProxyJump=bastion ana@srv.io")
        #expect(SSHCommand.displayString(for: Server(host: "h"), credential: nil) == "ssh h")
        #expect(SSHCommand.displayString(for: Server(), credential: Credential(kind: .keyContent)) == "ssh -i <chave-do-cofre> usuario@servidor")
    }

    @Test func servidorAPartirDeComando() throws {
        let p = try #require(SSHCommandParser.parse("ssh -p 2222 -i ~/.ssh/k -J bastion deploy@srv.io"))
        let s = p.server
        #expect(s.host == "srv.io")
        #expect(s.port == 2222)
        #expect(s.user == "deploy")
        #expect(s.extraOptions == ["ProxyJump=bastion"])
        #expect(p.identityFile == "~/.ssh/k")

        let withForward = try #require(SSHCommandParser.parse("ssh -N -L 5433:127.0.0.1:5432 root@db.io"))
        #expect(withForward.server.host == "db.io")
        #expect(withForward.server.port == 22)

        let v6 = try #require(SSHCommandParser.parse("ssh ssh://admin@[::1]:2022"))
        #expect(v6.server.host == "::1")
        #expect(v6.server.port == 2022)
        #expect(v6.server.user == "admin")
    }
}

@Suite("~/.ssh/config")
struct SSHConfigTests {
    @Test func blocosBasicos() {
        let text = """
        # comentário
        Host prod
            HostName 10.0.0.5
            User deploy
            Port 2222
            IdentityFile ~/.ssh/prod
            ProxyJump bastion

        Host web staging   # dois aliases
          hostname=web.internal
          USER = "ana"
        """
        let hosts = SSHConfigParser.parse(text)
        #expect(hosts.map(\.alias) == ["prod", "web", "staging"])
        let prod = hosts[0]
        #expect(prod.hostName == "10.0.0.5")
        #expect(prod.user == "deploy")
        #expect(prod.port == 2222)
        #expect(prod.identityFile == "~/.ssh/prod")
        #expect(prod.proxyJump == "bastion")
        #expect(prod.summary == "deploy@10.0.0.5:2222 via bastion")
        #expect(hosts[1].hostName == "web.internal")
        #expect(hosts[2].user == "ana")
        #expect(hosts[1].port == nil)
    }

    @Test func curingasEMatchIgnorados() {
        let text = """
        Host *
            User root
        Host *.corp !foo db?
            User x
        Match host foo
            User y
        Host real
            HostName r.io
        """
        let hosts = SSHConfigParser.parse(text)
        #expect(hosts.map(\.alias) == ["real"])
        #expect(hosts[0].user == nil)

        // Opções depois de um Match não vazam para o Host anterior.
        let after = SSHConfigParser.parse("Host real\nMatch user x\n  User vazou")
        #expect(after.first?.user == nil)
    }

    @Test func primeiroValorVence() {
        let text = """
        Host a
            User um
            User dois
        Host a
            User tres
            Port 2200
        """
        let hosts = SSHConfigParser.parse(text)
        #expect(hosts.count == 1)
        #expect(hosts[0].user == "um")
        #expect(hosts[0].port == 2200)
    }

    @Test func include() {
        let text = """
        Include conf.d/*
        Host principal
        """
        let hosts = SSHConfigParser.parse(text) { pattern in
            pattern == "conf.d/*" ? ["Host incluido\n  User z"] : []
        }
        #expect(hosts.map(\.alias) == ["incluido", "principal"])
        #expect(hosts[0].user == "z")
    }

    @Test func includeCircularNaoTravas() {
        let hosts = SSHConfigParser.parse("Include self\nHost x") { _ in ["Include self\nHost x"] }
        #expect(hosts.map(\.alias) == ["x"])
    }

    @Test func viraServidor() {
        let s = SSHConfigHost(alias: "prod", hostName: "10.0.0.5", user: "deploy", port: 2222, proxyJump: "b").server
        #expect(s.name == "prod")
        #expect(s.host == "prod")
        #expect(s.user == "deploy")
        #expect(s.port == 2222)
        #expect(s.extraOptions.isEmpty) // o ssh lê ProxyJump do próprio config
        #expect(SSHConfigHost(alias: "x").server.port == 22)
    }

    @Test func arquivoNoDisco() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        try "Include conf.d/*.conf\nHost a".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host b".write(to: dir.appendingPathComponent("conf.d/1.conf"), atomically: true, encoding: .utf8)
        try "Host c".write(to: dir.appendingPathComponent("conf.d/2.txt"), atomically: true, encoding: .utf8)
        #expect(SSHConfigParser.load(from: dir.appendingPathComponent("config"))?.map(\.alias) == ["b", "a"])
        #expect(SSHConfigParser.load(from: dir.appendingPathComponent("nada")) == nil)
    }
}

@Suite("Terminal")
struct TerminalTests {
    @Test func scriptDeConexao() {
        let script = ConnectScript.make(
            title: "Prod \u{1B}]0;x",
            arguments: ["-t", "-i", "/tmp/minha chave", "-o", "ProxyCommand=nc 'x' %h", "ana@srv.io"],
            environment: ["ROSEN_ASKPASS_REQ": "/tmp/a b/ask.req", "SSH_ASKPASS": "/x/askpass.sh"]
        )
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/sh")
        #expect(lines.contains("rm -f \"$0\""))
        #expect(lines.contains("export ROSEN_ASKPASS_REQ='/tmp/a b/ask.req'"))
        #expect(lines.contains("export SSH_ASKPASS=/x/askpass.sh"))
        #expect(lines.last == "exec /usr/bin/ssh -t -i '/tmp/minha chave' -o 'ProxyCommand=nc '\\''x'\\'' %h' ana@srv.io")
        #expect(!script.contains("\u{1B}"))
    }

    @Test func ambienteDoAskpass() {
        let env = ConnectScript.askpassEnvironment(askpassPath: "/a.sh", broker: ["ROSEN_ASKPASS_REQ": "r", "ROSEN_ASKPASS_RESP": "s"])
        #expect(env["SSH_ASKPASS"] == "/a.sh")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["ROSEN_ASKPASS_TTY"] == "1")
        #expect(env["ROSEN_ASKPASS_REQ"] == "r")
        #expect(env["ROSEN_ASKPASS_RESP"] == "s")
    }

    @Test func scriptRodaDeVerdadeESeApaga() throws {
        let ws = try ConnectionWorkspace()
        defer { ws.destroy() }
        // `ssh -V` só imprime a versão: prova que as aspas e o exec funcionam.
        let url = try ConnectScript.write(ConnectScript.make(title: "t", arguments: ["-V"], environment: ["X": "1 2"]), in: ws)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        let p = Process()
        p.executableURL = url
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("OpenSSH"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func terminais() {
        #expect(TerminalApp.warp.bundleIdentifier == "dev.warp.Warp-Stable")
        #expect(TerminalApp.terminal.bundleIdentifier == "com.apple.Terminal")
        #expect(TerminalApp(rawValue: "warp") == .warp)
    }
}

@Suite("Aceite sem ver a saída")
struct AcceptanceTests {
    @Test func proximoPedidoDecide() {
        #expect(!AskpassPrompt.previousWasAccepted(previous: .password, next: .password))
        #expect(AskpassPrompt.previousWasAccepted(previous: .password, next: .other))
        #expect(!AskpassPrompt.previousWasAccepted(previous: .passphrase(keyPath: "/k"), next: .passphrase(keyPath: "/k")))
        #expect(AskpassPrompt.previousWasAccepted(previous: .passphrase(keyPath: "/k"), next: .passphrase(keyPath: "/outra")))
        #expect(AskpassPrompt.previousWasAccepted(previous: .passphrase(keyPath: nil), next: .password))
        #expect(!AskpassPrompt.previousWasAccepted(previous: .other, next: .other))
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

@Suite("Latência")
struct LatencyTests {
    @Test func leSaidaDoSshG() throws {
        let out = """
        user deploy
        hostname 178.0.0.10
        port 2222
        proxyjump none
        """
        let t = try #require(Latency.target(fromSSHConfig: out))
        #expect(t.host == "178.0.0.10")
        #expect(!t.viaProxy)
        #expect(Latency.target(fromSSHConfig: "hostname db\nproxyjump bastion")?.viaProxy == true)
        #expect(Latency.target(fromSSHConfig: "user x") == nil)
    }

    @Test func leSaidaDoPing() {
        let ok = "64 bytes from 1.2.3.4: icmp_seq=0 ttl=52 time=23.456 ms"
        #expect(Latency.milliseconds(fromPing: ok) == 23.456)
        #expect(Latency.milliseconds(fromPing: "time<1 ms") == 1)
        #expect(Latency.milliseconds(fromPing: "Request timeout for icmp_seq 0") == nil)
    }

    @Test func qualidadeESuavizacao() {
        #expect(Latency.quality(40) == .good)
        #expect(Latency.quality(120) == .fair)
        #expect(Latency.quality(240) == .fair)
        #expect(Latency.quality(400) == .poor)
        #expect(Latency.smoothed([10, nil, 20, 30]) == 25)
        #expect(Latency.smoothed([nil, nil]) == nil)
    }

    @Test func argumentosDoSshG() {
        let t = Tunnel(host: "stage", port: 2200, user: "ana", extraOptions: ["ProxyJump=bastion"])
        #expect(Latency.sshConfigArguments(for: t) == ["-G", "-o", "ProxyJump=bastion", "-p", "2200", "ana@stage"])
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

        // Sem os FIFOs (Rosen não escuta) e fora de um terminal: falha em vez de travar.
        let (_, gone) = try ask(script, "Password:", env: ["ROSEN_ASKPASS_REQ": "/nao/existe", "ROSEN_ASKPASS_RESP": "/nao/existe"])
        #expect(gone == 1)
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
