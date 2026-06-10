import Foundation
import LocalAuthentication
import Security

public protocol SecretStoring {
    func read(provider: Provider) throws -> String?
    func save(_ value: String, provider: Provider) throws
    func delete(provider: Provider) throws
}

public final class KeychainStore: SecretStoring {
    private let service: String

    public init(service: String = "com.codex.AIMonitor.apiKeys") {
        self.service = service
    }

    public func read(provider: Provider) throws -> String? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AIMonitorError.keychainFailed(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String, provider: Provider) throws {
        let data = Data(value.utf8)
        var query = baseQuery(provider: provider)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(provider: provider) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw AIMonitorError.keychainFailed(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else { throw AIMonitorError.keychainFailed(status) }
    }

    public func delete(provider: Provider) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIMonitorError.keychainFailed(status)
        }
    }

    private func baseQuery(provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}
