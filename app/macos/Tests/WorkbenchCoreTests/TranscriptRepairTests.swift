import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct TranscriptRepairTests {
    @Test func deletionConfirmationRechecksRepairOwnershipAndPreservesSource() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let session = f.session()
        f.processing.relatedOperationBlocksDeletion = { [weak session] in session?.occupiesMaterial($0) == true }
        #expect(f.processing.requestDeletion(.material(recordingID: f.id)))
        let blocker = UUID(); f.gate.enqueue(id: blocker) {}
        let task = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        #expect(!f.processing.confirmDeletion())
        #expect(f.processing.deletionError == .busy)
        #expect(!f.processing.requestDeletion(.result(recordingID: f.id, resultID: f.original.id)))
        #expect(try f.store.loadTranscription(for: f.id).results == [f.original])
        session.cancel(task); f.gate.finish(id: blocker)
        #expect(f.processing.deletionBlockReason(for: .material(recordingID: f.id)) == nil)
        #expect(await f.service.ranges.isEmpty)
    }
    @Test func repairOnlyRequestedIntervalsPublishesNewVersionAndPreservesEditedSource() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let session = f.session()
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        try await settle { session.tasks.first?.status == .completed }
        #expect(await f.service.ranges == f.original.currentDocument.missingIntervals)
        #expect(await f.service.configurations == [f.configuration, f.configuration])
        let reopened = try f.store.loadTranscription(for: f.id)
        #expect(reopened.results.count == 2)
        #expect(reopened.results[0] == f.original)
        let result = reopened.results[1]
        #expect(result.id != f.original.id)
        #expect(result.text == "Edited first.\n\nRepair 1\n\nEdited last.\n\nRepair 2\n\n")
        #expect(result.currentDocument.missingIntervals.isEmpty)
        #expect(result.paragraphs.first(where: { $0.text == "Repair 1" })?.playbackStart == 1.1)
        #expect(result.paragraphs.first(where: { $0.text == "Edited last." })?.playbackStart == 3)
        #expect(session.tasks.first(where: { $0.id == id })?.completedCount == 2)
        #expect(!session.occupiesMaterial(f.id))
    }
    @Test func partialFailurePublishesExactRemainingRangeAndRetryPreservesPriorUserEdits() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        await f.service.setFailStart(4 * 24_000)
        let session = f.session()
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        try await settle { session.tasks.first?.status == .failed && session.runningID == nil }
        let partial = try #require(f.processing.materials[f.id]?.results.last)
        #expect(partial.currentDocument.missingIntervals == [f.original.currentDocument.missingIntervals[1]])
        f.processing.saveTranscriptText(recordingID: f.id, resultID: partial.id, text: "USER EDITED PARTIAL")
        await f.service.setFailStart(nil)
        session.resume(id)
        try await settle { session.tasks.first?.status == .completed }
        let saved = try f.store.loadTranscription(for: f.id)
        #expect(saved.results.count == 3)
        #expect(saved.results.first(where: { $0.id == partial.id })?.text == "USER EDITED PARTIAL")
        #expect(saved.results[0] == f.original)
        #expect(await f.service.ranges.map(\.startFrame) == [24_000, 96_000, 96_000])
    }
    @Test func sharedGateQueuesAndCancellationRejectsLateResponseUntilWorkerActuallyStops() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let blocker = UUID(); f.gate.enqueue(id: blocker) {}
        let session = f.session()
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        #expect(session.tasks.first?.status == .queued)
        #expect(await f.service.ranges.isEmpty)
        session.cancel(id); f.gate.finish(id: blocker)
        #expect(await f.service.ranges.isEmpty)
        await f.service.setHold(true)
        session.resume(id)
        try await settle { await f.service.isHolding }
        session.cancel(id)
        var nextStarted = false; let next = UUID()
        f.gate.enqueue(id: next) { nextStarted = true }
        #expect(!nextStarted); #expect(session.occupiesMaterial(f.id))
        await f.service.release()
        try await settle { nextStarted }
        #expect(f.processing.materials[f.id]?.results.count == 1)
        #expect(session.tasks.first?.completedCount == 0)
        f.gate.finish(id: next)
    }
    @Test func restartRequiresManualResumeAndDoesNotRepeatCompletedIntervals() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        var task = TranscriptRepairTask(recordingID: f.id, source: f.original, configuration: f.configuration)
        task.status = .running
        task.intervals[0].document = TranscriptDocument(text: "Prior successful repair")
        try f.repairStore.save([task], recordingID: f.id)
        let session = f.session()
        #expect(session.tasks.first?.status == .awaitingResume)
        await Task.yield(); #expect(await f.service.ranges.isEmpty)
        session.resume(task.id)
        try await settle { session.tasks.first?.status == .completed }
        #expect(await f.service.ranges.map(\.startFrame) == [96_000])
        #expect(f.processing.materials[f.id]?.results.last?.text.contains("Prior successful repair") == true)
    }
    @Test func allIntervalsCheckpointedBeforeCrashCanPublishLocallyWithoutCloud() throws {
        let f = try RepairFixture(); defer { f.remove() }
        var task = TranscriptRepairTask(recordingID: f.id, source: f.original, configuration: f.configuration)
        task.status = .running
        for i in task.intervals.indices { task.intervals[i].document = TranscriptDocument(text: "Recovered \(i)") }
        try f.repairStore.save([task], recordingID: f.id)
        let session = f.session()
        #expect(session.tasks.first?.status == .awaitingLocalSave)
        session.retrySaving()
        #expect(session.tasks.first?.status == .completed)
        #expect(f.processing.materials[f.id]?.results.last?.id == task.resultID)
        let reopened = f.session(); reopened.retrySaving()
        #expect(f.processing.materials[f.id]?.results.count == 2)
    }
    @Test func journalSaveFailurePreservesCopiesAndRequiresManualResume() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let path = f.folder.appendingPathComponent("transcript-repair-tasks.json")
        let session = f.session()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let copy = path.appendingPathComponent("user-copy.txt"); try Data("keep".utf8).write(to: copy)
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        #expect(session.needsSave); #expect(await f.service.ranges.isEmpty)
        #expect(try String(contentsOf: copy) == "keep")
        try FileManager.default.moveItem(at: path, to: f.folder.appendingPathComponent("preserved-copy"))
        session.retrySaving()
        #expect(!session.needsSave); #expect(session.tasks.first?.status == .awaitingResume)
        #expect(await f.service.ranges.isEmpty)
        session.resume(id); try await settle { session.tasks.first?.status == .completed }
        #expect(try String(contentsOf: f.folder.appendingPathComponent("preserved-copy/user-copy.txt")) == "keep")
    }
    @Test func finalSaveFailureRetryIsLocalAndStableResultIDPreservesEditing() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        var task = TranscriptRepairTask(recordingID: f.id, source: f.original, configuration: f.configuration)
        task.status = .awaitingLocalSave
        for i in task.intervals.indices { task.intervals[i].document = TranscriptDocument(text: "Saved repair \(i)") }
        try f.repairStore.save([task], recordingID: f.id)
        let session = f.session()
        let transcript = f.folder.appendingPathComponent("transcription.json")
        try FileManager.default.moveItem(at: transcript, to: f.folder.appendingPathComponent("transcription-before.json"))
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: false)
        session.retrySaving()
        #expect(session.tasks.first?.status == .awaitingLocalSave)
        #expect(session.needsSave)
        try FileManager.default.removeItem(at: transcript)
        session.retrySaving()
        #expect(session.tasks.first?.status == .completed)
        #expect(await f.service.ranges.isEmpty)
        let repaired = try #require(f.processing.materials[f.id]?.results.last)
        f.processing.saveTranscriptText(recordingID: f.id, resultID: repaired.id, text: "EDIT AFTER SAVE")
        session.retrySaving()
        #expect(f.processing.materials[f.id]?.results.last?.text == "EDIT AFTER SAVE")
        #expect(f.processing.materials[f.id]?.results.count == 2)
    }
    @Test func unknownPlaybackAnchorsRemainUnavailableAndMissingCredentialMakesNoCalls() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        f.credentials.key = nil
        let session = f.session()
        _ = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        try await settle { session.tasks.first?.status == .failed }
        #expect(session.tasks.first?.failure == .credential)
        #expect(await f.service.ranges.isEmpty)
        #expect(f.processing.materials[f.id]?.results.count == 1)
        var task = TranscriptRepairTask(recordingID: f.id, source: f.original, configuration: f.configuration)
        task.intervals[0].document = TranscriptDocument(text: "Untimed repair")
        #expect(task.repairedDocument.paragraphs.first(where: { $0.text == "Untimed repair" })?.playbackStart == nil)
    }
    @Test func activeRecordingCannotSubmitRepair() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        await f.recordings.start()
        let active = try #require(f.recordings.activeID)
        let resultID = UUID()
        #expect(f.processing.saveTranscriptResult(recordingID: active, resultID: resultID, createdAt: Date(),
            configuration: f.configuration, document: f.original.currentDocument))
        let session = f.session()
        #expect(session.submit(recordingID: active, sourceResultID: resultID, configuration: f.configuration) == nil)
        #expect(await f.service.ranges.isEmpty)
        f.recordings.stop()
    }
    @Test func shutdownWaitsForWorkerAndLeavesManualResumeWithoutAcceptingLateSuccess() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        await f.service.setHold(true)
        let session = f.session()
        _ = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        try await settle { await f.service.isHolding }
        var finished = false
        let shutdown = Task { await session.awaitShutdown(); finished = true }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!finished); #expect(f.gate.activeID != nil)
        await f.service.release(); await shutdown.value
        #expect(session.tasks.first?.status == .awaitingResume)
        #expect(session.tasks.first?.completedCount == 0)
        #expect(f.processing.materials[f.id]?.results.count == 1)
        #expect(f.gate.activeID == nil)
        #expect(session.prepareToQuit())
        session.continueAfterCancelledQuit()
        await f.service.setHold(false)
        session.resume(try #require(session.tasks.first?.id))
        try await settle { session.tasks.first?.status == .completed }
    }
    @Test func cancelledQuitPreflightKeepsHealthyQueuedRepairAndItsGatePosition() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let blocker = UUID(); f.gate.enqueue(id: blocker) {}
        let session = f.session()
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        #expect(session.tasks.first?.status == .queued)
        #expect(session.prepareToQuit())
        session.continueAfterCancelledQuit()
        #expect(session.tasks.first?.status == .queued)
        #expect(await f.service.ranges.isEmpty)
        f.gate.finish(id: blocker)
        try await settle { session.tasks.first?.status == .completed }
        #expect(session.tasks.first?.id == id)
        #expect(await f.service.ranges.count == 2)
    }
    @Test func shutdownJournalFailureVetoesQuitAndManualResumeWorksAfterLocalRecovery() async throws {
        let f = try RepairFixture(); defer { f.remove() }
        let blocker = UUID(); f.gate.enqueue(id: blocker) {}
        let session = f.session()
        let id = try #require(session.submit(recordingID: f.id, sourceResultID: f.original.id, configuration: f.configuration))
        #expect(session.prepareToQuit())
        let journal = f.folder.appendingPathComponent("transcript-repair-tasks.json")
        try FileManager.default.moveItem(at: journal, to: f.folder.appendingPathComponent("before-quit.json"))
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        let copy = journal.appendingPathComponent("user-copy.txt")
        try Data("preserve".utf8).write(to: copy)
        await session.awaitShutdown()
        #expect(!session.prepareToQuit())
        #expect(session.needsSave)
        #expect(await f.service.ranges.isEmpty)
        #expect(try String(contentsOf: copy) == "preserve")
        session.continueAfterCancelledQuit()
        try FileManager.default.moveItem(at: journal, to: f.folder.appendingPathComponent("preserved-quit-copy"))
        session.retrySaving()
        #expect(session.prepareToQuit())
        #expect(session.tasks.first?.status == .awaitingResume)
        f.gate.finish(id: blocker)
        #expect(await f.service.ranges.isEmpty)
        session.resume(id)
        try await settle { session.tasks.first?.status == .completed }
        #expect(f.processing.materials[f.id]?.results.first == f.original)
        #expect(try String(contentsOf: f.folder.appendingPathComponent("preserved-quit-copy/user-copy.txt")) == "preserve")
    }
    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }
}

