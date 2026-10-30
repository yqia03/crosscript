import Combine
import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct LiveBilingualSessionTests {
    @Test func transcriptDeltasRefreshTheirPresentationWithoutInvalidatingSessionControls() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        try await Task.sleep(for: .milliseconds(20))
        var invalidations = 0
        let observation = f.live.objectWillChange.sink { invalidations += 1 }
        f.service.emit(f.text(.source, "words", id: "source"))
        f.service.emit(f.text(.translation, "文字", id: "translation"))
        try await f.settle { f.state.document.translation.text == "文字" }
        #expect(f.state.document.source.text == "words" && invalidations == 0)
        f.live.cancelCloud()
        #expect(invalidations > 0)
        observation.cancel()
        await f.live.stop()
    }

    @Test(arguments: [false, true]) func cancellingSessionReleasesOwnedAuthorizationTask(stop: Bool) async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        f.credentials.cooperativeHold = true
        var startFinished = false
        let start = Task { _ = await f.start(); startFinished = true }
        try await f.settle { f.credentials.cooperativeWaiting }
        let began = ContinuousClock.now
        if stop { await f.live.stop() } else { f.live.cancelCloud() }
        try await f.settle { startFinished }
        await start.value
        #expect(began.duration(to: .now) < .milliseconds(150))
        #expect(!f.credentials.cooperativeWaiting && f.service.connections.isEmpty)
        #expect(!f.live.isAwaitingCredentials)
        if !stop { #expect(f.recordings.isRecording); await f.live.stop() }
    }

    @Test func unverifiedTargetDoesNotReadCredentialsOrStartCapture() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        let session = LiveBilingualSession(recordings: f.recordings, credentials: f.credentials,
            service: f.service, presentation: f.state)
        let unverified = AudioServiceConfiguration(provider: .openAI, model: "gpt-realtime-translate")
        #expect(f.credentials.reads.isEmpty && f.service.connections.isEmpty)
        #expect(!(await session.start(configuration: unverified, direction: .englishToChinese)))
        #expect(f.recorder.starts == 0 && f.credentials.reads.isEmpty)
        #expect(!LiveBilingualCapability.forConfiguration(unverified).canStart)
        #expect(LiveBilingualCapability.forConfiguration(f.configuration) == .availableWithLimitations)
    }

    @Test func stoppingDuringAuthorizationDoesNotWaitForCloudDrain() async throws {
        let f = BilingualSessionFixture(timeout: 0.3); defer { f.credentials.releaseRead(); f.remove() }
        f.credentials.holdRead = true
        let start = Task { await f.start() }
        try await f.settle { f.credentials.readHeld }
        try f.recorder.capture(frames: 2_400)
        let began = ContinuousClock.now
        await f.live.stop()
        let elapsed = began.duration(to: .now)
        #expect(elapsed < .milliseconds(150), "No cloud connection exists to drain: \(elapsed)")
        #expect(!f.live.isActive && !f.live.isAwaitingCredentials)
        f.credentials.releaseRead()
        _ = await start.value
        #expect(f.service.connections.isEmpty)
        #expect(f.recordings.selectedRecording?.duration == 0.1)
    }

    @Test func authorizationFromStoppedSessionCannotConnectOrChangeReplacement() async throws {
        let f = BilingualSessionFixture(); defer { f.credentials.releaseRead(); f.remove() }
        f.credentials.holdRead = true
        let old = Task { await f.start() }
        try await f.settle { f.credentials.readHeld }
        await f.live.stop()
        f.credentials.holdRead = false
        #expect(await f.start())
        let current = f.live.snapshot
        f.credentials.releaseRead()
        _ = await old.value
        #expect(f.live.snapshot == current && f.live.cloudState == .connected)
        #expect(f.service.connections.count == 1 && !f.live.isAwaitingCredentials)
        await f.live.stop()
    }

    @Test func authorizationWaitIsAsyncAndCancellationRejectsLateKey() async throws {
        let f = BilingualSessionFixture(); defer { f.credentials.releaseRead(); f.remove() }
        f.credentials.holdRead = true
        let start = Task { await f.start() }
        try await f.settle { f.credentials.readHeld || f.live.cloudState == .failed }
        #expect(f.credentials.readHeld, "Formal session must use the asynchronous credential boundary")
        #expect(f.recordings.isRecording && f.service.connections.isEmpty)
        try f.recorder.capture(frames: 2_400)
        f.live.cancelCloud()
        await f.live.stop()
        #expect(!f.live.isActive && f.recordings.selectedRecording?.duration == 0.1)
        f.credentials.releaseRead()
        _ = await start.value
        #expect(f.service.connections.isEmpty, "Late authorization must never upload after cancellation")
    }

    @Test func bothChannelsArriveDuringSingleCaptureAndGenericEndEventsCannotConfirmMedia() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        f.service.emit(.text(channel: .source, eventID: "shared", delta: "Hello", startOffset: 0, endOffset: 0.5, finished: true))
        f.service.emit(.text(channel: .translation, eventID: "shared", delta: "你好", startOffset: 0, endOffset: 99, finished: true))
        f.service.emit(.text(channel: .source, eventID: "shared", delta: "duplicate", startOffset: nil, endOffset: nil, finished: nil))
        f.service.emit(.generationComplete); f.service.emit(.turnComplete); f.service.emit(.interactionStatus(.idle))
        try await f.settle { f.state.document.translation.text == "你好" && f.live.interactionStatus == .idle }
        #expect(f.recorder.starts == 1 && f.recordings.isRecording)
        #expect(f.state.document.source.text == "Hello" && f.state.document.alignment.count == 2)
        #expect(f.state.document.alignment.allSatisfy { $0.elapsedMilliseconds == nil })
        #expect(f.state.document.source.anchors.isEmpty && f.state.document.translation.anchors.isEmpty)
        let snapshot = try #require(f.live.snapshot)
        await f.live.stop()
        let result = try #require(f.results.load(snapshot.recordingID).first)
        #expect(result.id == snapshot.resultID && result.configuration == f.configuration)
        #expect(result.document.completedChannels.isEmpty && !result.document.isComplete)
        #expect(ranges(result.document.source.missingIntervals) == [0..<12_000])
        #expect(ranges(result.document.translation.missingIntervals) == ranges(result.document.source.missingIntervals))
        #expect(f.service.finishes == 1 && !f.live.needsSaveRetry)
        #expect(try f.drafts.load(snapshot.recordingID) == nil)
        f.service.emitOld(.text(channel: .source, eventID: "late", delta: "late", startOffset: nil, endOffset: nil, finished: nil))
        await Task.yield()
        #expect(f.state.document.source.text == "Hello")
    }

    @Test func credentialsAreReadOnlyOnExplicitStartAndMissingKeyKeepsLocalAudio() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        f.credentials.key = nil
        #expect(f.credentials.reads.isEmpty)
        #expect(await f.start())
        #expect(f.credentials.reads == [f.configuration] && f.service.connections.isEmpty)
        #expect(f.live.cloudFailureReason == .credentials && f.recordings.isRecording)
        try f.recorder.capture(frames: 24_000)
        await f.live.stop()
        #expect(f.recordings.selectedRecording?.duration == 1)
        #expect(ranges(f.state.document.source.missingIntervals) == [0..<24_000])
        #expect(ranges(f.state.document.translation.missingIntervals) == ranges(f.state.document.source.missingIntervals))
    }

    @Test func reconnectKeepsResultAndTargetAndUploadsCurrentAudioWithoutOfflineBacklog() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let snapshot = try #require(f.live.snapshot)
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        f.service.emit(f.text(.source, "before", id: "same"))
        try await f.settle { f.state.document.source.text == "before" }
        f.live.cancelCloud()
        try f.recorder.capture(frames: 24_000)
        f.service.holdConfiguration = true
        let reconnect = Task { await f.live.reconnect() }
        try await f.settle { f.service.connections.count == 2 }
        try f.recorder.capture(frames: 12_000)
        f.service.emit(.configured)
        await reconnect.value
        f.service.emitOld(f.text(.source, "old", id: "old"))
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 2 }
        #expect(f.service.chunks.map(\.recordingStartFrame) == [0, 48_000])
        f.service.emit(f.text(.source, " after", id: "same"))
        f.service.emit(f.text(.translation, "译文", id: "target"))
        try await f.settle { f.state.document.source.text == "before after" }
        #expect(f.live.snapshot == snapshot && f.credentials.reads == [f.configuration, f.configuration])
        #expect(f.service.connections == [f.configuration, f.configuration])
        #expect(f.state.document.alignment.last?.connectionStartFrame == 48_000)
        await f.live.stop()
        #expect(try f.results.load(snapshot.recordingID).count == 1)
        #expect(ranges(f.state.document.source.missingIntervals) == [0..<60_000])
    }

    @Test func pauseKeepsTheRecordingAndResumeAutomaticallyReconnectsTheSameTarget() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        f.state.reviewEarlierText()
        await f.live.pause()
        #expect(f.recordings.isPaused && !f.state.followsLatest)
        let count = f.service.chunks.count
        try f.recorder.capture(frames: 12_000)
        #expect(f.service.chunks.count == count && f.service.finishes == 1)
        f.recordings.selectSource(.system)
        await f.live.resume()
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 2 }
        f.state.returnToLatest()
        await f.live.stop()
        #expect(f.recorder.starts == 1 && f.service.connections == [f.configuration, f.configuration])
        #expect(f.credentials.reads == [f.configuration, f.configuration])
        #expect(f.service.finishes == 2 && f.recordings.selectedRecording?.duration == 1)
        #expect(f.live.snapshot?.source == .microphone && f.state.followsLatest)
    }

    @Test func pauseHasAShortFixedTailBudgetAndKeepsArrivingTextWithoutEndingTheResult() async throws {
        let f = BilingualSessionFixture(timeout: 3); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        let began = ContinuousClock.now
        let pause = Task { await f.live.pause() }
        try await f.settle { f.service.finishes == 1 }
        f.service.emit(f.text(.source, "last words", id: "tail-source"))
        f.service.emit(f.text(.translation, "最后一句", id: "tail-translation"))
        await pause.value
        #expect(began.duration(to: .now) < .seconds(2))
        #expect(f.recordings.isPaused && f.live.isActive && !f.live.isPausing)
        #expect(f.live.cloudState == .idle && !f.live.canReconnect)
        #expect(!f.state.document.isFinished && f.state.document.source.text == "last words")
        #expect(f.state.document.translation.text == "最后一句")
        f.live.cancelCloud()
        await f.live.stop()
        #expect(f.recordings.selectedRecording?.duration == 0.5)
    }

    @Test func cancellingAPauseWaitPromptlyReleasesCloudAndKeepsLocalAudio() async throws {
        let f = BilingualSessionFixture(timeout: 3); defer { f.service.releaseAppend(); f.remove() }
        f.service.holdAppend = true
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.appendHeld }
        let pause = Task { await f.live.pause() }
        try await f.settle { f.recordings.isPaused && f.live.isPausing }
        let began = ContinuousClock.now
        pause.cancel()
        await pause.value
        #expect(began.duration(to: .now) < .milliseconds(250))
        #expect(f.recordings.isPaused && !f.live.isPausing)
        #expect(f.live.cloudFailureReason == .cancelled)
        f.service.releaseAppend()
        await f.live.stop()
        #expect(f.recordings.selectedRecording?.duration == 0.5)
    }

    @Test func stalledSetupBoundsBacklogAndLeavesRecordingRunning() async throws {
        let f = BilingualSessionFixture(timeout: 0.2); defer { f.remove() }
        f.service.holdConfiguration = true
        let start = Task { await f.start() }
        try await f.settle { f.service.connections.count == 1 }
        for _ in 0..<31 { try f.recorder.capture(frames: 24_000) }
        #expect(await start.value)
        #expect(f.live.cloudFailureReason == .audioBacklog && f.recordings.isRecording)
        #expect(f.service.chunks.isEmpty)
        await f.live.stop()
        #expect(f.recordings.selectedRecording?.duration == 31)
        #expect(f.state.document.translation.missingIntervals.last?.endFrame == 744_000)
    }

    @Test func uncooperativeUploadCannotBlockStopOrOverwriteAfterRetry() async throws {
        let f = BilingualSessionFixture(); defer { f.service.releaseAppend(); f.remove() }
        f.service.holdAppend = true
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.appendHeld }
        f.service.emit(f.text(.translation, "保留", id: "before"))
        try await f.settle { f.state.document.translation.text == "保留" }
        let began = Date()
        await f.live.stop()
        #expect(Date().timeIntervalSince(began) < 0.5 && !f.live.isActive)
        #expect(f.live.cloudFailureReason == .uploadTimeout && f.service.finishes == 0)
        f.service.releaseAppend()
        f.service.emitOld(f.text(.translation, "late", id: "late"))
        await Task.yield()
        #expect(f.state.document.translation.text == "保留" && f.service.finishes == 0)
    }

    @Test func uncooperativeConnectTimesOutAndItsLateReturnCannotCloseNewConnection() async throws {
        let f = BilingualSessionFixture(); defer { f.service.releaseConnect(); f.remove() }
        f.service.holdConnect = true
        #expect(await f.start())
        #expect(f.live.cloudFailureReason == .responseTimeout && f.recordings.isRecording)
        f.service.holdConnect = false
        await f.live.reconnect()
        #expect(f.live.cloudState == .connected)
        let closes = f.service.closes
        f.service.releaseConnect()
        await Task.yield()
        #expect(f.live.cloudState == .connected && f.service.closes == closes)
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        await f.live.stop()
    }

    @Test func finalDeltasDrainAndOverlappingStopsPublishOneResult() async throws {
        let f = BilingualSessionFixture(timeout: 0.06); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        let first = Task { await f.live.stop() }
        try await f.settle { f.service.finishes == 1 }
        let second = Task { await f.live.stop() }
        try await Task.sleep(for: .milliseconds(35))
        f.service.emit(f.text(.source, "tail", id: "s"))
        try await Task.sleep(for: .milliseconds(35))
        f.service.emit(f.text(.translation, "尾段", id: "t"))
        await first.value; await second.value
        #expect(f.state.document.source.text == "tail" && f.state.document.translation.text == "尾段")
        #expect(f.service.finishes == 1)
        #expect(try f.results.load(f.live.snapshot!.recordingID).count == 1)
        #expect(!f.state.document.isComplete)
    }

    @Test func continuousResponsesCannotExtendStopBeyondItsHardCap() async throws {
        let f = BilingualSessionFixture(timeout: 0.05); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        let responses = Task { @MainActor in
            for index in 0..<100 {
                try? await Task.sleep(for: .milliseconds(10))
                guard f.live.isActive else { return }
                f.service.emit(f.text(.source, "word ", id: "s\(index)"))
            }
        }
        let began = Date()
        await f.live.stop()
        responses.cancel(); await responses.value
        #expect(Date().timeIntervalSince(began) < 0.5)
        #expect(!f.state.document.source.text.isEmpty && f.state.document.isFinished)
        #expect(f.state.document.completedChannels.isEmpty)
        #expect(ranges(f.state.document.translation.missingIntervals) == [0..<12_000])
    }

    @Test func goAwayAndPausedReconnectKeepCapturePausedAndRejectOldRecordingFailure() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let oldFailure = try #require(f.recorder.onLiveAudioFailure)
        try f.recorder.capture(frames: 12_000)
        try await f.settle { f.service.chunks.count == 1 }
        f.service.emit(.goAway(timeLeft: 10))
        try await f.settle { f.live.canReconnect }
        await f.live.pause()
        await f.live.reconnect()
        #expect(f.recordings.isPaused && f.recorder.starts == 1)
        try f.recorder.capture(frames: 12_000)
        #expect(f.service.chunks.count == 1)
        await f.live.stop()
        #expect(await f.start())
        oldFailure(AudioProcessingError.processing)
        await Task.yield()
        #expect(f.live.cloudState == .connected && f.recordings.isRecording)
        await f.live.stop()
    }

    @Test func failedResultAndCheckpointWritesRetainIdentityAndEditedRetry() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let id = try #require(f.live.snapshot?.recordingID)
        let draftPath = f.path(id, "bilingual-draft.json")
        try FileManager.default.removeItem(at: draftPath)
        try FileManager.default.createDirectory(at: draftPath, withIntermediateDirectories: false)
        try f.recorder.capture(frames: 12_000)
        f.live.checkpoint()
        #expect(f.live.checkpointNeedsSaveRetry && f.recordings.isRecording)
        try FileManager.default.removeItem(at: draftPath)
        f.live.checkpoint()
        #expect(!f.live.checkpointNeedsSaveRetry)
        let resultPath = f.path(id, "bilingual-results.json")
        try FileManager.default.createDirectory(at: resultPath, withIntermediateDirectories: false)
        await f.live.stop()
        let resultID = f.state.result?.id
        #expect(f.live.needsSaveRetry)
        #expect(try f.drafts.load(id) != nil)
        f.state.editPending("用户修改", channel: .translation)
        #expect(!(await f.start()))
        try FileManager.default.removeItem(at: resultPath)
        f.live.retrySave()
        let saved = try #require(f.results.load(id).first)
        #expect(!f.live.needsSaveRetry && saved.id == resultID && saved.document.translation.text == "用户修改")
        #expect(try f.drafts.load(id) == nil && f.credentials.reads.count == 1)
    }

    @Test func checkpointRecoveryAddsUncheckpointedAudioWithoutKeyOrService() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        f.service.emit(f.text(.source, "received", id: "s"))
        try await f.settle { f.state.document.source.text == "received" }
        f.live.checkpoint()
        let checkpoint = try #require(try f.drafts.load(f.live.snapshot!.recordingID))
        try f.recorder.capture(frames: 12_000)
        let recoveredSession = RecordingSession(store: f.store, recorder: BilingualSessionRecorder(), inspectAudioDuration: { _ in 1 })
        #expect(f.drafts.recover(recordings: recoveredSession, results: f.results).isEmpty)
        let recovered = try #require(f.results.load(checkpoint.result.recordingID).first)
        #expect(recovered.id == checkpoint.result.id && recovered.document.source.text == "received")
        #expect(recovered.document.source.missingIntervals.last?.endFrame == 24_000)
        #expect(ranges(recovered.document.translation.missingIntervals) == ranges(recovered.document.source.missingIntervals))
        #expect(f.credentials.reads.count == 1 && f.service.connections.count == 1)
        await f.live.stop()
    }

    @Test func conversionFailureClosesCloudButDurationStillCoversLocalTail() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let failure = try #require(f.recorder.onLiveAudioFailure)
        failure(AudioProcessingError.processing)
        try await f.settle { f.live.cloudFailureReason == .captureConversion }
        f.recorder.suppressLiveAudio = true
        try f.recorder.capture(frames: 24_000)
        #expect(!f.live.canReconnect && f.recordings.isRecording)
        await f.live.stop()
        #expect(f.state.document.source.missingIntervals.last?.endFrame == 24_000)
        #expect(f.state.document.translation.missingIntervals.last?.endFrame == 24_000)
    }

    @Test func localCaptureStopWithMetadataFailureStillFinalizesCloud() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let id = try #require(f.live.snapshot?.recordingID)
        try f.recorder.capture(frames: 12_000)
        let metadata = f.path(id, "recording.json")
        let backup = try Data(contentsOf: metadata)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        f.recorder.onFailure?(AudioProcessingError.processing)
        try await f.settle { !f.live.isActive }
        #expect(f.recordings.needsSaveRetry && !f.live.needsSaveRetry)
        #expect(try f.results.load(id).count == 1)
        #expect(f.state.document.isFinished && f.service.closes > 0)
        try FileManager.default.removeItem(at: metadata)
        try backup.write(to: metadata)
        f.recordings.stop(); f.live.retrySave()
        #expect(!f.recordings.needsSaveRetry && !f.live.needsSaveRetry)
        #expect(f.state.document.source.missingIntervals.last?.endFrame == 12_000)
    }

    @Test func fractionalOriginalSampleDurationRecoversStoppedDraftWithoutFrameMismatch() async throws {
        let f = BilingualSessionFixture(); defer { f.remove() }
        #expect(await f.start())
        let id = try #require(f.live.snapshot?.recordingID)
        try f.recorder.capture(frames: 24_000)
        // An odd 48 kHz source frame count is not an integral 24 kHz boundary.
        f.recorder.currentTime = 48_001.0 / 48_000
        let resultPath = f.path(id, "bilingual-results.json")
        try FileManager.default.createDirectory(at: resultPath, withIntermediateDirectories: false)
        await f.live.stop()
        #expect(f.live.needsSaveRetry)
        try FileManager.default.removeItem(at: resultPath)
        let restarted = RecordingSession(store: f.store, recorder: BilingualSessionRecorder())
        #expect(f.drafts.recover(recordings: restarted, results: f.results).isEmpty)
        let recovered = try #require(f.results.load(id).first)
        #expect(recovered.document.source.missingIntervals.last?.endFrame == 24_001)
        #expect(recovered.document.translation.missingIntervals.last?.endFrame == 24_001)
        #expect(try f.drafts.load(id) == nil)
    }

    @Test func stoppingNextStartBeforePermissionReturnsDoesNotCheckpointPreviousResult() async throws {
        let f = BilingualSessionFixture(); defer { f.recorder.releasePermission(); f.remove() }
        #expect(await f.start())
        try f.recorder.capture(frames: 12_000)
        await f.live.stop()
        let previous = try #require(f.state.result)
        let saved = try f.results.load(previous.recordingID)
        f.recorder.holdPermission = true
        let starting = Task { await f.start() }
        try await f.settle { f.recorder.permissionHeld }
        await f.live.stop()
        f.recorder.releasePermission()
        #expect(!(await starting.value))
        #expect(!f.live.checkpointNeedsSaveRetry && f.live.snapshot == nil)
        #expect(f.state.result == previous)
        #expect(try f.results.load(previous.recordingID) == saved)
        #expect(try f.drafts.load(previous.recordingID) == nil)
        f.recorder.holdPermission = false
        #expect(await f.start())
        await f.live.stop()
    }
}

