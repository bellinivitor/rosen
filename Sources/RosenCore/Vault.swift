import CryptoKit
import Foundation
import Security

public enum VaultError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case missingKey
    case corrupted
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "código \(status)"
            return "Não foi possível acessar o Keychain: \(message)"
        case .missingKey:
            return "O cofre existe, mas a chave de criptografia não está no Keychain. Os dados não podem ser abertos."
        case .corrupted:
            return "O cofre está corrompido ou foi alterado fora do Rosen."
        case .unsupportedFormat:
            return "Formato de cofre desconhecido."
        }
    }
}

/// Fornece a chave simétrica do cofre.
public protocol VaultKeyProvider: Sendable {
    func key(createIfMissing: Bool) throws -> SymmetricKey
}

/// Chave AES-256 aleatória guardada no Keychain do macOS (só neste Mac, só com o Mac desbloqueado).
public struct KeychainKeyProvider: VaultKeyProvider {
    /// Remove a chave do Keychain (usado ao migrar de um cofre antigo).
    public func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public let service: String
    public let account: String

    public init(service: String = "app.rosen.vault", account: String = "master-key") {
        self.service = service
        self.account = account
    }

    public func key(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw VaultError.keychain(status) }
        guard createIfMissing else { throw VaultError.missingKey }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Rosen — chave do cofre",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw VaultError.keychain(addStatus) }
        return key
    }
}

/// Chave fixa — para testes.
public struct StaticKeyProvider: VaultKeyProvider {
    let data: Data
    public init(key: SymmetricKey) { data = key.withUnsafeBytes { Data($0) } }
    public func key(createIfMissing: Bool) throws -> SymmetricKey { SymmetricKey(data: data) }
}

/// Arquivo único com todos os túneis e credenciais, criptografado com AES-256-GCM.
/// Formato: "BRW1" + nonce(12) + ciphertext + tag(16). O cabeçalho é autenticado.
public struct Vault: Sendable {
    public static let magic = Data("BRW1".utf8)

    public let url: URL
    let keyProvider: VaultKeyProvider

    public init(url: URL, keyProvider: VaultKeyProvider) {
        self.url = url
        self.keyProvider = keyProvider
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Rosen", isDirectory: true).appendingPathComponent("vault.rosen")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// `nil` quando ainda não existe cofre.
    public func load() throws -> VaultPayload? {
        guard exists else { return nil }
        let data = try Data(contentsOf: url)
        let key = try keyProvider.key(createIfMissing: false)
        return try Self.open(data, key: key)
    }

    public func save(_ payload: VaultPayload) throws {
        let key = try keyProvider.key(createIfMissing: !exists)
        let sealed = try Self.seal(payload, key: key)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Copia o conteúdo de um cofre antigo para este, se este ainda não existir.
    /// Confere a cópia antes de devolver. Não apaga nada: quem chama decide.
    /// - Returns: o conteúdo migrado, ou `nil` se não havia o que migrar.
    @discardableResult
    public func migrate(from legacy: Vault) throws -> VaultPayload? {
        guard !exists, legacy.exists, let payload = try legacy.load() else { return nil }
        try save(payload)
        guard try load() == payload else { throw VaultError.corrupted }
        return payload
    }

    public static func seal(_ payload: VaultPayload, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(payload)
        let box = try AES.GCM.seal(json, using: key, authenticating: magic)
        guard let combined = box.combined else { throw VaultError.corrupted }
        return magic + combined
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> VaultPayload {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { throw VaultError.unsupportedFormat }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            let json = try AES.GCM.open(box, using: key, authenticating: magic)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VaultPayload.self, from: json)
        } catch {
            throw VaultError.corrupted
        }
    }
}
