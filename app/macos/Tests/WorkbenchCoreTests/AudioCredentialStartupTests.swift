import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct AudioCredentialStartupTests {
    @Test func reopeningAndReadingHistoryNeverReadsCredentials() async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let resultID = UUID()
        #expect(fixture.processing.saveTranscriptResult(recordingID: fixture.id, resultID: resultID,
            createdAt: Date(), configuration: .init(provider: .aiHubMix), document: .init(text: "Retained user edit")))
        let original = try fixture.store.loadTranscription(for: fixture.id)
        let credentials = StartupAudioCredentials(); credentials.failure = .credential
        let service = StartupTranscriber()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: service)
        #expect(credentials.readScopes.isEmpty)
        #expect(app.error == nil)
        #expect(app.credentialAvailability == .unchecked)
        #expect(app.materials[fixture.id] == original)
        #expect(app.selectResult(recordingID: fixture.id, resultID: resultID))
        #expect(app.selectedResult(recordingID: fixture.id)?.text == "Retained user edit")
        let destination = fixture.root.appendingPathComponent("history.txt")
        #expect(app.exportTranscript(recordingID: fixture.id, resultID: resultID, format: .text,
            includeTimestamps: false, language: .english, to: destination))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Retained user edit")
        #expect(credentials.readScopes.isEmpty)
        #expect(await service.calls == 0)
        #expect(try fixture.store.loadTranscription(for: fixture.id) == original)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func savedTargetIsReadOnlyAfterExplicitSubmission() async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "fixture-key")
        let target = fixture.processing.configuration
        let credentials = StartupAudioCredentials()
        credentials.keys[target.credentialScope] = "fixture-key"
        credentials.keys[AudioServiceConfiguration().credentialScope] = "other-target-key"
        let service = StartupTranscriber()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: service)
        #expect(credentials.readScopes.isEmpty)
        #expect(app.credentialAvailability == .unchecked)
        #expect(app.canEnqueueTranscription)
        await app.transcribe(fixture.id)
        #expect(await service.calls == 1)
        #expect(await service.configurations == [target])
        #expect(!credentials.readScopes.isEmpty && credentials.readScopes.allSatisfy { $0 == target.credentialScope })
        #expect(app.hasCredential)
        #expect(app.materials[fixture.id]?.results.first?.configuration == target)
    }

    @Test(arguments: [false, true])
    func missingOrDeniedAccessNeverEnqueuesOrLosesHistory(denied: Bool) async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let resultID = UUID()
        #expect(fixture.processing.saveTranscriptResult(recordingID: fixture.id, resultID: resultID,
            createdAt: Date(), configuration: .init(), document: .init(text: "Old edited result")))
        let original = try fixture.store.loadTranscription(for: fixture.id)
        let credentials = StartupAudioCredentials(); credentials.failure = denied ? .credential : nil
        let service = StartupTranscriber()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: service)
        #expect(credentials.readScopes.isEmpty && app.error == nil)
        #expect(app.enqueueTranscription(fixture.id) == nil)
        #expect(app.backgroundTasks.isEmpty && app.runningID == nil)
        #expect(await service.calls == 0)
        #expect(app.error == (denied ? .credential : .configuration))
        #expect(app.credentialAvailability == (denied ? .inaccessible : .missing))
        #expect(try fixture.store.loadTranscription(for: fixture.id) == original)
        credentials.failure = nil; credentials.keys[app.configuration.credentialScope] = "restored-fixture-key"
        #expect(await service.calls == 0)
        await app.transcribe(fixture.id)
        #expect(await service.calls == 1)
        #expect(app.credentialAvailability == .available)
        #expect(app.materials[fixture.id]?.results.first == original.results.first)
    }

    @Test(arguments: [PostRecordingSession.CredentialAvailability.available, .missing, .inaccessible])
    func restoredQueueReadsItsSnapshotOnlyAfterExplicitResume(access: PostRecordingSession.CredentialAvailability) async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let resultID = UUID()
        #expect(fixture.processing.saveTranscriptResult(recordingID: fixture.id, resultID: resultID,
            createdAt: Date(), configuration: .init(), document: .init(text: "Retained before resuming")))
        let original = try fixture.store.loadTranscription(for: fixture.id)
        let queuedTarget = AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3")
        let task = AudioBackgroundTask(recordingID: fixture.id, configuration: queuedTarget, requestTimestamps: true)
        try fixture.store.saveAudioQueue([task])
        let credentials = StartupAudioCredentials()
        if access == .available { credentials.keys[queuedTarget.credentialScope] = "queued-fixture-key" }
        let service = StartupTranscriber()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: service)
        #expect(app.configuration.provider == .openAI)
        #expect(app.backgroundTasks.first?.status == .awaitingResume)
        #expect(credentials.readScopes.isEmpty && app.error == nil)
        #expect(app.credentialAvailability == .unchecked)
        #expect(await service.calls == 0)
        // Current target B deliberately has the opposite status to queued target A.
        app.saveConfiguration(model: "whisper-1", apiKey: access == .available ? "" : "current-target-key")
        let currentAvailability = app.credentialAvailability
        #expect(currentAvailability == (access == .available ? .missing : .available))
        if access == .inaccessible { credentials.failure = .credential }
        #expect(app.resumeBackgroundTask(task.id))
        let deadline = Date().addingTimeInterval(3)
        while app.runningID != nil, Date() < deadline { await Task.yield() }
        #expect(app.backgroundTasks.first?.status == (access == .available ? .completed : .failed))
        #expect(credentials.readScopes == [app.configuration.credentialScope, queuedTarget.credentialScope])
        #expect(await service.configurations == (access == .available ? [queuedTarget] : []))
        #expect(app.credentialAvailability == currentAvailability)
        #expect(app.materials[fixture.id]?.results.first == original.results.first)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func explicitSaveChecksOnlySelectedTargetAndRetainsExistingKey() async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let credentials = StartupAudioCredentials()
        let target = AudioServiceConfiguration(provider: .aiHubMix)
        credentials.keys[target.credentialScope] = "existing-target-key"
        let service = StartupTranscriber()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: service)
        #expect(credentials.readScopes.isEmpty)
        app.saveConfiguration(provider: target.provider, model: target.model, apiKey: "")
        #expect(credentials.readScopes == [target.credentialScope])
        #expect(credentials.keys[target.credentialScope] == "existing-target-key")
        #expect(app.credentialAvailability == .available)
        #expect(await service.calls == 0)
    }

    @Test func explicitRemovalDoesNotNeedAStartupCredentialRead() async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let credentials = StartupAudioCredentials()
        let target = AudioServiceConfiguration()
        credentials.keys[target.credentialScope] = "existing-target-key"
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: StartupTranscriber())
        #expect(app.credentialAvailability == .unchecked)
        app.removeCredential()
        #expect(app.credentialAvailability == .missing)
        #expect(credentials.keys[target.credentialScope] == nil)
        #expect(credentials.readScopes.isEmpty)
    }

    @Test func unavailableHistoryKeepsStorageErrorWithoutReadingCredentials() async throws {
        let fixture = try await PostRecordingFixture(); defer { fixture.remove() }
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        let corrupt = Data("incomplete local material".utf8)
        try corrupt.write(to: path)
        let credentials = StartupAudioCredentials(); credentials.failure = .credential
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: StartupTranscriber())
        #expect(app.error == .storage)
        #expect(app.credentialAvailability == .unchecked)
        #expect(app.enqueueTranscription(fixture.id) == nil)
        #expect(app.error == .storage)
        #expect(credentials.readScopes.isEmpty)
        #expect(try Data(contentsOf: path) == corrupt)
    }
}

@MainActor private final class StartupAudioCredentials: AudioCredentials {
    var keys: [String: String] = [:]
    var failure: AudioProcessingError?
    private(set) var readScopes: [String] = []
    func read(for configuration: AudioServiceConfiguration) throws -> String? {
        readScopes.append(configuration.credentialScope)
        if let failure { throw failure }
        return keys[configuration.credentialScope]
    }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = value }
    func delete(for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = nil }
}

private actor StartupTranscriber: FileTranscribing {
    private(set) var calls = 0
    private(set) var configurations: [AudioServiceConfiguration] = []
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
        progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        calls += 1; configurations.append(configuration)
        return "New controlled transcript"
    }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
        requestTimestamps: Bool, progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        try await TranscribedAudio(text: transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }
}
