import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct AudioCredentialConsumerTests {
    @Test func queuedFileWorkerWaitsAsynchronouslyAndCancellationRejectsLateKey() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials()
        let service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let task = try #require(processing.enqueueTranscription(f.id))
        try await settle { credentials.isWaiting || processing.runningID == nil }
        #expect(credentials.isWaiting)
        #expect(await service.calls == 0)
        processing.cancelBackgroundTask(task)
        credentials.release()
        try await settle { processing.runningID == nil }
        #expect(await service.calls == 0)
        #expect(processing.backgroundTasks.first?.status == .cancelled)
        #expect(processing.materials[f.id]?.results.isEmpty == true)
    }

    @Test func submittedTargetStaysFixedWhileSettingsChangeAndDuplicateClicksDoNotReadAgain() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let original = processing.configuration
        let submission = Task { await processing.enqueueTranscriptionAsync(f.id) }
        try await settle { credentials.isWaiting }
        #expect(processing.authorizingSubmissionID == f.id && !processing.canEnqueueTranscription)
        #expect(await processing.enqueueTranscriptionAsync(f.id) == nil)
        #expect(credentials.reads == [original])
        processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "fixture-only")
        credentials.release()
        let taskID = try #require(await submission.value)
        try await settle { credentials.reads.count == 2 && credentials.isWaiting }
        #expect(credentials.reads == [original, original])
        #expect(processing.backgroundTasks.first?.configuration == original)
        #expect(processing.configuration.provider == .aiHubMix)
        processing.cancelBackgroundTask(taskID); credentials.release()
        try await settle { processing.runningID == nil }
        #expect(await service.calls == 0)
    }

    @Test func cancelledPreflightAndConfirmedQuitCannotEnqueueAfterLateAuthorization() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let first = Task { await processing.enqueueTranscriptionAsync(f.id) }
        try await settle { credentials.isWaiting }
        processing.cancelPendingSubmission(); credentials.release()
        #expect(await first.value == nil)
        #expect(processing.backgroundTasks.isEmpty && processing.authorizingSubmissionID == nil)
        let second = Task { await processing.enqueueTranscriptionAsync(f.id) }
        try await settle { credentials.isWaiting }
        #expect(processing.prepareForConfirmedQuit())
        processing.continueAfterCancelledQuit()
        credentials.release()
        #expect(await second.value == nil)
        #expect(processing.backgroundTasks.isEmpty)
        #expect(credentials.syncReads == 0)
        #expect(await service.calls == 0)
    }

    @Test func settingsAuthorizationCanCancelAndSerializesConfigurationUpdates() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let original = processing.configuration
        let saving = Task { await processing.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "") }
        try await settle { credentials.isWaiting }
        #expect(processing.isUpdatingCredentials)
        #expect(!(await processing.removeCredentialAsync()))
        processing.cancelCredentialAction(); credentials.release()
        #expect(!(await saving.value))
        #expect(processing.configuration == original && !processing.isUpdatingCredentials)
        let another = Task { await processing.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "") }
        try await settle { credentials.isWaiting }
        processing.saveConfiguration(model: "gpt-4o-transcribe-diarize", apiKey: "fixture-only")
        #expect(processing.configuration == original) // Settings mutations are serialized.
        processing.cancelCredentialAction(); credentials.release()
        #expect(!(await another.value))
        processing.saveConfiguration(model: "gpt-4o-transcribe-diarize", apiKey: "fixture-only")
        #expect(processing.configuration.model == "gpt-4o-transcribe-diarize")
        #expect(credentials.reads.allSatisfy { $0.provider == .aiHubMix })
        #expect(await service.calls == 0)
    }

    @Test func explicitSaveAndDeleteUseAsyncScopeAndSerializeSettingsChanges() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        credentials.holdReads = false
        #expect(await processing.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "fixture-only"))
        let original = processing.configuration
        #expect(credentials.writes == [original] && credentials.syncReads == 0)
        credentials.holdDeletes = true
        let deletion = Task { await processing.removeCredentialAsync() }
        try await settle { credentials.isWaiting }
        processing.saveConfiguration(model: "whisper-1", apiKey: "fixture-only")
        #expect(processing.configuration == original && processing.hasCredential)
        credentials.release()
        #expect(await deletion.value)
        #expect(processing.configuration == original && !processing.hasCredential)
        processing.saveConfiguration(model: "whisper-1", apiKey: "fixture-only")
        #expect(processing.configuration.provider == .openAI && processing.hasCredential)
        #expect(credentials.deletes == [original])
        #expect(await service.calls == 0)
    }

    @Test func removedMaterialCannotBeSubmittedWhenAuthorizationReturns() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let id = f.id
        let submission = Task { await processing.enqueueTranscriptionAsync(id) }
        try await settle { credentials.isWaiting }
        #expect(processing.requestDeletion(.material(recordingID: id)))
        #expect(processing.confirmDeletion())
        credentials.release()
        #expect(await submission.value == nil)
        #expect(processing.backgroundTasks.isEmpty)
        #expect(await service.calls == 0)
    }

    @Test func keySaveWaitsAsynchronouslyAndCancellationDoesNotSelectTheCandidate() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerFileService()
        credentials.holdWrites = true; credentials.holdReads = false
        let processing = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: service)
        let original = processing.configuration
        let save = Task { await processing.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "fixture-only") }
        try await settle { credentials.isWaiting }
        #expect(processing.isUpdatingCredentials && processing.configuration == original)
        processing.cancelCredentialAction(); credentials.release()
        #expect(!(await save.value))
        #expect(processing.configuration == original && !processing.isUpdatingCredentials)
        #expect(credentials.writes == [.init(provider: .aiHubMix, model: "whisper-large-v3"), .init(provider: .aiHubMix, model: "whisper-large-v3")])
        #expect(credentials.syncReads == 0)
        #expect(await service.calls == 0)
    }

    @Test func intervalRepairWaitsForAsyncAuthorizationAndRejectsCancelledLateKey() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = DelayedConsumerCredentials(), service = ConsumerIntervalService()
        let original = TranscriptDocument(text: "USER EDIT", missingIntervals: [.init(startFrame: 0, endFrame: 12_000)])
        let resultID = UUID()
        #expect(f.processing.saveTranscriptResult(recordingID: f.id, resultID: resultID, createdAt: Date(), configuration: .init(), document: original))
        let gate = BackgroundProcessingGate()
        let repair = TranscriptRepairSession(recordings: f.recordings, processing: f.processing, store: TranscriptRepairStore(recordings: f.store),
            credentials: credentials, service: service, gate: gate)
        let task = try #require(repair.submit(recordingID: f.id, sourceResultID: resultID, configuration: .init()))
        try await settle { credentials.isWaiting }
        #expect(repair.authorizingID == task && credentials.syncReads == 0)
        repair.cancel(task); credentials.release()
        try await settle { repair.runningID == nil }
        #expect(repair.tasks.first?.status == .cancelled && gate.activeID == nil)
        #expect(await service.calls == 0)
        #expect(f.processing.materials[f.id]?.results.count == 1)
        #expect(f.processing.materials[f.id]?.results.first?.text == "USER EDIT")
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor private final class DelayedConsumerCredentials: AudioCredentials {
    var syncReads = 0
    var holdDeletes = false
    var holdWrites = false
    var holdReads = true
    var reads: [AudioServiceConfiguration] = []
    var writes: [AudioServiceConfiguration] = []
    var deletes: [AudioServiceConfiguration] = []
    private var pending: CheckedContinuation<String?, Never>?
    var isWaiting: Bool { pending != nil }
    func release() { holdWrites = false; pending?.resume(returning: "fixture-only"); pending = nil }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { syncReads += 1; return "fixture-only" }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String? {
        reads.append(configuration)
        if !holdReads { return "fixture-only" }
        return await withCheckedContinuation { pending = $0 }
    }
    func saveAsync(_ value: String, for configuration: AudioServiceConfiguration) async throws {
        writes.append(configuration)
        if holdWrites { _ = await withCheckedContinuation { pending = $0 } }
    }
    func deleteAsync(for configuration: AudioServiceConfiguration) async throws {
        deletes.append(configuration)
        if holdDeletes { _ = await withCheckedContinuation { pending = $0 } }
    }
}

private actor ConsumerFileService: FileTranscribing {
    var calls = 0
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { calls += 1; return "controlled result" }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool, progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio { calls += 1; return .init(text: "controlled result", anchors: []) }
}
private actor ConsumerIntervalService: IntervalTranscribing {
    var calls = 0
    func transcribe(audio: URL, interval: MissingInterval, configuration: AudioServiceConfiguration, apiKey: String) async throws -> TranscribedAudio {
        calls += 1; return .init(text: "controlled repaired text", anchors: [])
    }
}
