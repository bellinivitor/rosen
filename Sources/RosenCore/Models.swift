import Foundation

// MARK: - Tipo de encaminhamento

public enum ForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, remote, dynamic

    public var id: String { rawValue }

    public var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    public var title: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remoto"
        case .dynamic: return "SOCKS"
        }
    }

    public var explanation: String {
        switch self {
        case .local:
            return "Traz um serviço do servidor para o seu Mac. Ex.: acessar o PostgreSQL remoto em 127.0.0.1."
        case .remote:
            return "Expõe um serviço do seu Mac dentro do servidor. Ex.: mostrar seu app local para o servidor."
        case .dynamic:
            return "Cria um proxy SOCKS5 no seu Mac que navega pela rede do servidor."
        }
    }
}

public enum TagColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, gray
    public var id: String { rawValue }
}

// MARK: - Túnel

public struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Host SSH (pode ser um alias do ~/.ssh/config).
    public var host: String
    public var port: Int
    public var user: String
    public var kind: ForwardKind
    /// Endereço onde o túnel escuta (no Mac para -L/-D, no servidor para -R).
    public var bindAddress: String
    /// Porta onde o túnel escuta.
    public var listenPort: Int
    /// Destino final (ignorado em SOCKS).
    public var targetHost: String
    public var targetPort: Int
    public var credentialID: UUID?
    public var autoConnect: Bool
    public var autoReconnect: Bool
    public var tag: TagColor
    /// Opções extras no formato `Chave=Valor` (viram `-o Chave=Valor`).
    public var extraOptions: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        user: String = "",
        kind: ForwardKind = .local,
        bindAddress: String = "127.0.0.1",
        listenPort: Int = 5433,
        targetHost: String = "127.0.0.1",
        targetPort: Int = 5432,
        credentialID: UUID? = nil,
        autoConnect: Bool = false,
        autoReconnect: Bool = true,
        tag: TagColor = .blue,
        extraOptions: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.credentialID = credentialID
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.tag = tag
        self.extraOptions = extraOptions
        self.createdAt = createdAt
    }

    // Decodificação tolerante: campos novos não quebram cofres antigos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Tunnel()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? d.kind
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? d.listenPort
        targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? d.targetHost
        targetPort = try c.decodeIfPresent(Int.self, forKey: .targetPort) ?? d.targetPort
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? d.autoConnect
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        tag = try c.decodeIfPresent(TagColor.self, forKey: .tag) ?? d.tag
        extraOptions = try c.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public extension Tunnel {
    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    var serviceName: String? {
        kind == .dynamic ? "Proxy SOCKS" : ServiceCatalog.name(for: targetPort)
    }

    var suggestedName: String {
        let server = host.isEmpty ? "servidor" : host
        switch kind {
        case .dynamic: return "SOCKS via \(server)"
        case .remote: return "Porta \(listenPort) em \(server)"
        case .local:
            if let service = ServiceCatalog.name(for: targetPort) { return "\(service) em \(server)" }
            return "Porta \(targetPort) em \(server)"
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    /// Endereço que um cliente usa para falar com o túnel (ex.: 127.0.0.1:5433).
    var clientAddress: String {
        let b = bindAddress.trimmingCharacters(in: .whitespaces)
        let h = (b.isEmpty || b == "0.0.0.0" || b == "*" || b == "localhost") ? "127.0.0.1" : b
        return "\(h.contains(":") ? "[\(h)]" : h):\(listenPort)"
    }

    var targetAddress: String {
        "\(targetHost.contains(":") ? "[\(targetHost)]" : targetHost):\(targetPort)"
    }

    /// Linha curta para listas.
    var summary: String {
        switch kind {
        case .local: return "\(clientAddress) → \(targetAddress)"
        case .remote: return "servidor:\(listenPort) → \(targetAddress)"
        case .dynamic: return "SOCKS em \(clientAddress)"
        }
    }

    /// Versão curta para listas estreitas: ":5433 → :5432" ou ":6380 → 10.0.0.12:6379".
    var compactSummary: String {
        let target = SSHCommand.isLoopback(targetHost) ? ":\(targetPort)" : targetAddress
        switch kind {
        case .local: return ":\(listenPort) → \(target)"
        case .remote: return "servidor :\(listenPort) → \(target)"
        case .dynamic: return "SOCKS em :\(listenPort)"
        }
    }

    /// Duas configurações ocupam a mesma porta local?
    func conflicts(with other: Tunnel) -> Bool {
        guard id != other.id, kind != .remote, other.kind != .remote else { return false }
        return listenPort == other.listenPort
    }
}

// MARK: - Credencial

public enum CredentialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyFile, keyContent, password, agent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keyFile: return "Arquivo"
        case .keyContent: return "Chave salva"
        case .password: return "Senha"
        case .agent: return "ssh-agent"
        }
    }

    public var longTitle: String {
        switch self {
        case .keyFile: return "Arquivo de chave privada"
        case .keyContent: return "Chave privada no cofre"
        case .password: return "Senha"
        case .agent: return "ssh-agent / ~/.ssh/config"
        }
    }

    public var explanation: String {
        switch self {
        case .keyFile:
            return "Aponta para um arquivo de chave (ex.: ~/.ssh/id_ed25519). A passphrase, se houver, fica no cofre criptografado."
        case .keyContent:
            return "O conteúdo da chave fica dentro do cofre criptografado do Rosen. Ao conectar, ela é gravada num arquivo temporário privado e apagada logo após a autenticação."
        case .password:
            return "A senha fica no cofre criptografado e é entregue ao ssh por um canal privado (FIFO), nunca por argumento ou variável de ambiente."
        case .agent:
            return "Usa as chaves carregadas no ssh-agent ou definidas no ~/.ssh/config. Nada é armazenado."
        }
    }
}

