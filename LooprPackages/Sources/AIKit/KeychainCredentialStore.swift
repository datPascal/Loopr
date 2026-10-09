#if canImport(Security)
import Foundation
import Security

public struct KeychainCredentialDescriptor: Equatable, Sendable {
    public enum Accessibility: String, Equatable, Sendable {
        case whenUnlockedThisDeviceOnly
    }

    public let service: String
    public let account: String
    public let accessibility: Accessibility
}

public actor KeychainCredentialStore: AICredentialStore {
    public static let account = "openai-compatible-api-key"
    private let service: String

    public init(bundleIdentifier: String) {
        service = Self.serviceIdentifier(bundleIdentifier: bundleIdentifier)
    }

    public static func serviceIdentifier(bundleIdentifier: String) -> String {
        bundleIdentifier + ".ai-provider"
    }

    public static func descriptor(bundleIdentifier: String) -> KeychainCredentialDescriptor {
        KeychainCredentialDescriptor(
            service: serviceIdentifier(bundleIdentifier: bundleIdentifier),
            account: account,
            accessibility: .whenUnlockedThisDeviceOnly
        )
    }

    public func write(_ value: Data) throws {
        try remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: value
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
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
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
#endif
