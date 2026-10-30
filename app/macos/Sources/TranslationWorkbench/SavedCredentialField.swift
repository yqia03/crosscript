import CryptoKit
import Foundation
import SwiftUI
import WorkbenchCore

/// Only presence and revision metadata is persisted. Settings never load a
/// saved secret into a text field or request Keychain secret data for display.
enum SavedCredentialPresence {
    private static func key(service: String, scope: String) -> String {
        "savedCredential." + SHA256.hash(data: Data((service + "|" + scope).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func remember(_ present: Bool, service: String, scope: String) {
        UserDefaults.standard.set(present, forKey: key(service: service, scope: scope))
        UserDefaults.standard.set(UUID().uuidString, forKey: key(service: service, scope: scope) + ".revision")
    }
    static func contains(service: String, scope: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(service: service, scope: scope))
    }
    static func audio(_ configuration: AudioServiceConfiguration) -> Bool {
        contains(service: "TranslationWorkbench.OpenAIAudio", scope: configuration.credentialScope)
    }
    static func provider(_ reference: ProviderCredentialReference) -> Bool {
        contains(service: "TranslationWorkbench.TextPDFProviders", scope: reference.profileID.uuidString + "|" + reference.target)
    }
    /// A lookup finishing after a save/delete cannot replace that newer state.
    /// Inconclusive and missing metadata do not erase known credential state.
    @MainActor static func discover(_ target: CredentialMetadataTarget,
        lookup: @Sendable (CredentialMetadataTarget) async -> Bool? = { await KeychainCredentialMetadata.presence(for: $0) }) async -> Bool {
        let revisionKey = key(service: target.service, scope: target.scope) + ".revision"
        let revision = UserDefaults.standard.string(forKey: revisionKey)
        guard await lookup(target) == true, !Task.isCancelled,
              UserDefaults.standard.string(forKey: revisionKey) == revision else { return false }
        remember(true, service: target.service, scope: target.scope)
        return true
    }
}

private typealias CredentialFieldState<Value> = SwiftUI.State<Value>

/// NSSecureTextField, used by SecureField, disables copying. The saved mask is
/// a placeholder, never an editable sentinel that could be saved as a real key.
struct SavedCredentialField: View {
    let title: String
    let hasSavedKey: Bool
    @Binding var key: String
    var metadataTarget: CredentialMetadataTarget? = nil
    var metadataLookup: @Sendable (CredentialMetadataTarget) async -> Bool? = { await KeychainCredentialMetadata.presence(for: $0) }
    @CredentialFieldState private var discoveredTarget: CredentialMetadataTarget?
    private var showMask: Bool {
        if hasSavedKey { return true }
        guard let metadataTarget, discoveredTarget == metadataTarget else { return false }
        return SavedCredentialPresence.contains(service: metadataTarget.service, scope: metadataTarget.scope)
    }
    var body: some View {
        SecureField(showMask ? "****************" : title, text: $key)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(title)
            .task(id: metadataTarget) {
                discoveredTarget = nil
                guard let metadataTarget, !hasSavedKey else { return }
                if await SavedCredentialPresence.discover(metadataTarget, lookup: metadataLookup), !Task.isCancelled {
                    discoveredTarget = metadataTarget
                }
            }
    }
}