public struct Credential: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CredentialKind
    public var keyPath: String
    public var keyContent: String
    public var passphrase: String
    public var password: String
    /// Exige Touch ID (ou a senha do Mac) antes de usar ou mostrar os segredos.
    public var requireUserPresence: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: CredentialKind = .keyFile,
        keyPath: String = "",
        keyContent: String = "",
        passphrase: String = "",
        password: String = "",
        requireUserPresence: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.keyPath = keyPath
        self.keyContent = keyContent
        self.passphrase = passphrase
        self.password = password
        self.requireUserPresence = requireUserPresence
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .agent
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        keyContent = try c.decodeIfPresent(String.self, forKey: .keyContent) ?? ""
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        requireUserPresence = try c.decodeIfPresent(Bool.self, forKey: .requireUserPresence) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public extension Credential {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .keyFile where !keyPath.isEmpty: return (keyPath as NSString).lastPathComponent
        default: return kind.longTitle
        }
    }

    var detail: String {
        switch kind {
        case .keyFile: return keyPath.isEmpty ? "Nenhum arquivo escolhido" : Paths.abbreviate(keyPath)
        case .keyContent: return keyContent.isEmpty ? "Nenhuma chave colada" : "\(SSHKeyInspector.keyType(of: keyContent)), criptografada"
        case .password: return password.isEmpty ? "Pergunta ao conectar" : "Senha criptografada"
        case .agent: return "Chaves do sistema"
        }
    }

    /// Há algo secreto guardado no cofre (passphrase, chave ou senha)?
    var hasStoredSecret: Bool {
        switch kind {
        case .keyFile: return !passphrase.isEmpty
        case .keyContent: return !keyContent.isEmpty
        case .password: return !password.isEmpty
        case .agent: return false
        }
    }

    /// Precisa de Touch ID / senha do Mac antes de ser usada.
    var needsUnlock: Bool { requireUserPresence && hasStoredSecret }

    /// Problema que impede o uso, se houver.
    var problem: String? {
        switch kind {
        case .keyFile:
            if keyPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Escolha o arquivo da chave." }
            switch SSHKeyInspector.inspect(path: Paths.expand(keyPath)) {
            case .ok: return nil
            case .missing: return "Arquivo não encontrado."
            case .unreadable: return "Sem permissão para ler o arquivo."
            case .publicKey: return "Esse arquivo é a chave pública (.pub). Escolha a privada."
            case .notAKey: return "O arquivo não parece uma chave privada."
            }
        case .keyContent:
            if keyContent.isEmpty { return "Cole o conteúdo da chave privada." }
            return SSHKeyInspector.looksLikePrivateKey(keyContent) ? nil : "O texto não parece uma chave privada."
        case .password:
            return nil // em branco: o Rosen pergunta ao conectar
        case .agent:
            return nil
        }
    }
}

// MARK: - Payload do cofre

public struct VaultPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var tunnels: [Tunnel]
    public var credentials: [Credential]

    public init(version: Int = 1, tunnels: [Tunnel] = [], credentials: [Credential] = []) {
        self.version = version
        self.tunnels = tunnels
        self.credentials = credentials
    }
}

// MARK: - Utilidades

public enum Paths {
    public static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    public static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

public enum ServiceCatalog {
    public enum Category: Sendable { case database, web, terminal, desktop, generic }

    private static let names: [Int: String] = [
        3306: "MySQL", 33060: "MySQL X", 5432: "PostgreSQL", 6379: "Redis",
        27017: "MongoDB", 1433: "SQL Server", 1521: "Oracle", 9200: "Elasticsearch",
        5672: "RabbitMQ", 15672: "RabbitMQ Admin", 11211: "Memcached", 8123: "ClickHouse",
        9000: "HTTP", 80: "HTTP", 8080: "HTTP", 8000: "HTTP", 3000: "HTTP", 5000: "HTTP",
        443: "HTTPS", 8443: "HTTPS", 22: "SSH", 5900: "VNC", 3389: "RDP",
        2375: "Docker", 2376: "Docker", 6443: "Kubernetes", 9090: "Prometheus", 3100: "Loki",
    ]

    public static func name(for port: Int) -> String? { names[port] }

    public static func category(for port: Int) -> Category {
        switch port {
        case 3306, 33060, 5432, 6379, 27017, 1433, 1521, 9200, 11211, 8123: return .database
        case 80, 443, 8080, 8000, 8443, 3000, 5000, 9000, 9090, 3100, 15672: return .web
        case 22, 2375, 2376, 6443: return .terminal
        case 5900, 3389: return .desktop
        default: return .generic
        }
    }
}
