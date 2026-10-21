import Foundation
import Security

/// Passwords and tokens (Google refresh tokens, the OAuth client, SMB passwords, paired TV keys), stored in the
/// login Keychain as generic passwords under the service "com.pntapps.veltoret". Never write secrets to files or logs.
public protocol SecretStoring: AnyObject, Sendable {
    func get(_ key: String) -> Data?
    func set(_ key: String, _ value: Data) throws
    func delete(_ key: String)
}

public extension SecretStoring {
    func getString(_ key: String) -> String? { get(key).flatMap { String(data: $0, encoding: .utf8) } }
    func setString(_ key: String, _ value: String) throws { try set(key, Data(value.utf8)) }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")" }
}

public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String
    public init(service: String = "com.pntapps.veltoret") { self.service = service }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return status == errSecSuccess ? out as? Data : nil
    }

    public func set(_ key: String, _ value: Data) throws {
        let q = base(key)
        let update: [String: Any] = [kSecValueData as String: value]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    public func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}

/// In-memory secrets (tests).
public final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[key] }
    public func set(_ key: String, _ value: Data) throws { lock.lock(); items[key] = value; lock.unlock() }
    public func delete(_ key: String) { lock.lock(); items[key] = nil; lock.unlock() }
}
