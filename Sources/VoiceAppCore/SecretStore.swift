import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public enum KeychainSecretStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidUTF8
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Keychain item could not be decoded."
        case .interactionNotAllowed:
            return "Keychain access requires unlocking or user interaction."
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Stores provider API keys in the macOS login keychain (`kSecClassGenericPassword`,
/// `kSecAttrSynchronizable: false`), never synchronized via iCloud.
///
/// VoiceApp is locally/ad-hoc signed without provisioning entitlements for the macOS
/// Data Protection keychain, so keys live in the file-based login keychain (which ignores
/// `kSecAttrAccessible` attributes and may transfer with Migration Assistant).
public struct KeychainSecretStore: SecretStore, Sendable {
    public static let defaultService = "com.local.voiceapp.correction"

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authContext

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == -60008 {
            throw KeychainSecretStoreError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.invalidUTF8
        }
        return string
    }

    public func write(_ secret: String, account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainSecretStoreError.invalidUTF8
        }

        let query = baseQuery(account: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "VoiceApp \(account) API Key",
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "VoiceApp \(account) API Key"

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
