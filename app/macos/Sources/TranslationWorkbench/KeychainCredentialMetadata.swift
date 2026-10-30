import Foundation
import LocalAuthentication
import Security

struct CredentialMetadataTarget: Hashable, Sendable {
    let service: String
    let account: String
    let scope: String
}

enum KeychainCredentialMetadata {
    /// The injectable query seam lets tests inspect the exact request without
    /// accessing any user's Keychain items. Only status is ever returned.
    static func presence(for target: CredentialMetadataTarget,
                         lookup: @escaping @Sendable ([String: Any]) -> OSStatus = {
                             SecItemCopyMatching($0 as CFDictionary, nil)
                         }) async -> Bool? {
        do {
            return try await KeychainOperation.metadata {
                let context = LAContext()
                context.interactionNotAllowed = true
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: target.service,
                    kSecAttrAccount as String: target.account,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnAttributes as String: true,
                    kSecUseAuthenticationContext as String: context,
                    // Some sandboxed hosts cannot retain LAContext's setting.
                    // Keep the explicit fail policy as well as the worker's
                    // process-wide interaction guard; never fall back to UI.
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
                ]
                switch lookup(query) {
                case errSecSuccess: return true
                case errSecItemNotFound: return false
                default: return nil // Locked, denied and unavailable are inconclusive.
                }
            }
        } catch { return nil }
    }
}
