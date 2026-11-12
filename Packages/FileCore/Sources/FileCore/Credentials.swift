import Foundation
import Security

/// Stores one secret (password or token) per connection. Implementations must
/// never let one connection read another connection's secret.
public protocol CredentialStore: Sendable {
    func secret(for connectionID: UUID) throws -> String?
    func setSecret(_ secret: String, for connectionID: UUID) throws
    func removeSecret(for connectionID: UUID) throws
}

public enum CredentialError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Keychain-backed store. Each connection is a separate generic-password item
/// whose account is the connection UUID; secrets are only readable after the
/// device's first unlock and never sync to other devices.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let useDataProtectionKeychain: Bool

    public init(service: String = "com.zacharysturman.filesbackups.connection", accessGroup: String? = nil, useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func query(for connectionID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func secret(for connectionID: UUID) throws -> String? {
        var query = query(for: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, for connectionID: UUID) throws {
        let data = Data(secret.utf8)
        let base = query(for: connectionID)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    public func removeSecret(for connectionID: UUID) throws {
        let status = SecItemDelete(query(for: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var secrets: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for connectionID: UUID) throws -> String? {
        lock.withLock { secrets[connectionID] }
    }

    public func setSecret(_ secret: String, for connectionID: UUID) throws {
        lock.withLock { secrets[connectionID] = secret }
    }

    public func removeSecret(for connectionID: UUID) throws {
        lock.withLock { secrets[connectionID] = nil }
    }
}

/// Saved connection profiles (no secrets) in one JSON file.
public final class ConnectionStore: @unchecked Sendable {
    public let url: URL
    private let credentials: any CredentialStore

    public init(url: URL, credentials: any CredentialStore) {
        self.url = url
        self.credentials = credentials
    }

    public func load() -> [ConnectionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.fileCore.decode([ConnectionProfile].self, from: data)) ?? []
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.fileCore.encode(profiles).write(to: url, options: .atomic)
    }

    /// Adds or replaces a profile. A nil secret keeps the existing one.
    public func upsert(_ profile: ConnectionProfile, secret: String?) throws {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if let secret { try credentials.setSecret(secret, for: profile.id) }
        try save(profiles)
    }

    /// Removes the profile and its secret.
    public func remove(_ id: UUID) throws {
        try credentials.removeSecret(for: id)
        try save(load().filter { $0.id != id })
    }
}
