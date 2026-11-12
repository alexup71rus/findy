import Foundation
import Security

protocol ProviderKeyStore {
    func read(for account: String) throws -> String
    func containsKey(for account: String) throws -> Bool
    func save(_ key: String, for account: String) throws
    func remove(for account: String) throws
    func removeAll(for providerID: UUID) throws
}

struct APIKeyStore: ProviderKeyStore {
    private let service = "com.khodyrev.findy.provider-key"

    func read(for origin: String) throws -> String {
        var query = baseQuery(origin: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return key
    }

    func containsKey(for origin: String) throws -> Bool {
        var query = baseQuery(origin: origin)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return true
    }

    func save(_ key: String, for origin: String) throws {
        if key.isEmpty {
            try remove(for: origin)
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            // Siri must be able to read this item after the device locks.
            // Device-only storage keeps the credential on this iPhone.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let query = baseQuery(origin: origin)
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(values) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(status: added) }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
    }

    func remove(for origin: String) throws {
        let status = SecItemDelete(baseQuery(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    func removeAll(for providerID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        let prefix = providerID.uuidString.lowercased() + "|"
        for item in result as? [[String: Any]] ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            try remove(for: account)
        }
    }

    private func baseQuery(origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin,
            kSecAttrSynchronizable as String: false
        ]
    }
}

private struct KeychainFailure: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return "Не удалось получить доступ к ключу. Разблокируйте iPhone и повторите попытку."
        }
        return "Не удалось открыть связку ключей (код \(status))."
    }
}
