import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualRepairTests {
    @Test func cancellingWhileCredentialAuthorizationWaitsRejectsLateKey() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        let credentials = SuspendedRepairCredentials()
        let session = f.makeSession(credentials: credentials)
        let task = try #require(session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        try await f.settle { credentials.isWaiting }
        #expect(session.authorizingID == task)
        // Reaching this actor while authorization is suspended proves UI work
        // and cancellation can proceed without blocking on the credential read.
        session.cancel(task)
        #expect(session.tasks.first?.status == .cancelled)
        credentials.release()
        try await f.settle { session.runningID == nil }
        #expect(session.authorizingID == nil && f.gate.activeID == nil)
        #expect(await f.service.channels.isEmpty)
        #expect(try f.results.load(f.id) == [f.source])
        #expect(session.tasks.first?.status == .cancelled)
        #expect(credentials.readConfigurations == [f.configuration])
    }
    @Test func journalAcceptsExactPartitionsButRejectsMissingOverlappingAndReorderedRanges() throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        let task = BilingualRepairTask(source: f.source, configuration: f.configuration, maximumIntervalFrames: 12_000)
        #expect(task.parts.count == 4)
        try f.journal.save([task], recordingID: f.id)
        #expect(try f.journal.load(f.id) == [task])
        var missing = task; missing.parts.removeFirst()
        #expect(throws: AudioProcessingError.storage) { try f.journal.save([missing], recordingID: f.id) }
        var duplicate = task; duplicate.parts.insert(.init(channel: task.parts[0].channel, interval: task.parts[0].interval), at: 1)
        #expect(throws: AudioProcessingError.storage) { try f.journal.save([duplicate], recordingID: f.id) }
        var reordered = task; reordered.parts.swapAt(0, 1)
        #expect(throws: AudioProcessingError.storage) { try f.journal.save([reordered], recordingID: f.id) }
        #expect(try f.journal.load(f.id) == [task])
    }
    @Test func interruptedAfterLastCheckpointOffersLocalSaveWithoutAnotherRequest() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        var task = BilingualRepairTask(source: f.source, configuration: f.configuration)
        for index in task.parts.indices { task.parts[index].document = .init(text: "saved checkpoint") }
        task.status = .running
        try f.journal.save([task], recordingID: f.id)
        let restored = f.makeSession()
        #expect(restored.tasks.first?.status == .awaitingLocalSave)
        #expect(restored.tasks.first?.remainingParts.isEmpty == true)
        #expect(f.credentials.reads == 0 && restored.runningID == nil)
        restored.retrySaving()
        #expect(restored.tasks.first?.status == .completed)
        let saved = try f.results.load(f.id)
        #expect(saved.count == 2 && saved.first == f.source)
        #expect(saved.last?.document.isComplete == true)
        #expect(await f.service.channels.isEmpty && f.credentials.reads == 0)
    }
    @Test func unavailableCapabilityDoesNotReadCredentialsOrSubmitWork() throws {
        let f = try BilingualRepairFixture(unavailable: true); defer { f.remove() }
        #expect(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration) == nil)
        #expect(f.credentials.reads == 0 && f.session.tasks.isEmpty && f.gate.activeID == nil)
        #expect(try f.results.load(f.id) == [f.source])
    }
    @Test func partialChannelFailureRetriesOnlyMissingTranslationAndPreservesOldEdits() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        await f.service.configure(failTranslation: true)
        let taskID = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        try await f.settle { f.session.runningID == nil && f.session.tasks.first?.status == .failed }
        var saved = try f.results.load(f.id)
        #expect(saved.count == 2 && saved[0] == f.source)
        #expect(!saved[1].document.isComplete && saved[1].document.source.missingIntervals.isEmpty)
        #expect(saved[1].document.translation.missingIntervals.count == 1)
        #expect(saved[1].document.source.text.hasPrefix("USER SOURCE EDIT"))
        #expect(saved[1].document.source.anchors.isEmpty)
        let partial = saved[1]
        saved[1].document.edit("USER PARTIAL EDIT", channel: .source)
        try f.results.saveEdit(saved[1], replacing: partial)
        await f.service.configure(failTranslation: false)
        f.session.resume(taskID)
        try await f.settle { f.session.runningID == nil && f.session.tasks.first?.status == .completed }
        let reopened = try BilingualResultStore(recordings: f.store).load(f.id)
        #expect(reopened.count == 3 && reopened[0] == f.source && reopened[1] == saved[1])
        #expect(reopened[2].id != partial.id && reopened[2].document.isComplete)
        #expect(reopened[2].document.translation.text.hasPrefix("用户译文编辑"))
        #expect(await f.service.channels == [.source, .translation, .translation])
        #expect(try Data(contentsOf: f.store.audioURL(for: f.id)) == f.audio)
        #expect(try f.store.loadTranscription(for: f.id).results.isEmpty)
    }
    @Test func cancellationHoldsSharedGateUntilLateWorkReturnsAndRestartRequiresManualResume() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        await f.service.configure(holdTranslation: true)
        let taskID = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        try await f.settleAsync { await f.service.isHeld }
        var nextStarted = false
        let other = UUID()
        f.gate.enqueue(id: other) { nextStarted = true }
        f.session.cancel(taskID)
        #expect(!nextStarted && f.gate.activeID == taskID)
        await f.service.release()
        try await f.settle { f.session.runningID == nil }
        #expect(nextStarted && f.gate.activeID == other)
        f.gate.finish(id: other)
        #expect(f.session.tasks.first?.status == .cancelled)
        let partial = try #require(f.results.load(f.id).last)
        #expect(!partial.document.translation.text.contains("repaired translation"))
        var task = try #require(f.journal.load(f.id).first)
        task.status = .running
        try f.journal.save([task], recordingID: f.id)
        let before = await f.service.channels.count
        let restored = f.makeSession()
        #expect(restored.tasks.first?.status == .awaitingResume && restored.runningID == nil)
        #expect(await f.service.channels.count == before)
        await f.service.configure(holdTranslation: false)
        restored.resume(taskID)
        try await f.settle { restored.tasks.first?.status == .completed && restored.runningID == nil }
        #expect(await f.service.channels == [.source, .translation, .translation])
        #expect(try f.results.load(f.id).contains(partial))
    }
    @Test func failedResultPublicationRetainsPartsAndLocalRetryMakesNoServiceCall() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        await f.service.configure(holdTranslation: true)
        _ = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        try await f.settleAsync { await f.service.isHeld }
        let path = f.store.audioURL(for: f.id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json")
        let retained = path.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: path, to: retained)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await f.service.release()
        try await f.settle { f.session.runningID == nil && f.session.tasks.first?.status == .awaitingLocalSave }
        #expect(!f.session.prepareToQuit())
        #expect(f.session.tasks.first?.completedCount == 2)
        let task = try #require(f.session.tasks.first)
        let generatedParts = task.parts
        f.session.editPending(task.id, text: "Pending source user edit", channel: .source)
        f.session.editPending(task.id, text: "待保存译文手改", channel: .translation)
        #expect(f.session.tasks.first?.parts == generatedParts)
        let restored = f.makeSession()
        let pending = try #require(restored.tasks.first)
        #expect(pending.status == .awaitingLocalSave && pending.resultID == task.resultID)
        #expect(pending.result.document.exported() == "Pending source user edit\n\n待保存译文手改")
        #expect(pending.parts == generatedParts && !restored.prepareToQuit())
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: retained, to: path)
        restored.retrySaving()
        #expect(restored.prepareToQuit() && restored.tasks.first?.status == .completed)
        #expect(restored.error == nil)
        #expect(await f.service.channels.count == 2)
        #expect(try f.results.load(f.id).count == 2)
        #expect(try f.results.load(f.id).first == f.source)
        let published = try #require(f.results.load(f.id).last)
        #expect(published.id == task.resultID && published.document == pending.result.document)
        f.session.retrySaving()
        #expect(try f.results.load(f.id).last == published)
    }
    @Test func journalFailureBlocksCallsAndSaveRetryDoesNotSilentlyResume() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        let path = f.store.audioURL(for: f.id).deletingLastPathComponent().appendingPathComponent("bilingual-repair-tasks.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let id = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        #expect(f.session.needsSave && f.credentials.reads == 0 && f.gate.activeID == nil)
        try FileManager.default.removeItem(at: path)
        f.session.retrySaving()
        #expect(!f.session.needsSave && f.session.tasks.first?.status == .awaitingResume)
        #expect(f.credentials.reads == 0)
        f.session.resume(id)
        try await f.settle { f.session.tasks.first?.status == .completed && f.session.runningID == nil }
    }
    @Test func quitPreflightAndCancelledQuitKeepHealthyQueuedRepairInTheSharedQueue() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        let pdfTask = UUID()
        f.gate.enqueue(id: pdfTask) {}
        let repairID = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        #expect(f.session.tasks.first?.status == .queued && f.credentials.reads == 0)
        #expect(f.session.prepareToQuit())
        f.session.continueAfterCancelledQuit()
        #expect(f.session.tasks.first?.status == .queued && f.gate.activeID == pdfTask)
        f.gate.finish(id: pdfTask)
        try await f.settle { f.session.runningID == nil && f.session.tasks.first?.status == .completed }
        #expect(f.session.tasks.first?.id == repairID && f.credentials.reads == 1)
        #expect(await f.service.channels == [.source, .translation])
    }
    @Test func independentChannelContinuityNeverReplaysOfflinePCMOrUsesPausedWallTime() throws {
        var continuity = BilingualAudioContinuity()
        func chunk(_ start: Int64) throws -> LiveAudioChunk { try .init(pcm16: Data(repeating: 0, count: 24_000), recordingStartFrame: start) }
        #expect(try continuity.capture(chunk(0)) == nil)
        let first = continuity.attachCurrent()
        #expect(try continuity.capture(chunk(12_000)) == first)
        continuity.confirm(channel: .source, throughFrame: 24_000, generation: first)
        continuity.disconnect(generation: first)
        #expect(try continuity.capture(chunk(24_000)) == nil)
        let second = continuity.attachCurrent()
        // A pause does not call capture: the next media start is still 36000.
        #expect(continuity.capturedEndFrame == 36_000)
        continuity.confirm(channel: .translation, throughFrame: 36_000, generation: first)
        #expect(try continuity.capture(chunk(36_000)) == second)
        continuity.disconnect(generation: second)
        #expect(continuity.missing(.source).map(\.startFrame) == [0, 24_000])
        #expect(continuity.missing(.translation).map(\.startFrame) == [0])
        #expect(continuity.missing(.translation).last?.endFrame == 48_000)
        let restored = try JSONDecoder().decode(BilingualAudioContinuity.self, from: JSONEncoder().encode(continuity))
        #expect(restored.capturedEndFrame == 48_000 && restored.generation == nil)
        #expect(restored.missing(.source).map(\.endFrame) == [12_000, 48_000])
    }
    @Test func confirmedQuitFreezesTheSharedGateBeforeAnEarlierOwnerFinishes() async throws {
        let f = try BilingualRepairFixture(); defer { f.remove() }
        let pdfTask = UUID()
        f.gate.enqueue(id: pdfTask) {}
        let repairID = try #require(f.session.submit(recordingID: f.id, sourceResultID: f.source.id, configuration: f.configuration))
        #expect(f.session.prepareToQuit() && f.session.tasks.first?.status == .queued)
        f.gate.suspendDispatch()
        // PDF termination completes before this repair owner is awaited.
        f.gate.finish(id: pdfTask)
        #expect(f.gate.activeID == nil && f.credentials.reads == 0 && f.session.runningID == nil)
        await f.session.awaitShutdown()
        #expect(f.session.prepareToQuit() && f.session.tasks.first?.status == .awaitingResume)
        #expect(try f.journal.load(f.id).first?.status == .awaitingResume)
        // Another owner's failed save keeps the App open. No automatic call.
        f.session.continueAfterCancelledQuit(); f.gate.resumeDispatch()
        #expect(f.gate.activeID == nil && f.credentials.reads == 0)
        f.session.resume(repairID)
        try await f.settle { f.session.runningID == nil && f.session.tasks.first?.status == .completed }
        #expect(f.credentials.reads == 1 && f.session.tasks.first?.id == repairID)
    }
}

