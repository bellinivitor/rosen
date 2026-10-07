import Foundation

// MARK: - Servidor

/// Um destino SSH para abrir uma sessão interativa num terminal.
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Host SSH (pode ser um alias do ~/.ssh/config).
    public var host: String
    public var port: Int
    public var user: String
    public var credentialID: UUID?
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
        credentialID: UUID? = nil,
        tag: TagColor = .blue,
        extraOptions: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.credentialID = credentialID
        self.tag = tag
        self.extraOptions = extraOptions
        self.createdAt = createdAt
    }

    // Decodificação tolerante: campos novos não quebram cofres antigos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Server()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
        tag = try c.decodeIfPresent(TagColor.self, forKey: .tag) ?? d.tag
        extraOptions = try c.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public extension Server {
    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? "Novo servidor" : destination
    }

    /// Linha curta para listas: "deploy@srv.io" ou "deploy@srv.io:2222".
    var summary: String {
        let dest = destination.isEmpty ? "servidor" : destination
        return port == 22 ? dest : "\(dest):\(port)"
    }

    /// Um túnel novo apontando para este servidor, com a mesma credencial e opções.
    func makeTunnel() -> Tunnel {
        Tunnel(host: host, port: port, user: user, credentialID: credentialID, tag: tag, extraOptions: extraOptions)
    }
}
