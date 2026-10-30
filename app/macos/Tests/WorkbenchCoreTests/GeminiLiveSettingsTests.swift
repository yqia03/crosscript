import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct GeminiLiveSettingsTests {
    @Test func reopeningDoesNotReadOrReplaceExistingTargets() {
        let credentials = GeminiSettingsCredentials()
        credentials.values[AudioServiceConfiguration(provider: .aiHubMix).credentialScope] = "audio-fixture"
        let settings = GeminiLiveSettings(credentials: credentials)
        #expect(settings.credentialAvailability == .unchecked)
        #expect(credentials.reads.isEmpty && credentials.writes.isEmpty)
        #expect(credentials.values.count == 1)
    }

    @Test func saveBlankReuseAndDeleteStayOnGoogleTarget() async {
        let credentials = GeminiSettingsCredentials()
        let other = AudioServiceConfiguration(provider: .aiHubMix).credentialScope
        credentials.values[other] = "unrelated-fixture"
        let settings = GeminiLiveSettings(credentials: credentials)
        let scope = settings.configuration.credentialScope
        #expect(await settings.saveCredential("  google-fixture  "))
        #expect(credentials.values[scope] == "google-fixture")
        #expect(credentials.reads.isEmpty)
        #expect(await settings.saveCredential(""))
        #expect(credentials.reads == [scope])
        #expect(settings.credentialAvailability == .available)
        #expect(await settings.removeCredential())
        #expect(settings.credentialAvailability == .missing)
        #expect(credentials.values == [other: "unrelated-fixture"])
        #expect(await settings.saveCredential(""))
        #expect(settings.credentialAvailability == .missing)
    }

    @Test func failuresRetainSavedKeyAndAreRetryable() async {
        let credentials = GeminiSettingsCredentials()
        let settings = GeminiLiveSettings(credentials: credentials)
        #expect(await settings.saveCredential("retained-fixture"))
        credentials.shouldFail = true
        #expect(!(await settings.saveCredential("replacement-fixture")))
        #expect(settings.error == .credential)
        #expect(settings.credentialAvailability == .inaccessible)
        #expect(!(await settings.removeCredential()))
        #expect(credentials.values[settings.configuration.credentialScope] == "retained-fixture")
        credentials.shouldFail = false
        #expect(await settings.saveCredential(""))
        #expect(settings.error == nil && settings.credentialAvailability == .available)
    }

    @Test func nativeGoogleConfigurationCannotBecomeAFileTranscriptionTarget() throws {
        let configuration = AudioServiceConfiguration(provider: .gemini)
        #expect(try configuration.validated() == configuration)
        #expect(try JSONDecoder().decode(AudioServiceConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
        #expect(configuration.credentialScope == "gemini|https://generativelanguage.googleapis.com/v1beta")
        #expect(!configuration.supportsSegmentTimestamps)
        #expect(!AudioServiceProvider.selectableProviders.contains(.gemini))
        #expect(throws: AudioProcessingError.configuration) { try configuration.transcriptionURL() }
    }

    @Test(arguments: ["https://evil.example/v1beta", "https://generativelanguage.googleapis.com/v1", "https://generativelanguage.googleapis.com/v1beta?key=fixture", "https://generativelanguage.googleapis.com.evil.example/v1beta", "https://user@generativelanguage.googleapis.com/v1beta"])
    func targetChangesAreRejected(target: String) {
        #expect(throws: AudioProcessingError.configuration) {
            try AudioServiceConfiguration(provider: .gemini, baseURL: target).validated()
        }
    }
}

@MainActor private final class GeminiSettingsCredentials: AudioCredentials {
    var values: [String: String] = [:]
    var reads: [String] = []
    var writes: [String] = []
    var shouldFail = false
    func read(for configuration: AudioServiceConfiguration) throws -> String? {
        reads.append(configuration.credentialScope)
        if shouldFail { throw AudioProcessingError.credential }
        return values[configuration.credentialScope]
    }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {
        if shouldFail { throw AudioProcessingError.credential }
        writes.append(configuration.credentialScope)
        values[configuration.credentialScope] = value
    }
    func delete(for configuration: AudioServiceConfiguration) throws {
        if shouldFail { throw AudioProcessingError.credential }
        values.removeValue(forKey: configuration.credentialScope)
    }
}
