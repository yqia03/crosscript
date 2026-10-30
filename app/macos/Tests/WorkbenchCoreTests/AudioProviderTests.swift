import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct AudioProviderTests {
    @Test func unsupportedModelCannotReplacePresetOrPersistItsCredential() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let app = fixture.processing
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "original-key")
        let original = app.configuration
        app.saveConfiguration(provider: .aiHubMix, model: "gpt-live-transcribe", apiKey: "must-not-save")
        #expect(app.error != nil)
        #expect(app.configuration == original)
        #expect(try fixture.credentials.read(for: original) == "original-key")
    }

    @Test func restoredKeychainAccessAllowsManualRetryWithoutReplacingConfiguration() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-aihub-key")
        fixture.credentials.readFailure = .credential
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.error == nil)
        #expect(reopened.credentialAvailability == .unchecked)
        #expect(reopened.enqueueTranscription(fixture.id) == nil)
        #expect(reopened.error == .credential)
        fixture.credentials.readFailure = nil
        await reopened.transcribe(fixture.id)
        #expect(reopened.materials[fixture.id]?.attempt?.status == .completed)
        #expect(reopened.materials[fixture.id]?.results.first?.configuration.provider == .aiHubMix)
    }

    @Test(arguments: [
        "http://gateway.example/v1", "https://user:key@gateway.example/v1",
        "https://gateway.example/v1?key=secret", "https://gateway.example/v1#fragment",
        "https://gateway.example/v1/v1", "https://gateway.example/../v1",
        "https://gateway.example/%2e%2e/v1", "https://gateway.example//v1",
        "https://gateway.example:99999/v1", "https://gateway.example/v1/audio/translations",
        "https://gateway.example/v1/chat/completions", "https://gateway.example./v1"
    ])
    func unsafeOrAmbiguousAddressCannotReplaceSavedSelection(address: String) async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let app = fixture.processing
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "")
        let original = app.configuration
        app.saveConfiguration(provider: .compatible, baseURL: address, model: "whisper-large-v3", apiKey: "must-not-be-saved")
        #expect(app.error == .configuration)
        #expect(app.configuration == original)
        #expect(app.hasCredential == false)
        await app.transcribe(fixture.id)
        #expect(app.materials[fixture.id]?.attempt == nil)
    }

    @Test func submittedServiceAndModelRemainStableWhileDefaultsChange() async throws {
        let service = SuspendedTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let app = fixture.processing
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "aihub-snapshot-key")
        let work = Task { await app.transcribe(fixture.id) }
        while app.runningID == nil { await Task.yield() }
        app.saveConfiguration(provider: .openAI, model: "whisper-1", apiKey: "other-key")
        app.removeCredential()
        await service.finish()
        await work.value
        let result = try #require(app.materials[fixture.id]?.results.first)
        #expect(result.configuration.provider == .aiHubMix)
        #expect(result.configuration.baseURL == "https://aihubmix.com/v1")
        #expect(result.configuration.model == "whisper-large-v3")
        #expect(await service.receivedConfiguration == result.configuration)
        #expect(await service.receivedKey == "aihub-snapshot-key")
        #expect(app.configuration.provider == .openAI)
        #expect(app.hasCredential == false)
    }

    @Test func legacyOfficialModelAndHistoryKeepTheirIdentityAfterUpgrade() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let directory = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent()
        try Data("\"legacy-official-model\"".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent("audio-configuration.json"))
        let oldMaterial = """
        {"results":[{"id":"D8AED8C7-FD16-4E55-9A01-B11D0F4FCC4A","createdAt":0,"model":"old-official-model","text":"Earlier source-language text"}],"attempt":{"id":"19514E29-B600-43E8-B502-2375A2BC6B34","model":"legacy-official-model","status":"failed","completedChunks":0,"failure":"rateLimited"}}
        """
        try Data(oldMaterial.utf8).write(to: directory.appendingPathComponent("transcription.json"))
        try fixture.credentials.save("legacy-official-key", for: AudioServiceConfiguration())
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                       credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(app.configuration.provider == .openAI)
        #expect(app.model == "legacy-official-model")
        #expect(app.credentialAvailability == .unchecked)
        #expect(app.materials[fixture.id]?.attempt?.configuration.provider == .openAI)
        #expect(app.materials[fixture.id]?.attempt?.failure == .rateLimited)
        await app.transcribe(fixture.id)
        #expect(app.error == .unsupportedConfiguration)
        #expect(app.materials[fixture.id]?.attempt?.id == UUID(uuidString: "19514E29-B600-43E8-B502-2375A2BC6B34"))
        #expect(app.materials[fixture.id]?.results.count == 1)
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "aihub-key")
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.configuration.provider == .aiHubMix)
        let old = try #require(reopened.materials[fixture.id]?.results.first)
        #expect(old.text == "Earlier source-language text")
        #expect(old.configuration.provider == .openAI)
        #expect(old.configuration.model == "old-official-model")
        #expect(reopened.configuration(for: .openAI).model == "legacy-official-model")
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func switchingPresetsKeepsKeysBoundToTheirService() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let app = fixture.processing
        app.saveConfiguration(model: "whisper-1", apiKey: "official-only")
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "")
        #expect(app.hasCredential == false)
        await app.transcribe(fixture.id)
        #expect(app.materials[fixture.id]?.attempt == nil)
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "aihub-only")
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-1", apiKey: "")
        #expect(app.hasCredential)
        #expect(try fixture.credentials.read(for: app.configuration) == "aihub-only")
        let original = app.configuration
        app.saveConfiguration(provider: .compatible, baseURL: "https://aihubmix.com/v1", model: "whisper-large-v3", apiKey: "must-not-save")
        #expect(app.error == .unsupportedConfiguration)
        #expect(app.configuration == original)
        #expect(try fixture.credentials.read(for: original) == "aihub-only")
        app.removeCredential()
        app.saveConfiguration(model: "whisper-1", apiKey: "")
        #expect(app.hasCredential)
        #expect(try fixture.credentials.read(for: app.configuration) == "official-only")
        #expect(app.configuration.provider == .openAI)
        #expect(app.materials[fixture.id]?.results.isEmpty != false)
    }

    @Test func selectedAiHubMixConfigurationAndResultSurviveRestart() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, baseURL: " https://AIHUBMIX.com/ ",
                                             model: "whisper-large-v3", apiKey: "aihub-controlled-key")
        #expect(fixture.processing.error == nil)
        #expect(fixture.processing.configuration.baseURL == "https://aihubmix.com/v1")
        #expect(fixture.processing.configuration.provider == .aiHubMix)
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.materials[fixture.id]?.results.first)
        #expect(result.configuration.provider == .aiHubMix)
        #expect(result.configuration.model == "whisper-large-v3")
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.configuration == result.configuration)
        #expect(reopened.materials[fixture.id]?.results.first == result)
        #expect(reopened.runningID == nil)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }
}
