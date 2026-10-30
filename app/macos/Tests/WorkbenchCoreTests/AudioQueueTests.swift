import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct AudioQueueTests {
    @Test func twoSubmittedRecordingsRunInOrderAndKeepTheirOwnResults() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let a = Task { await fixture.processing.transcribe(first) }
        await service.waitForRequests(1)
        let b = Task { await fixture.processing.transcribe(second) }
        for _ in 0..<100 { await Task.yield() }
        #expect(await service.requestCount == 1)
        await service.finishNext("First transcript")
        await a.value
        for _ in 0..<100 { await Task.yield() }
        await service.finishNext("Second transcript")
        await b.value
        #expect(fixture.processing.materials[first]?.results.map(\.text) == ["First transcript"])
        #expect(fixture.processing.materials[second]?.results.map(\.text) == ["Second transcript"])
        #expect(await service.maximumConcurrent == 1)
    }
    @Test func restartRetainsQueueButOnlyAnExplicitResumeStartsWork() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let running = try #require(fixture.processing.enqueueTranscription(first))
        await service.waitForRequests(1)
        let queued = try #require(fixture.processing.enqueueTranscription(second))
        let reopenedService = QueueControlledTranscriber()
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: reopenedService)
        #expect(reopened.backgroundTasks.map(\.id) == [running, queued])
        #expect(reopened.backgroundTasks.map(\.status) == [.interrupted, .awaitingResume])
        #expect(await reopenedService.requestCount == 0)
        await service.finishNext("Original instance finishing")
        await service.waitForRequests(2)
        await service.finishNext("Original queued instance finishing")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(await reopenedService.requestCount == 0)
    }

    @Test(arguments: [false, true])
    func cancellingQueuedOrRunningWorkRejectsLateResultsAndPreservesNextTask(running: Bool) async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let a = try #require(fixture.processing.enqueueTranscription(first))
        await service.waitForRequests(1)
        let b = try #require(fixture.processing.enqueueTranscription(second))
        fixture.processing.cancelBackgroundTask(running ? a : b)
        #expect(fixture.processing.backgroundTasks.first { $0.id == (running ? a : b) }?.status == .cancelled)
        await service.finishAll("Retained transcript")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.materials[running ? first : second]?.results.isEmpty != false)
        #expect(fixture.processing.materials[running ? second : first]?.results.map(\.text) == ["Retained transcript"])
        #expect(await service.maximumConcurrent == 1)
    }

    @Test func quitPreflightKeepsWorkAliveAndConfirmedQuitRequiresExplicitResumeUsingOriginalSnapshot() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let a = try #require(fixture.processing.enqueueTranscription(first))
        await service.waitForRequests(1)
        let b = try #require(fixture.processing.enqueueTranscription(second))
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3-turbo", apiKey: "different-key")
        #expect(fixture.processing.prepareToQuit())
        #expect(fixture.processing.backgroundTasks.map(\.status) == [.running, .queued])
        #expect(fixture.processing.prepareForConfirmedQuit())
        await service.finishAll("Must not publish after confirmed quit")
        while fixture.processing.runningID != nil { await Task.yield() }
        let nextService = QueueControlledTranscriber()
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: nextService)
        #expect(reopened.backgroundTasks.map(\.status) == [.interrupted, .awaitingResume])
        #expect(reopened.materials[first]?.results.isEmpty != false)
        #expect(await nextService.requestCount == 0)
        let resumed = reopened.resumeBackgroundTask(b)
        #expect(resumed)
        if resumed {
            await nextService.waitForRequests(1)
            #expect(await nextService.configurations.map(\.model) == ["whisper-1"])
            await nextService.finishAll("Recovered request")
            while reopened.runningID != nil { await Task.yield() }
            #expect(reopened.materials[second]?.results.map(\.text) == ["Recovered request"])
            #expect(reopened.backgroundTasks.first { $0.id == a }?.status == .interrupted)
        }
    }

    @Test func queueSaveFailurePreventsRequestsAndLocalRetryDoesNotInventASubmission() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let queueFile = fixture.root.appendingPathComponent("Recordings/audio-task-queue.json")
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        #expect(fixture.processing.enqueueTranscription(fixture.id) == nil)
        #expect(fixture.processing.queueNeedsSave)
        #expect(await service.requestCount == 0)
        #expect(fixture.processing.backgroundTasks.isEmpty)
        try FileManager.default.removeItem(at: queueFile)
        fixture.processing.retrySaving()
        #expect(!fixture.processing.queueNeedsSave)
        #expect(await service.requestCount == 0)
        #expect(fixture.processing.backgroundTasks.isEmpty)
    }

    @Test func receivedResultStaysEditableDuringSaveFailureAndLocalSaveDoesNotResubmit() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let jobID = try #require(fixture.processing.enqueueTranscription(fixture.id))
        await service.waitForRequests(1)
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await service.finishAll("Received result")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.backgroundTasks.first?.status == .awaitingLocalSave)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: "Edited while unsaved"))
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: result.id) == "Edited while unsaved")
        #expect(!fixture.processing.prepareToQuit())
        try FileManager.default.removeItem(at: path)
        fixture.processing.retrySaving()
        #expect(fixture.processing.backgroundTasks.first { $0.id == jobID }?.status == .completed)
        #expect(fixture.processing.prepareToQuit())
        #expect(await service.requestCount == 1)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Edited while unsaved"])
        #expect(reopened.materials[fixture.id]?.results.first?.id == result.id)
    }

    @Test func restartReconcilesDurableResultWhenCompletionJournalWriteWasInterrupted() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let job = try #require(fixture.processing.enqueueTranscription(fixture.id))
        await service.waitForRequests(1)
        let queueFile = fixture.root.appendingPathComponent("Recordings/audio-task-queue.json")
        let runningJournal = try Data(contentsOf: queueFile)
        await service.finishAll("Durable before process exit")
        while fixture.processing.runningID != nil { await Task.yield() }
        let original = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        // Reproduce a process dying between the two atomic file replacements.
        try runningJournal.write(to: queueFile, options: .atomic)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(reopened.backgroundTasks.first?.status == .completed)
        #expect(reopened.materials[fixture.id]?.results.map(\.id) == [original.id])
        #expect(!reopened.resumeBackgroundTask(job))
        await service.finishAll("Unexpected duplicate")
        while reopened.runningID != nil { await Task.yield() }
        #expect(await service.requestCount == 1)
    }

    @Test(arguments: [false, true])
    func cancellationBeforeWorkerStartsNeverSendsAudio(confirmQuit: Bool) async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let task = try #require(fixture.processing.enqueueTranscription(fixture.id))
        if confirmQuit { #expect(fixture.processing.prepareForConfirmedQuit()) }
        else { fixture.processing.cancelBackgroundTask(task) }
        await service.finishAll("Must never be requested")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(await service.requestCount == 0)
        #expect(fixture.processing.materials[fixture.id]?.results.isEmpty != false)
    }

    @Test func queuedWorkBlocksDeletionIncludingAnAlreadyOpenConfirmation() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await service.finishAll("Keep this edited version")
        await fixture.processing.transcribe(second)
        let saved = try #require(fixture.processing.selectedResult(recordingID: second))
        await service.holdFutureRequests()
        _ = fixture.processing.enqueueTranscription(first)
        await service.waitForRequests(2)
        #expect(fixture.processing.requestDeletion(.result(recordingID: second, resultID: saved.id)))
        let queued = try #require(fixture.processing.enqueueTranscription(second))
        #expect(fixture.processing.deletionBlockReason(for: .material(recordingID: second)) == .busy)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.materials[second]?.results.map(\.id) == [saved.id])
        fixture.processing.cancelBackgroundTask(queued)
        await service.finishAll("Other material")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.deletionBlockReason(for: .material(recordingID: second)) == nil)
        #expect(await service.requestCount == 2)
    }

    @Test func removedCredentialFailsWaitingTaskWithoutUploadingAndOnlyManualRetryUsesRestoredScope() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        _ = fixture.processing.enqueueTranscription(first)
        await service.waitForRequests(1)
        let secondJob = try #require(fixture.processing.enqueueTranscription(second))
        let originalAttempt = try #require(fixture.processing.backgroundTasks.last?.attemptID)
        fixture.processing.removeCredential()
        await service.finishAll("First request already had its credential")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(await service.requestCount == 1)
        #expect(fixture.processing.backgroundTasks.last?.status == .failed)
        #expect(fixture.processing.backgroundTasks.last?.failure == .credential)
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "restored-controlled-key")
        #expect(await service.requestCount == 1)
        #expect(fixture.processing.retryBackgroundTask(secondJob))
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(await service.requestCount == 2)
        #expect(fixture.processing.backgroundTasks.last?.attemptID != originalAttempt)
        #expect(fixture.processing.materials[second]?.results.count == 1)
        let journal = try String(contentsOf: fixture.root.appendingPathComponent("Recordings/audio-task-queue.json"), encoding: .utf8)
        #expect(!journal.contains("controlled-key"))
    }

    @Test func audioQueueAllowsRecordingAndCancellingQuitOrFailedRecordingSaveNeverInterruptsRequests() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        let recordings = RecordingSession(store: fixture.store, recorder: QueueRecordingStub())
        let processing = PostRecordingSession(recordings: recordings, store: fixture.store, credentials: fixture.credentials, service: service)
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        _ = processing.enqueueTranscription(first)
        await service.waitForRequests(1)
        _ = processing.enqueueTranscription(second)
        await recordings.start()
        #expect(recordings.isRecording)
        #expect(processing.backgroundTasks.map(\.status) == [.running, .queued])
        #expect(processing.prepareToQuit())
        #expect(!recordings.requestQuit())
        recordings.cancelQuit()
        #expect(recordings.isRecording)
        #expect(processing.backgroundTasks.map(\.status) == [.running, .queued])
        #expect(await service.requestCount == 1)
        let active = try #require(recordings.activeID)
        let metadata = recordings.audioURL(for: active).deletingLastPathComponent().appendingPathComponent("recording.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        #expect(!recordings.requestQuit())
        #expect(await recordings.confirmQuit() == false)
        #expect(recordings.needsSaveRetry)
        #expect(processing.backgroundTasks.map(\.status) == [.running, .queued])
        #expect(await service.requestCount == 1)
        try FileManager.default.removeItem(at: metadata)
        recordings.stop()
        #expect(!recordings.needsSaveRetry)
        #expect(processing.prepareForConfirmedQuit())
        await service.finishAll("Late after actual quit")
        while processing.runningID != nil { await Task.yield() }
        #expect(processing.backgroundTasks.map(\.status) == [.interrupted, .awaitingResume])
        #expect(processing.materials[first]?.results.isEmpty != false)
    }

    @Test func unreadableQueueIsPreservedWithoutUploadsAndDoesNotTrapSafeExit() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let path = fixture.root.appendingPathComponent("Recordings/audio-task-queue.json")
        let unreadable = Data("retained unreadable queue".utf8)
        try unreadable.write(to: path)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(!reopened.isAudioQueueReadable)
        #expect(reopened.enqueueTranscription(fixture.id) == nil)
        reopened.retrySaving()
        #expect(reopened.prepareToQuit())
        #expect(reopened.prepareForConfirmedQuit())
        #expect(try Data(contentsOf: path) == unreadable)
        #expect(await service.requestCount == 0)
    }

    @Test func restartPreservesExistingEditsWhenInterruptedAttemptCannotBeSaved() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await service.finishAll("Existing transcript")
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: "Keep this edit"))
        var material = try fixture.store.loadTranscription(for: fixture.id)
        material.attempt?.status = .running
        try fixture.store.saveTranscription(material, for: fixture.id)
        let directory = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(reopened.materials[fixture.id]?.results.first?.text == "Keep this edit")
        #expect(reopened.hasUnsavedTranscript(recordingID: fixture.id))
        #expect(!reopened.prepareToQuit())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        reopened.retrySaving()
        #expect(!reopened.hasUnsavedTranscript(recordingID: fixture.id))
        #expect(try fixture.store.loadTranscription(for: fixture.id).results.first?.text == "Keep this edit")
        #expect(await service.requestCount == 1)
    }

    @Test func cancellingQuitAfterRepairingLocalSaveContinuesPreviouslySubmittedQueue() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        _ = fixture.processing.enqueueTranscription(first)
        await service.waitForRequests(1)
        let secondJob = try #require(fixture.processing.enqueueTranscription(second))
        let path = fixture.recordings.audioURL(for: first).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await service.finishNext("Received before save failure")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.backgroundTasks.map(\.status) == [.awaitingLocalSave, .queued])
        try FileManager.default.removeItem(at: path)
        #expect(fixture.processing.prepareToQuit())
        #expect(await service.requestCount == 1)
        fixture.processing.continueAfterCancelledQuit()
        let deadline = Date().addingTimeInterval(2)
        while await service.requestCount < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await service.requestCount == 2)
        await service.finishAll("Second request after cancelled quit")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.backgroundTasks.first { $0.id == secondJob }?.status == .completed)
    }


    @Test func anotherMaterialVetoingConfirmedQuitRestoresManualQueueCommands() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let first = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let second = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        _ = try #require(fixture.processing.enqueueTranscription(first))
        await service.waitForRequests(1)
        let queued = try #require(fixture.processing.enqueueTranscription(second))
        #expect(fixture.processing.prepareForConfirmedQuit())
        #expect(!fixture.processing.canEnqueueTranscription)
        await service.finishAll("Late completion after confirmed shutdown")
        let stopped = Date().addingTimeInterval(2)
        while fixture.processing.runningID != nil, Date() < stopped { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fixture.processing.runningID == nil)
        // A later repair/PDF save failure vetoed termination. Restoring command
        // availability must not itself retry an interrupted cloud request.
        fixture.processing.continueAfterCancelledQuit()
        #expect(fixture.processing.canEnqueueTranscription)
        #expect(fixture.processing.backgroundTasks.map(\.status) == [.interrupted, .awaitingResume])
        #expect(await service.requestCount == 1)
        #expect(fixture.processing.resumeBackgroundTask(queued))
        let resumed = Date().addingTimeInterval(2)
        while fixture.processing.backgroundTasks.first(where: { $0.id == queued })?.status != .completed, Date() < resumed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.requestCount == 2)
        #expect(fixture.processing.backgroundTasks.first(where: { $0.id == queued })?.status == .completed)
        #expect(fixture.processing.materials[first]?.results.isEmpty != false)
        #expect(fixture.processing.materials[second]?.results.count == 1)
    }

}

actor QueueControlledTranscriber: FileTranscribing {
    private var finishAutomatically: String?
    private var continuations: [CheckedContinuation<String, Never>] = []
    private(set) var requestCount = 0
    private(set) var maximumConcurrent = 0
    private(set) var configurations: [AudioServiceConfiguration] = []
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        requestCount += 1
        configurations.append(configuration)
        if let finishAutomatically { return finishAutomatically }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            maximumConcurrent = max(maximumConcurrent, continuations.count)
        }
    }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        let text = try await transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress)
        await progress(1)
        return TranscribedAudio(text: text)
    }
    func waitForRequests(_ count: Int) async {
        while requestCount < count { await Task.yield() }
    }
    func holdFutureRequests() { finishAutomatically = nil }
    func finishAll(_ text: String) {
        finishAutomatically = text
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: text) }
    }
    func finishNext(_ text: String) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: text)
    }
}

@MainActor private final class QueueRecordingStub: AudioRecording {
    var currentTime: TimeInterval { 12 }
    var power: Float { -120 }
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { try Data("controlled recording".utf8).write(to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 12 }
}
