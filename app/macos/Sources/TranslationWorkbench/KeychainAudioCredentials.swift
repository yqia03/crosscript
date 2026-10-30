import Foundation
import Security
import LocalAuthentication
import CryptoKit
import WorkbenchCore

@MainActor final class KeychainAudioCredentials: AudioCredentials {
    private let service: String
    private let allowsAuthenticationUI: Bool
    init(service: String = "TranslationWorkbench.OpenAIAudio", allowsAuthenticationUI: Bool = true) {
        self.service = service
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }
    private func account(for configuration: AudioServiceConfiguration) throws -> String {
        // Secret operations retain full configuration validation, including model.
        try Self.metadataTarget(for: configuration.validated(), service: service).account
    }
    nonisolated static func metadataTarget(for configuration: AudioServiceConfiguration,
                                          service: String = "TranslationWorkbench.OpenAIAudio") throws -> CredentialMetadataTarget {
        // Model is not part of a credential target. Settings can temporarily have
        // an empty model while displaying a legacy profile's saved credential.
        let configuration = try AudioServiceConfiguration(
            provider: configuration.provider, baseURL: configuration.baseURL, model: "credential"
        ).validated()
        // Keep the original official item in place; never copy its secret to another target.
        let account = configuration.provider == .openAI ? "api-key" :
            "api-key-" + SHA256.hash(data: Data(configuration.credentialScope.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(service: service, account: account, scope: configuration.credentialScope)
    }
    private nonisolated static func query(service: String, account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(for configuration: AudioServiceConfiguration) throws -> String? {
        let account = try account(for: configuration)
        let service = service
        // Legacy synchronous callers must never wait behind an authorization
        // dialog or present one on the main actor. Formal UI uses async methods.
        return try Self.compatibilityOperation {
            try Self.readItem(service: service, account: account, allowsAuthenticationUI: false)
        }
    }
    /// Keeps AppKit responsive while the same scoped lookup waits for authorization.
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String? {
        try Task.checkCancellation()
        let account = try account(for: configuration)
        let service = service, allowsAuthenticationUI = allowsAuthenticationUI
        let value = try await Self.readOffMain {
            try Self.readItem(service: service, account: account, allowsAuthenticationUI: allowsAuthenticationUI)
        }
        SavedCredentialPresence.remember(value?.isEmpty == false, service: service, scope: configuration.credentialScope)
        return value
    }
    nonisolated static func readOffMain(_ operation: @escaping @Sendable () throws -> String?) async throws -> String? {
        try await KeychainOperation.read(operation)
    }
    private nonisolated static func compatibilityOperation<Value>(_ operation: () throws -> Value) throws -> Value {
        do { return try KeychainOperation.compatibility(operation) }
        catch { throw AudioProcessingError.credential }
    }
    private nonisolated static func readItem(service: String, account: String, allowsAuthenticationUI: Bool) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var previousInteraction = DarwinBoolean(true)
        if !allowsAuthenticationUI {
            // LAContext covers modern items; the legacy macOS keychain also
            // requires its process-level interaction policy. Restore it below.
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw AudioProcessingError.credential }
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        defer { if !allowsAuthenticationUI { _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AudioProcessingError.credential }
        return key
    }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {
        let account = try account(for: configuration), service = service
        try Self.compatibilityOperation { try Self.saveItem(value, service: service, account: account) }
        SavedCredentialPresence.remember(!value.isEmpty, service: service, scope: configuration.credentialScope)
    }
    func saveAsync(_ value: String, for configuration: AudioServiceConfiguration) async throws {
        try Task.checkCancellation()
        let account = try account(for: configuration), service = service
        try await KeychainOperation.mutate { try Self.saveItem(value, service: service, account: account) }
        SavedCredentialPresence.remember(!value.isEmpty, service: service, scope: configuration.credentialScope)
    }
    private nonisolated static func saveItem(_ value: String, service: String, account: String) throws {
            let query = Self.query(service: service, account: account)
            let data = Data(value.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var addition = query
                addition[kSecValueData as String] = data
                addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw AudioProcessingError.credential }
            } else if status != errSecSuccess { throw AudioProcessingError.credential }
    }
    func delete(for configuration: AudioServiceConfiguration) throws {
        let account = try account(for: configuration), service = service
        try Self.compatibilityOperation { try Self.deleteItem(service: service, account: account) }
        SavedCredentialPresence.remember(false, service: service, scope: configuration.credentialScope)
    }
    func deleteAsync(for configuration: AudioServiceConfiguration) async throws {
        try Task.checkCancellation()
        let account = try account(for: configuration), service = service
        try await KeychainOperation.mutate { try Self.deleteItem(service: service, account: account) }
        SavedCredentialPresence.remember(false, service: service, scope: configuration.credentialScope)
    }
    private nonisolated static func deleteItem(service: String, account: String) throws {
        let query = Self.query(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AudioProcessingError.credential }
    }
}
