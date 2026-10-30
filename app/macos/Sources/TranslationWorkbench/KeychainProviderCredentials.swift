import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WorkbenchCore

@MainActor final class KeychainProviderCredentials: ProviderCredentials {
    private let service: String
    init(service: String = "TranslationWorkbench.TextPDFProviders") { self.service = service }
    private func account(_ reference: ProviderCredentialReference) throws -> String {
        try Self.metadataTarget(for: reference, service: service).account
    }
    nonisolated static func metadataTarget(for reference: ProviderCredentialReference,
                                          service: String = "TranslationWorkbench.TextPDFProviders") throws -> CredentialMetadataTarget {
        let normalized = try ProviderProfile(id: reference.profileID, name: "Credential", baseURL: reference.target, model: "credential")
        guard normalized.baseURL == reference.target else { throw ProviderConfigurationError.credential }
        let scope = reference.profileID.uuidString + "|" + reference.target
        let account = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(service: service, account: account, scope: scope)
    }
    private nonisolated static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(reference: ProviderCredentialReference) throws -> String? {
        let account = try account(reference), service = service
        do { return try KeychainOperation.compatibility { try Self.readItem(service: service, account: account, interactive: false) } }
        catch { throw ProviderConfigurationError.credential }
    }
    func readAsync(reference: ProviderCredentialReference) async throws -> String? {
        let account = try account(reference), service = service
        let value = try await KeychainOperation.read { try Self.readItem(service: service, account: account, interactive: true) }
        remember(value?.isEmpty == false, reference: reference)
        return value
    }
    private nonisolated static func readItem(service: String, account: String, interactive: Bool) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw ProviderConfigurationError.credential }
        return value
    }
    func save(_ value: String, reference: ProviderCredentialReference) throws {
        let account = try account(reference), service = service
        do { try KeychainOperation.compatibility { try Self.saveItem(value, service: service, account: account) } }
        catch { throw ProviderConfigurationError.credential }
        remember(!value.isEmpty, reference: reference)
    }
    func saveAsync(_ value: String, reference: ProviderCredentialReference) async throws {
        let account = try account(reference), service = service
        try await KeychainOperation.mutate { try Self.saveItem(value, service: service, account: account) }
        remember(!value.isEmpty, reference: reference)
    }
    private nonisolated static func saveItem(_ value: String, service: String, account: String) throws {
        let query = query(service: service, account: account), data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data; addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw ProviderConfigurationError.credential }
        } else if status != errSecSuccess { throw ProviderConfigurationError.credential }
    }
    func delete(reference: ProviderCredentialReference) throws {
        let account = try account(reference), service = service
        do { try KeychainOperation.compatibility { try Self.deleteItem(service: service, account: account) } }
        catch { throw ProviderConfigurationError.credential }
        remember(false, reference: reference)
    }
    func deleteAsync(reference: ProviderCredentialReference) async throws {
        let account = try account(reference), service = service
        try await KeychainOperation.mutate { try Self.deleteItem(service: service, account: account) }
        remember(false, reference: reference)
    }
    private func remember(_ present: Bool, reference: ProviderCredentialReference) {
        SavedCredentialPresence.remember(present, service: service, scope: reference.profileID.uuidString + "|" + reference.target)
    }
    private nonisolated static func deleteItem(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderConfigurationError.credential }
    }
}
