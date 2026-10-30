import Foundation
import LocalAuthentication
import Security
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct KeychainCredentialMetadataTests {
    @Test func existenceQueryIsOffMainNoninteractiveAndNeverRequestsSecretData() async {
        let target = CredentialMetadataTarget(service: "metadata-query-test", account: "scoped-account", scope: "scoped-target")
        let result = await KeychainCredentialMetadata.presence(for: target) { query in
            #expect(!Thread.isMainThread)
            #expect(query[kSecAttrService as String] as? String == "metadata-query-test")
            #expect(query[kSecAttrAccount as String] as? String == "scoped-account")
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(query[kSecReturnData as String] == nil)
            #expect(query[kSecReturnRef as String] == nil)
            #expect(query[kSecReturnPersistentRef as String] == nil)
            #expect(query[kSecValueData as String] == nil)
            #expect(query[kSecUseAuthenticationContext as String] is LAContext)
            #expect(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            var interaction = DarwinBoolean(true)
            #expect(SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess)
            #expect(!interaction.boolValue)
            return errSecSuccess
        }
        #expect(result == true)
    }

    @Test func missingIsDistinctFromDeniedOrLockedMetadata() async {
        let target = CredentialMetadataTarget(service: "metadata-status-test", account: "dummy", scope: "dummy")
        #expect(await KeychainCredentialMetadata.presence(for: target, lookup: { _ in errSecItemNotFound }) == false)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            #expect(await KeychainCredentialMetadata.presence(for: target, lookup: { _ in status }) == nil)
        }
    }

    @Test func metadataUsesExistingCredentialAccountsAndSeparatesTargets() throws {
        let official = try KeychainAudioCredentials.metadataTarget(for: .init(provider: .openAI))
        let gemini = try KeychainAudioCredentials.metadataTarget(for: .init(provider: .gemini))
        #expect(official.account == "api-key")
        #expect(gemini.account.hasPrefix("api-key-") && gemini.account != official.account)
        let id = UUID()
        let original = try ProviderProfile(id: id, name: "Original", baseURL: "https://one.test", model: "model")
        let changed = try ProviderProfile(id: id, name: "Original", baseURL: "https://two.test", model: "model")
        let first = try KeychainProviderCredentials.metadataTarget(for: original.credentialReference)
        let second = try KeychainProviderCredentials.metadataTarget(for: changed.credentialReference)
        #expect(first.account != second.account && first.scope != second.scope)
    }

    @Test func metadataTargetSurvivesEmptyLegacyModelDraftWithoutRelaxingSecretValidation() throws {
        let configurations: [AudioServiceConfiguration] = [
            .init(provider: .openAI, model: "legacy-transcribe-model"),
            .init(provider: .aiHubMix, model: "custom-transcribe-model"),
            .init(provider: .compatible, baseURL: "https://custom.example/v1", model: "custom-model")
        ]
        let credentials = KeychainAudioCredentials(service: "metadata-model-test-\(UUID())")
        for saved in configurations {
            let draft = AudioServiceConfiguration(provider: saved.provider, baseURL: saved.baseURL, model: "")
            #expect(try KeychainAudioCredentials.metadataTarget(for: draft) ==
                    KeychainAudioCredentials.metadataTarget(for: saved))
            // Invalid drafts must fail before any real Keychain read or mutation.
            #expect(throws: AudioProcessingError.configuration) { try credentials.read(for: draft) }
            #expect(throws: AudioProcessingError.configuration) { try credentials.save("unused", for: draft) }
            #expect(throws: AudioProcessingError.configuration) { try credentials.delete(for: draft) }
        }
        #expect(throws: AudioProcessingError.configuration) {
            try KeychainAudioCredentials.metadataTarget(
                for: .init(provider: .compatible, baseURL: "http://custom.example/v1", model: "")
            )
        }
    }

    @Test func failedOrLateDiscoveryCannotEraseOrReviveCredentialState() async {
        let target = CredentialMetadataTarget(service: "metadata-state-test-\(UUID())", account: "dummy", scope: "dummy")
        SavedCredentialPresence.remember(true, service: target.service, scope: target.scope)
        #expect(!(await SavedCredentialPresence.discover(target, lookup: { _ in nil })))
        #expect(!(await SavedCredentialPresence.discover(target, lookup: { _ in false })))
        #expect(SavedCredentialPresence.contains(service: target.service, scope: target.scope))

        let gate = MetadataGate()
        let discovery = Task { await SavedCredentialPresence.discover(target, lookup: { _ in await gate.read() }) }
        while !(await gate.started) { await Task.yield() }
        SavedCredentialPresence.remember(false, service: target.service, scope: target.scope)
        await gate.finish()
        #expect(!(await discovery.value))
        #expect(!SavedCredentialPresence.contains(service: target.service, scope: target.scope))
    }
}

private actor MetadataGate {
    var started = false
    private var continuation: CheckedContinuation<Bool?, Never>?
    func read() async -> Bool? {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() { continuation?.resume(returning: true); continuation = nil }
}
