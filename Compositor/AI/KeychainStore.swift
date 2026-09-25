import Foundation
import Security

/// Reads and writes API keys. Keys never touch UserDefaults and never appear in logs.
nonisolated protocol KeychainStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String?, account: String) throws
}

/// The real Keychain, scoped to this app's AI settings.
nonisolated struct SystemKeychainStore: KeychainStore {
    static let service = "com.wonderassembly.compositor.ai"

    func read(account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw AIError.network("Keychain error \(status)") }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let added = SecItemAdd(add as CFDictionary, nil)
                guard added == errSecSuccess else { throw AIError.network("Keychain error \(added)") }
            } else if status != errSecSuccess {
                throw AIError.network("Keychain error \(status)")
            }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIError.network("Keychain error \(status)")
            }
        }
    }
}

/// In-memory stand-in for tests.
nonisolated final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func write(_ value: String?, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { values[account] = value } else { values[account] = nil }
    }
}
