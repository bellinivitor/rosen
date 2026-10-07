import Foundation

public enum SSHKeyInspector {
    public enum Status: Equatable, Sendable { case ok, missing, unreadable, publicKey, notAKey }

    public static func looksLikePrivateKey(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("-----BEGIN") && t.contains("PRIVATE KEY-----")
            || t.hasPrefix("PuTTY-User-Key-File")
    }

    public static func keyType(of text: String) -> String {
        if text.contains("RSA PRIVATE KEY") { return "RSA" }
        if text.contains("EC PRIVATE KEY") { return "ECDSA" }
        if text.contains("DSA PRIVATE KEY") { return "DSA" }
        if text.contains("OPENSSH PRIVATE KEY") { return "OpenSSH" }
        return "Chave privada"
    }

    public static func inspect(path: String) -> Status {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return .missing }
        guard fm.isReadableFile(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 128), as: UTF8.self)
        if looksLikePrivateKey(head) { return .ok }
        if head.hasPrefix("ssh-") || head.hasPrefix("ecdsa-") || head.hasPrefix("sk-") { return .publicKey }
        return .notAKey
    }

    /// Chaves privadas encontradas em ~/.ssh, para escolha rápida.
    public static func discoverKeys(in directory: URL? = nil) -> [URL] {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let skip: Set<String> = ["config", "known_hosts", "known_hosts.old", "authorized_keys", "environment"]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return [] }
        return items
            .filter { url in
                let name = url.lastPathComponent
                guard !name.hasPrefix("."), !name.hasSuffix(".pub"), !skip.contains(name) else { return false }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 32_768 else { return false }
                return inspect(path: url.path) == .ok
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
