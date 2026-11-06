#if canImport(Security)
import Foundation
import Security

public struct KeychainCredentialDescriptor: Equatable, Sendable {
    public enum Accessibility: String, Equatable, Sendable {
        case whenUnlockedThisDeviceOnly
        case afterFirstUnlockThisDeviceOnly
    }

    public let service: String
    public let account: String
    public let accessibility: Accessibility
}

public actor KeychainCredentialStore: AICredentialStore {
    public static let account = "openai-compatible-api-key"
    private let service: String
    private let credentialAccount: String
    private let accessibility: KeychainCredentialDescriptor.Accessibility

    public init(bundleIdentifier: String, account: String = KeychainCredentialStore.account,
                accessibility: KeychainCredentialDescriptor.Accessibility = .whenUnlockedThisDeviceOnly) {
        service = Self.serviceIdentifier(bundleIdentifier: bundleIdentifier)
        credentialAccount = account
        self.accessibility = accessibility
    }

    public static func serviceIdentifier(bundleIdentifier: String) -> String {
        bundleIdentifier + ".ai-provider"
    }

    public static func descriptor(bundleIdentifier: String, account: String = KeychainCredentialStore.account,
                                  accessibility: KeychainCredentialDescriptor.Accessibility = .whenUnlockedThisDeviceOnly) -> KeychainCredentialDescriptor {
        KeychainCredentialDescriptor(
            service: serviceIdentifier(bundleIdentifier: bundleIdentifier),
            account: account,
            accessibility: accessibility
        )
    }

    public func write(_ value: Data) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount
        ]
        let protection = accessibility == .afterFirstUnlockThisDeviceOnly
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let updated = SecItemUpdate(match as CFDictionary,
            [kSecValueData as String: value, kSecAttrAccessible as String: protection] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount,
            kSecAttrAccessible as String: protection,
            kSecValueData as String: value
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }

    public func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
#endif
