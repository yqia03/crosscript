import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualRecordingActionsTests {
    @Test func everyPauseActionWaitsUntilBilingualTailHasDrained() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        #expect(await fixture.bilingual.start(configuration: .init(provider: .gemini), direction: .englishToChinese))
        let pausing = Task { await fixture.actions.togglePause() }
        try await wait { fixture.bilingual.isPausing && fixture.recordings.isPaused }
        #expect(fixture.actions.isFinishingPause && !fixture.actions.canTogglePause)
        await fixture.actions.togglePause()
        #expect(fixture.recorder.resumes == 0)
        await pausing.value
        #expect(!fixture.actions.isFinishingPause && fixture.actions.canTogglePause)
        await fixture.actions.togglePause()
        #expect(fixture.recorder.resumes == 1)
        await fixture.actions.stop()
    }

    @Test func sharedActionsPauseResumeAndStopTheBilingualOwnerWithoutNewCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let actions = fixture.actions
        #expect(actions.canStart && fixture.credentials.reads == 0)
        #expect(await fixture.bilingual.start(configuration: .init(provider: .gemini), direction: .englishToChinese))
        #expect(!actions.canStart && fixture.recorder.starts == 1 && fixture.service.connections == 1)
        fixture.service.emit(.text(channel: .source, eventID: "a", delta: "Source", startOffset: nil, endOffset: nil, finished: nil))
        fixture.service.emit(.text(channel: .translation, eventID: "b", delta: "译文", startOffset: nil, endOffset: nil, finished: nil))
        await Task.yield()
        await actions.togglePause()
        #expect(fixture.recordings.isPaused && fixture.recorder.pauses == 1)
        await actions.togglePause()
        #expect(fixture.recordings.isRecording && fixture.recorder.resumes == 1)
        fixture.bilingual.cancelCloud()
        #expect(fixture.recordings.isRecording && !actions.canStart)
        await actions.stop()
        let result = try #require(fixture.presentation.result)
        #expect(fixture.recorder.stops == 1 && fixture.recorder.starts == 1)
        #expect(!fixture.bilingual.isActive && !fixture.recordings.hasActiveRecording && actions.canStart)
        #expect(result.document.source.text == "Source" && result.document.translation.text == "译文")
        #expect(try fixture.results.load(result.recordingID).first?.id == result.id)
    }

    @Test func pendingBilingualWriteBlocksNewCaptureAndLocalRetryPreservesEdits() async throws {
        let fixture = try Fixture(failPublication: true)
        defer { fixture.clean() }
        let oldID = try fixture.addUnreadablePriorDraft()
        let recovery = fixture.recoveryController()
        #expect(recovery.failedIDs == [oldID])
        #expect(await fixture.bilingual.start(configuration: .init(provider: .gemini), direction: .chineseToEnglish))
        fixture.service.emit(.text(channel: .source, eventID: "a", delta: "原文", startOffset: nil, endOffset: nil, finished: true))
        await Task.yield()
        await fixture.actions.stop()
        #expect(fixture.bilingual.needsSaveRetry && !fixture.actions.canStart)
        fixture.presentation.editPending("用户保留修改", channel: .source)
        recovery.retry()
        fixture.publicationFails = false
        fixture.bilingual.retrySave()
        #expect(!fixture.bilingual.needsSaveRetry && fixture.actions.canStart)
        let result = try #require(fixture.presentation.result)
        #expect(try fixture.results.load(result.recordingID).first?.document.source.text == "用户保留修改")
        #expect(fixture.service.connections == 1 && fixture.credentials.reads == 1)
    }

    @Test func retryingOldRecoveryDuringFinishingDoesNotPublishTheNewDraftBeforeItsTail() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let oldID = try fixture.addUnreadablePriorDraft()
        let recovery = fixture.recoveryController()
        #expect(recovery.failedIDs == [oldID])
        #expect(await fixture.bilingual.start(configuration: .init(provider: .gemini), direction: .englishToChinese))
        fixture.service.emit(.text(channel: .source, eventID: "initial", delta: "First. ", startOffset: nil, endOffset: nil, finished: nil))
        try await wait { fixture.presentation.document.source.text == "First. " }
        let stopping = Task { await fixture.actions.stop() }
        try await wait { fixture.bilingual.cloudState == .finishing }
        let recordingID = try #require(fixture.presentation.result?.recordingID)
        #expect(fixture.recordings.canCreateProject)
        recovery.retry()
        #expect(try fixture.results.load(recordingID).isEmpty)
        fixture.service.emit(.text(channel: .source, eventID: "tail", delta: "Tail preserved.", startOffset: nil, endOffset: nil, finished: true))
        await stopping.value
        #expect(try fixture.results.load(recordingID).first?.document.source.text == "First. Tail preserved.")
        #expect(recovery.failedIDs == [oldID])
    }

    @Test func ordinaryRecordingControlsRemainLocalAndDoNotReadAnyKey() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.recordings.start()
        await fixture.actions.togglePause()
        await fixture.actions.togglePause()
        await fixture.actions.stop()
        #expect(fixture.recorder.starts == 1 && fixture.recorder.pauses == 1 && fixture.recorder.resumes == 1 && fixture.recorder.stops == 1)
        #expect(fixture.credentials.reads == 0 && fixture.service.connections == 0)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-actions-\(UUID())")
        let recorder = Recorder()
        let credentials = Credentials()
        let service = Service()
        let recordings: RecordingSession
        let results: BilingualResultStore
        var publicationFails: Bool
        lazy var presentation = BilingualSessionState { [unowned self] result in
            if publicationFails { throw AudioProcessingError.storage }
            return try results.publish(result)
        }
        lazy var bilingual = LiveBilingualSession(recordings: recordings, credentials: credentials, service: service,
            presentation: presentation, drafts: BilingualDraftStore(recordings: store), responseTimeout: 0.01,
            capabilityAllowsStart: { $0.provider == .gemini })
        var actions: RecordingActions { .init(recordings: recordings, bilingual: bilingual) }
        private let store: RecordingStore
        init(failPublication: Bool = false) throws {
            publicationFails = failPublication
            store = RecordingStore(root: root)
            results = BilingualResultStore(recordings: store)
            recordings = RecordingSession(store: store, recorder: recorder)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func recoveryController() -> BilingualDraftRecoveryController {
            .init(drafts: BilingualDraftStore(recordings: store), recordings: recordings, results: results)
        }
        func addUnreadablePriorDraft() throws -> UUID {
            let id = UUID()
            try store.save(Recording(id: id, startedAt: Date(), defaultName: "Old draft", name: "Old draft", duration: 1, status: .saved))
            try Data("{".utf8).write(to: store.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("bilingual-draft.json"))
            recordings.refresh()
            return id
        }
    }
    @MainActor private final class Recorder: AudioRecording {
        var currentTime: TimeInterval = 1
        var power: Float { -40 }
        var onFailure: ((Error) -> Void)?
        var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?
        var onLiveAudioFailure: (@Sendable (Error) -> Void)?
        var starts = 0, stops = 0, pauses = 0, resumes = 0
        func requestPermission(for source: AudioSource) async throws {}
        func start(at url: URL, source: AudioSource) async throws { starts += 1; try Data([0]).write(to: url) }
        func pause() async throws { pauses += 1 }
        func resume() async throws { resumes += 1 }
        func stop() -> TimeInterval { stops += 1; return currentTime }
    }
    @MainActor private final class Credentials: AudioCredentials {
        var reads = 0
        func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; return "controlled-token" }
        func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
        func delete(for configuration: AudioServiceConfiguration) throws {}
    }
    @MainActor private final class Service: LiveBilingualTranslating {
        var connections = 0
        var continuation: AsyncThrowingStream<LiveBilingualTransportEvent, Error>.Continuation?
        func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection, apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> {
            connections += 1
            let pair = AsyncThrowingStream<LiveBilingualTransportEvent, Error>.makeStream()
            continuation = pair.continuation; emit(.configured)
            return pair.stream
        }
        func emit(_ event: LiveBilingualTransportEvent) { continuation?.yield(event) }
        func append(_ chunk: LiveAudioChunk) async throws {}
        func finishInput() async throws {}
        func close() { continuation?.finish(); continuation = nil }
    }
}
