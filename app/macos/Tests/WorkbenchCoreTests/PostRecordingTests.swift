import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct PostRecordingTests {
    @Test func liveTranslationMaterialCannotEnterTranscriptionQueue() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        var recording = try #require(fixture.recordings.selectedRecording)
        recording.workflow = .liveTranslation
        try fixture.store.save(recording)
        fixture.recordings.refresh()
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        #expect(fixture.processing.enqueueTranscription(recording.id) == nil)
        #expect(await fixture.processing.enqueueTranscriptionAsync(recording.id) == nil)
        #expect(fixture.processing.backgroundTasks.isEmpty)
        #expect(fixture.processing.materials[recording.id]?.results.isEmpty == true)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: recording.id)) == fixture.bytes)
    }

    @Test func resultSaveRetryDoesNotResubmitAndKeepsOriginalAudio() async throws {
        let service = SuspendedTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let work = Task { await fixture.processing.transcribe(fixture.id) }
        while fixture.processing.runningID == nil { await Task.yield() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "")
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await service.finish()
        await work.value
        #expect(fixture.processing.pendingSaveID == fixture.id)
        #expect(fixture.processing.error == .storage)
        try FileManager.default.removeItem(at: path)
        fixture.processing.retrySaving()
        #expect(fixture.processing.pendingSaveID == nil)
        #expect(fixture.processing.materials[fixture.id]?.results.map(\.text) == ["late response"])
        #expect(fixture.processing.materials[fixture.id]?.results.first?.model == "whisper-1")
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
        #expect(fixture.processing.runningID == nil)
    }

    @Test func missingAndRemovedCredentialsNeverStartPaidWork() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        await fixture.processing.transcribe(fixture.id)
        #expect(fixture.processing.error == .configuration)
        #expect(fixture.processing.materials[fixture.id]?.attempt == nil)
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        fixture.processing.removeCredential()
        await fixture.processing.transcribe(fixture.id)
        #expect(!fixture.processing.hasCredential)
        #expect(fixture.processing.materials[fixture.id]?.attempt == nil)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func failingRetryRetainsAudioAndConfigurationWithoutLeakingErrors() async throws {
        let service = RecoveringTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "secret-never-persist")
        await fixture.processing.transcribe(fixture.id)
        #expect(fixture.processing.materials[fixture.id]?.attempt?.status == .failed)
        #expect(fixture.processing.materials[fixture.id]?.attempt?.failure == .processing)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
        await service.recover()
        await fixture.processing.transcribe(fixture.id)
        #expect(fixture.processing.materials[fixture.id]?.results.map(\.text) == ["Recovered source language"])
        let saved = try String(contentsOf: fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json"), encoding: .utf8)
        #expect(!saved.contains("secret-never-persist"))
    }

    @Test(arguments: [AudioServiceProvider.openAI, .aiHubMix])
    func interruptedResponseCannotPublishACompletedResult(provider: AudioServiceProvider) async throws {
        let service = SuspendedTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: provider, model: AudioServiceConfiguration(provider: provider).model, apiKey: "secret-never-persist")
        let work = Task { await fixture.processing.transcribe(fixture.id) }
        while fixture.processing.runningID == nil { await Task.yield() }
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: service)
        #expect(reopened.materials[fixture.id]?.attempt?.status == .interrupted)
        #expect(reopened.materials[fixture.id]?.results.isEmpty == true)
        work.cancel()
        await service.finish()
        await work.value
        #expect(fixture.processing.materials[fixture.id]?.results.isEmpty == true)
        #expect(fixture.processing.materials[fixture.id]?.attempt?.status == .interrupted)
    }

    @Test func manualTranscriptionIsSavedWithAudioAndReopensWithoutAnotherCall() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let processing = fixture.processing
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await processing.transcribe(fixture.id)
        let material = try #require(processing.materials[fixture.id])
        #expect(material.attempt?.status == .completed)
        #expect(material.results.map(\.text) == ["Hello. 你好。"])
        #expect(material.results.first?.model == "whisper-1")
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results == material.results)
        #expect(reopened.runningID == nil)
        #expect(fixture.recordings.recordings.count == 1)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }
}

@MainActor final class PostRecordingFixture {
    let root: URL
    let store: RecordingStore
    let recordings: RecordingSession
    let processing: PostRecordingSession
    let credentials = MemoryAudioCredentials()
    let bytes = Data("independent controlled audio".utf8)
    var id: UUID { recordings.selectedID! }
    init(service: any FileTranscribing = ControlledTranscriber()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample.wav")
        try bytes.write(to: source)
        store = RecordingStore(root: root.appendingPathComponent("Recordings"))
        recordings = RecordingSession(store: store, recorder: ImportUnusedRecorder())
        await recordings.importAudio(from: source, using: ControlledAudioImporter())
        processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor final class MemoryAudioCredentials: AudioCredentials {
    var keys: [String: String] = [:]
    var readFailure: AudioProcessingError?
    func read(for configuration: AudioServiceConfiguration) throws -> String? {
        if let readFailure { throw readFailure }
        return keys[configuration.credentialScope]
    }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = value }
    func delete(for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = nil }
}

struct ControlledTranscriber: FileTranscribing {
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        try await TranscribedAudio(text: transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        await progress(1)
        return "Hello. 你好。"
    }
}

actor SuspendedTranscriber: FileTranscribing {
    private var done = false
    private(set) var receivedConfiguration: AudioServiceConfiguration?
    private(set) var receivedKey: String?
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        try await TranscribedAudio(text: transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        receivedConfiguration = configuration
        receivedKey = apiKey
        while !done { await Task.yield() }
        return "late response"
    }
    func finish() { done = true }
}

actor RecoveringTranscriber: FileTranscribing {
    var recovered = false
    func recover() { recovered = true }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        try await TranscribedAudio(text: transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        if !recovered { throw NSError(domain: "secret-never-persist", code: 500, userInfo: [NSLocalizedDescriptionKey: "secret-never-persist"]) }
        return "Recovered source language"
    }
}