@MainActor private final class BilingualRepairFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-repair-\(UUID())")
    let id = UUID()
    let audio = Data([1, 2, 3, 4])
    let configuration = AudioServiceConfiguration(provider: .openAI, model: "controlled-bilingual-only")
    let store: RecordingStore
    let recordings: RecordingSession
    let results: BilingualResultStore
    let journal: BilingualRepairStore
    let credentials = BilingualRepairCredentials()
    let service = ControlledBilingualRepair()
    let gate = BackgroundProcessingGate()
    let source: BilingualResult
    var session: BilingualRepairSession!
    init(unavailable: Bool = false) throws {
        store = RecordingStore(root: root)
        try store.save(.init(id: id, startedAt: Date(), defaultName: "Bilingual", name: "Bilingual", duration: 4, status: .saved))
        try audio.write(to: store.audioURL(for: id))
        results = .init(recordings: store); journal = .init(recordings: store)
        recordings = RecordingSession(store: store, recorder: RepairTestRecorder())
        var document = BilingualTranscriptDocument()
        document.append("USER SOURCE EDIT", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("用户译文编辑", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.addMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .source)
        document.addMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .translation)
        document.finish()
        source = .init(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        try results.publish(source)
        session = makeSession(unavailable: unavailable)
    }
    func makeSession(unavailable: Bool = false, credentials overrideCredentials: (any AudioCredentials)? = nil) -> BilingualRepairSession {
        .init(recordings: recordings, results: results, journal: journal, credentials: overrideCredentials ?? credentials,
              service: unavailable ? UnavailableBilingualRepair() : service, gate: gate)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func settle(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
    func settleAsync(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await condition()), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
    }
}
private actor ControlledBilingualRepair: BilingualIntervalRepairing {
    var channels: [BilingualChannel] = []
    private var failTranslation = false
    private var holdTranslation = false
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    func configure(failTranslation: Bool = false, holdTranslation: Bool = false) {
        self.failTranslation = failTranslation; self.holdTranslation = holdTranslation
    }
    func release() { held?.resume(); held = nil }
    nonisolated func supports(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) -> Bool { configuration.model == "controlled-bilingual-only" }
    func repair(audio: URL, interval: MissingInterval, channel: BilingualChannel, configuration: AudioServiceConfiguration,
                direction: TextTranslationDirection, apiKey: String) async throws -> TranscriptDocument {
        channels.append(channel)
        if channel == .translation && holdTranslation { await withCheckedContinuation { held = $0 } }
        if channel == .translation && failTranslation { throw AudioProcessingError.processing }
        return .init(text: channel == .source ? "repaired source" : "repaired translation")
    }
}
@MainActor private final class BilingualRepairCredentials: AudioCredentials {
    var reads = 0
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; return "controlled-only" }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
@MainActor private final class RepairTestRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}

@MainActor private final class SuspendedRepairCredentials: AudioCredentials {
    var readConfigurations: [AudioServiceConfiguration] = []
    private var pending: CheckedContinuation<String?, Never>?
    var isWaiting: Bool { pending != nil }
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String? {
        readConfigurations.append(configuration)
        return await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: "fixture-only"); pending = nil }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { Issue.record("Synchronous credential read must not block repair authorization"); return nil }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