@MainActor private final class RepairFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-tests-\(UUID())")
    let id = UUID(), configuration = AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-1")
    let store: RecordingStore
    let repairStore: TranscriptRepairStore
    let recordings: RecordingSession
    let processing: PostRecordingSession
    let credentials = RepairCredentials(), service = RepairService(), gate = BackgroundProcessingGate()
    let original: TranscriptResult
    var folder: URL { store.audioURL(for: id).deletingLastPathComponent() }
    init() throws {
        store = RecordingStore(root: root); repairStore = TranscriptRepairStore(recordings: store)
        let recording = Recording(id: id, startedAt: Date(), defaultName: "Saved", name: "Saved", duration: 6, status: .saved)
        try store.save(recording)
        try Data("preserved original audio".utf8).write(to: store.audioURL(for: id))
        let text = "Edited first.\n\nEdited last."
        let document = TranscriptDocument(text: text, anchors: [
            .init(sourceStart: 0, sourceEnd: 0.9, range: .init(location: 0, length: 13)),
            .init(sourceStart: 3, sourceEnd: 3.9, range: .init(location: 15, length: 12))], missingIntervals: [
                .init(startFrame: 24_000, endFrame: 48_000), .init(startFrame: 96_000, endFrame: 120_000)])
        original = .init(id: UUID(), createdAt: Date(), model: "gpt-live-transcribe", text: text,
            service: .init(provider: .aiHubMix, model: "gpt-live-transcribe"), document: document)
        var material = TranscriptionMaterial(); material.results = [original]; try store.saveTranscription(material, for: id)
        recordings = RecordingSession(store: store, recorder: RepairRecorder())
        processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: RepairUnusedService(), gate: gate)
    }
    func session() -> TranscriptRepairSession { .init(recordings: recordings, processing: processing, store: repairStore, credentials: credentials, service: service, gate: gate) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class RepairCredentials: AudioCredentials {
    var key: String? = "controlled"
    func read(for configuration: AudioServiceConfiguration) throws -> String? { key }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { key = value }
    func delete(for configuration: AudioServiceConfiguration) throws { key = nil }
}
private actor RepairService: IntervalTranscribing {
    var ranges: [MissingInterval] = [], configurations: [AudioServiceConfiguration] = []
    var failStart: Int64?, hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }
    func setFailStart(_ value: Int64?) { failStart = value }
    func setHold(_ value: Bool) { hold = value }
    func release() { continuation?.resume(); continuation = nil }
    func transcribe(audio: URL, interval: MissingInterval, configuration: AudioServiceConfiguration, apiKey: String) async throws -> TranscribedAudio {
        ranges.append(interval); configurations.append(configuration)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if interval.startFrame == failStart { throw AudioProcessingError.unavailable }
        let text = "Repair \(interval.startFrame == 24_000 ? 1 : 2)"
        return .init(text: text, anchors: [.init(sourceStart: interval.start + 0.1, sourceEnd: interval.end - 0.1, range: .init(location: 0, length: text.utf16.count))])
    }
}
private struct RepairUnusedService: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
}
@MainActor private final class RepairRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { try Data([1]).write(to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