@MainActor private final class BilingualSessionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-session-\(UUID())")
    let configuration = AudioServiceConfiguration(provider: .gemini)
    let recorder = BilingualSessionRecorder()
    let credentials = BilingualSessionCredentials()
    let service = BilingualSessionService()
    let store: RecordingStore
    let recordings: RecordingSession
    let results: BilingualResultStore
    let drafts: BilingualDraftStore
    let state: BilingualSessionState
    let live: LiveBilingualSession
    init(allowStart: Bool = true, timeout: TimeInterval = 0.1) {
        store = .init(root: root)
        recordings = .init(store: store, recorder: recorder)
        results = .init(recordings: store); drafts = .init(recordings: store)
        let results = results
        state = .init { try results.publish($0) }
        live = .init(recordings: recordings, credentials: credentials, service: service, presentation: state,
                     drafts: drafts, responseTimeout: timeout,
                     capabilityAllowsStart: { allowStart && $0 == AudioServiceConfiguration(provider: .gemini) })
    }
    func start() async -> Bool { await live.start(configuration: configuration, direction: .englishToChinese) }
    func text(_ channel: BilingualChannel, _ value: String, id: String) -> LiveBilingualTransportEvent {
        .text(channel: channel, eventID: id, delta: value, startOffset: nil, endOffset: nil, finished: nil)
    }
    func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition(), "state=\(live.cloudState) reason=\(String(describing: live.cloudFailureReason))")
    }
    func path(_ id: UUID, _ name: String) -> URL { store.audioURL(for: id).deletingLastPathComponent().appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class BilingualSessionCredentials: AudioCredentials {
    var key: String? = "controlled-only"
    var reads: [AudioServiceConfiguration] = []
    var holdRead = false
    var cooperativeHold = false, cooperativeWaiting = false
    private var pendingRead: CheckedContinuation<Void, Never>?
    var readHeld: Bool { pendingRead != nil }
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String? {
        reads.append(configuration)
        if cooperativeHold {
            cooperativeWaiting = true
            defer { cooperativeWaiting = false }
            try await Task.sleep(for: .seconds(30))
        }
        if holdRead { await withCheckedContinuation { pendingRead = $0 } }
        return key
    }
    func releaseRead() { pendingRead?.resume(); pendingRead = nil }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { if holdRead { throw AudioProcessingError.credential }; reads.append(configuration); return key }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { key = value }
    func delete(for configuration: AudioServiceConfiguration) throws { key = nil }
}

@MainActor private final class BilingualSessionService: LiveBilingualTranslating {
    var connections: [AudioServiceConfiguration] = []
    var chunks: [LiveAudioChunk] = []
    var finishes = 0, closes = 0
    var holdConfiguration = false, holdAppend = false, holdConnect = false
    var appendHeld: Bool { appendContinuation != nil }
    private var appendContinuation: CheckedContinuation<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var sink: AsyncThrowingStream<LiveBilingualTransportEvent, Error>.Continuation?
    private var oldSinks: [AsyncThrowingStream<LiveBilingualTransportEvent, Error>.Continuation] = []
    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                 apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> {
        connections.append(configuration)
        let pair = AsyncThrowingStream<LiveBilingualTransportEvent, Error>.makeStream()
        sink = pair.continuation; oldSinks.append(pair.continuation)
        if !holdConfiguration { pair.continuation.yield(.configured) }
        if holdConnect { await withCheckedContinuation { connectContinuation = $0 } }
        return pair.stream
    }
    func append(_ chunk: LiveAudioChunk) async throws {
        chunks.append(chunk)
        if holdAppend { await withCheckedContinuation { appendContinuation = $0 } }
    }
    func finishInput() async throws { finishes += 1 }
    func close() { closes += 1; sink?.finish(); sink = nil }
    func emit(_ event: LiveBilingualTransportEvent) { sink?.yield(event) }
    func emitOld(_ event: LiveBilingualTransportEvent) { oldSinks.first?.yield(event) }
    func releaseAppend() { appendContinuation?.resume(); appendContinuation = nil }
    func releaseConnect() { connectContinuation?.resume(); connectContinuation = nil }
}

@MainActor private final class BilingualSessionRecorder: AudioRecording {
    var currentTime: TimeInterval = 0
    var power: Float { -20 }
    var onFailure: ((Error) -> Void)?
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?
    var onLiveAudioFailure: (@Sendable (Error) -> Void)?
    var starts = 0, suppressLiveAudio = false
    var holdPermission = false
    var permissionHeld: Bool { permissionContinuation != nil }
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private var capturing = false
    private var frame: Int64 = 0
    private var file: URL?
    func requestPermission(for source: AudioSource) async throws {
        if holdPermission { await withCheckedContinuation { permissionContinuation = $0 } }
    }
    func releasePermission() { permissionContinuation?.resume(); permissionContinuation = nil }
    func start(at url: URL, source: AudioSource) async throws {
        try Data([0]).write(to: url); starts += 1; file = url; frame = 0; currentTime = 0; capturing = true
    }
    func pause() async throws { capturing = false }
    func resume() async throws { capturing = true }
    func stop() -> TimeInterval { capturing = false; return currentTime }
    func capture(frames: Int64) throws {
        guard capturing, let file else { return }
        let bytes = Data(repeating: 1, count: Int(frames) * 2)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        if !suppressLiveAudio { onLiveAudio?(try .init(pcm16: bytes, recordingStartFrame: frame)) }
        frame += frames; currentTime = Double(frame) / LiveAudioChunk.sampleRate
    }
}

private func ranges(_ intervals: [MissingInterval]) -> [Range<Int64>] {
    intervals.map { $0.startFrame..<$0.endFrame }
}
