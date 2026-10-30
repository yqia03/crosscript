import Combine
import Foundation

public struct LiveBilingualSnapshot: Equatable, Sendable {
    public let recordingID: UUID
    public let resultID: UUID
    public let createdAt: Date
    public let source: AudioSource
    public let configuration: AudioServiceConfiguration
    public let direction: TextTranslationDirection
}

/// Owns one capture route and one selected live translation target. Cloud
/// failure never stops local recording, and transport observations never grant
/// an original-media confirmation that the provider has not supplied.
@MainActor public final class LiveBilingualSession: ObservableObject {
    @Published public private(set) var isActive = false
    @Published public private(set) var isAwaitingCredentials = false
    @Published public private(set) var cloudState: LiveCloudState = .idle
    @Published public private(set) var snapshot: LiveBilingualSnapshot?
    @Published public private(set) var cloudError: AudioProcessingError?
    @Published public private(set) var cloudFailureReason: LiveCloudFailureReason?
    @Published public private(set) var checkpointNeedsSaveRetry = false
    @Published public private(set) var latestUsage: LiveBilingualUsage?
    @Published public private(set) var interactionStatus: LiveBilingualInteractionStatus?
    public let presentation: BilingualSessionState
    public var needsSaveRetry: Bool { presentation.needsSaveRetry }
    public var canReconnect: Bool { isActive && cloudState == .failed && !isStopping && !isPausing && captureHealthy }

    private let recordings: RecordingSession
    private let credentials: any AudioCredentials
    private let service: any LiveBilingualTranslating
    private let drafts: BilingualDraftStore?
    private let responseTimeout: TimeInterval
    private let capabilityAllowsStart: (AudioServiceConfiguration) -> Bool
    private var continuity = BilingualAudioContinuity()
    private var route: LiveAudioRoute?
    private var generation = UUID()
    private var recordingGeneration = UUID()
    private var acceptsEvents = false
    private var captureHealthy = true
    private var isStopping = false
    @Published public private(set) var isPausing = false
    private var uploadFinished = true
    private var uploadedEnd: Int64 = 0
    private var finishedInputEnd: Int64 = 0
    private var finishRequests = 0
    private var finishedRequests = 0
    private var responseProgress = 0
    private var credentialTask: Task<String?, Error>?
    private var connectionTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var observations: [AnyCancellable] = []

    public init(recordings: RecordingSession, credentials: any AudioCredentials,
                service: any LiveBilingualTranslating, presentation: BilingualSessionState,
                drafts: BilingualDraftStore? = nil, responseTimeout: TimeInterval = 10,
                capabilityAllowsStart: @escaping (AudioServiceConfiguration) -> Bool = {
                    LiveBilingualCapability.forConfiguration($0).canStart
                }) {
        self.recordings = recordings; self.credentials = credentials; self.service = service
        self.presentation = presentation; self.drafts = drafts
        self.responseTimeout = responseTimeout.isFinite ? max(0.01, responseTimeout) : 10
        self.capabilityAllowsStart = capabilityAllowsStart
        // Transcript readers observe presentation directly. Relaying every text
        // delta through the session invalidates the whole app scene and controls.
        observations.append(Publishers.CombineLatest3(
            presentation.$result.map { $0?.id }.removeDuplicates(),
            presentation.$cloudState.removeDuplicates(),
            presentation.$needsSaveRetry.removeDuplicates()
        ).dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        })
        observations.append(recordings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.snapshot != nil, !self.isStopping,
                      !self.recordings.isBusy,
                      !self.recordings.hasActiveRecording || self.recordings.needsSaveRetry else { return }
                await self.stop()
            }
        })
    }

    @discardableResult public func start(configuration: AudioServiceConfiguration,
                                         direction: TextTranslationDirection) async -> Bool {
        guard !isActive, !isStopping, !checkpointNeedsSaveRetry, presentation.canReplaceResult,
              recordings.canCreateProject, let configuration = try? configuration.validated(),
              capabilityAllowsStart(configuration) else { return false }
        let token = UUID(); generation = token; recordingGeneration = token
        snapshot = nil; continuity = .init(); cloudError = nil; cloudFailureReason = nil
        latestUsage = nil; interactionStatus = nil; responseProgress = 0
        isActive = true; cloudState = .connecting; acceptsEvents = true; captureHealthy = true
        uploadFinished = true; uploadedEnd = 0; finishedInputEnd = 0; finishRequests = 0; finishedRequests = 0
        let pair = AsyncStream<LiveAudioInput>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        let route = LiveAudioRoute { [weak self] connection in
            Task { @MainActor [weak self] in self?.fail(.processing, token: connection, reason: .audioBacklog) }
        }
        self.route = route
        route.attach(pair.continuation, token: token)
        _ = continuity.attachCurrent(generation: token)
        guard recordings.configureLiveAudio({ chunk in route.receive(chunk) }, onFailure: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recordingGeneration == token, self.isActive else { return }
                self.captureHealthy = false
                self.fail(.processing, token: self.generation, reason: .captureConversion)
            }
        }) else { abandonStart(); return false }
        let source = recordings.selectedSource
        await recordings.start(workflow: .liveTranslation)
        guard generation == token, isActive, !isStopping, let recording = recordings.activeRecording,
              presentation.beginObservation(recordingID: recording.id, configuration: configuration,
                  direction: direction, generation: token) != nil, let result = presentation.result else {
            if generation == token { abandonStart() }
            return false
        }
        snapshot = .init(recordingID: recording.id, resultID: result.id, createdAt: result.createdAt,
                         source: source, configuration: configuration, direction: direction)
        if !acceptsEvents { presentation.receive(.failed, generation: token) }
        if isActive { checkpoint() }
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.recordingGeneration == token, self.isActive else { return }
                self.checkpoint()
            }
        }
        if acceptsEvents { await connect(token: token, pair: pair, reconnecting: false) }
        return true
    }

    public func reconnect() async {
        guard canReconnect else { return }
        let token = UUID(); generation = token
        acceptsEvents = true; cloudState = .reconnecting; cloudError = nil; cloudFailureReason = nil
        uploadFinished = true; finishRequests = 0; finishedRequests = 0; interactionStatus = nil
        presentation.beginReconnection(generation: token)
        let pair = AsyncStream<LiveAudioInput>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        await connect(token: token, pair: pair, reconnecting: true)
    }

    private func connect(token: UUID,
                         pair: (stream: AsyncStream<LiveAudioInput>, continuation: AsyncStream<LiveAudioInput>.Continuation),
                         reconnecting: Bool) async {
        guard let snapshot else { return }
        defer { if generation == token { isAwaitingCredentials = false; credentialTask = nil } }
        do {
            isAwaitingCredentials = true
            let lookup = Task { [credentials] in try await credentials.readAsync(for: snapshot.configuration) }
            credentialTask = lookup
            let key = try await withTaskCancellationHandler {
                try await lookup.value
            } onCancel: { lookup.cancel() }
            guard generation == token, acceptsEvents, !isStopping, !Task.isCancelled else { return }
            isAwaitingCredentials = false
            guard let key, !key.isEmpty else { throw AudioProcessingError.credential }
            connectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let stream = try await self.service.connect(configuration: snapshot.configuration,
                        direction: snapshot.direction, apiKey: key)
                    guard self.generation == token, self.acceptsEvents, !self.isStopping else { return }
                    self.eventsTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            for try await event in stream {
                                guard self.generation == token, self.acceptsEvents else { return }
                                self.receive(event, token: token)
                            }
                            self.fail(.unavailable, token: token, reason: .connection)
                        } catch { self.fail(.unavailable, token: token, reason: .connection) }
                    }
                } catch { self.fail(error as? AudioProcessingError ?? .unavailable, token: token, reason: .connection) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(responseTimeout))
            while generation == token, acceptsEvents, !isStopping,
                  cloudState == .connecting || cloudState == .reconnecting, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard generation == token, acceptsEvents, !isStopping else { return }
            guard cloudState == .connected else { fail(.unavailable, token: token, reason: .responseTimeout); return }
            if reconnecting {
                let begin = route?.attach(pair.continuation, token: token) ?? continuity.capturedEndFrame
                try continuity.captureThroughFrame(begin)
                _ = continuity.attachCurrent(generation: token)
                presentation.setConnectionStartFrame(begin, generation: token)
                uploadedEnd = begin; finishedInputEnd = begin
                checkpoint()
            }
            uploadFinished = false
            uploadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.generation == token { self.uploadFinished = true } }
                do {
                    for await value in pair.stream {
                        guard self.generation == token, self.acceptsEvents else { return }
                        switch value {
                        case .audio(let chunk):
                            guard chunk.recordingStartFrame == self.uploadedEnd else { throw LiveAudioClockError.invalidClock }
                            try await self.service.append(chunk)
                            guard self.generation == token, self.acceptsEvents else { return }
                            self.route?.acknowledge(chunk.frameCount, token: token)
                            self.uploadedEnd = chunk.recordingEndFrame
                        case .commit:
                            try await self.finishInput(token: token, forPause: true)
                            guard self.generation == token, self.acceptsEvents else { return }
                            self.finishedRequests += 1
                        }
                    }
                    try await self.finishInput(token: token)
                } catch { self.fail(.unavailable, token: token, reason: .connection) }
            }
        } catch {
            fail(error as? AudioProcessingError ?? .unavailable, token: token,
                 reason: error is CancellationError ? .cancelled : error as? AudioProcessingError == .credential ? .credentials : .connection)
        }
    }

    private func receive(_ event: LiveBilingualTransportEvent, token: UUID) {
        switch event {
        case .configured:
            if cloudState == .connecting || cloudState == .reconnecting {
                cloudState = .connected; presentation.receive(.configured, generation: token)
            }
        case let .text(channel, eventID, delta, _, _, _):
            // Provider offsets describe its channel's audio, not a confirmed
            // position in our original recording. Preserve text without anchors.
            presentation.receive(.text(channel: channel, eventID: channel.rawValue + ":" + eventID,
                delta: delta, elapsedMilliseconds: nil), generation: token)
            if !delta.isEmpty { responseProgress += 1 }
        case .interactionStatus(let status):
            if interactionStatus != status { interactionStatus = status }
        case .usage(let usage):
            if latestUsage != usage { latestUsage = usage }
        case .goAway: fail(.unavailable, token: token, reason: .connection)
        case .closed: fail(.unavailable, token: token, reason: .connection)
        case .interrupted: fail(.interrupted, token: token, reason: .protocolFailure)
        case .turnComplete, .generationComplete, .audioDiscarded: break
        }
    }

    public func pause() async {
        guard isActive, !isStopping, !isPausing else { return }
        isPausing = true; defer { isPausing = false }
        await recordings.pause()
        guard recordings.isPaused, !isStopping else { return }
        if acceptsEvents {
            finishRequests += 1; let expected = finishRequests
            route?.flush()
            // A pause is a short interruption, not a full session stop. Upload
            // and response drain share one cap, so trailing deltas cannot keep
            // the resume button disabled for another response timeout.
            let deadline = ContinuousClock.now.advanced(by: .seconds(min(responseTimeout, 1.5)))
            while acceptsEvents, !isStopping, !Task.isCancelled,
                  finishedRequests < expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if !isStopping, acceptsEvents, finishedRequests < expected {
                fail(Task.isCancelled ? .interrupted : .unavailable, token: generation,
                     reason: Task.isCancelled ? .cancelled : .uploadTimeout)
            }
            if !isStopping {
                await drain(token: generation, until: deadline)
                if !isStopping { suspendCloud() }
            }
        }
        if isActive { checkpoint() }
    }
    public func resume() async {
        guard isActive, !isStopping, !isPausing, recordings.isPaused else { return }
        guard captureHealthy else { await recordings.resume(); return }
        suspendCloud()
        let token = UUID(); generation = token
        acceptsEvents = true; cloudState = .reconnecting; cloudError = nil; cloudFailureReason = nil
        uploadFinished = true; finishRequests = 0; finishedRequests = 0; interactionStatus = nil
        presentation.beginReconnection(generation: token)
        let pair = AsyncStream<LiveAudioInput>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        // Unlike a reconnect during an outage, resume starts at an exact paused
        // boundary. Attach before capture resumes so setup cannot lose its first words.
        let begin = route?.attach(pair.continuation, token: token) ?? continuity.capturedEndFrame
        try? continuity.captureThroughFrame(begin)
        _ = continuity.attachCurrent(generation: token)
        presentation.setConnectionStartFrame(begin, generation: token)
        uploadedEnd = begin; finishedInputEnd = begin
        await recordings.resume()
        guard generation == token, isActive, !isStopping, !isPausing else { return }
        guard recordings.isRecording else { suspendCloud(); return }
        await connect(token: token, pair: pair, reconnecting: false)
    }
    public func cancelCloud() { fail(.interrupted, token: generation, reason: .cancelled) }

    public func stop() async {
        if isStopping { await withCheckedContinuation { stopWaiters.append($0) }; return }
        guard isActive else { return }
        // There is no transport to drain while Keychain is still waiting.
        // Invalidate cloud acceptance before a late authorization can return.
        if isAwaitingCredentials { fail(.interrupted, token: generation, reason: .cancelled) }
        isStopping = true
        isAwaitingCredentials = false
        defer {
            isStopping = false
            let waiters = stopWaiters; stopWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let token = generation
        recordings.stop(); route?.detach()
        if cloudState != .failed { cloudState = .finishing; presentation.beginFinishing() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(responseTimeout))
        while acceptsEvents, !uploadFinished, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if acceptsEvents, !uploadFinished { fail(.unavailable, token: token, reason: .uploadTimeout) }
        await drain(token: token)
        advanceContinuity(includeRecordedDuration: true)
        continuity.disconnect(generation: token)
        synchronizeMissing()
        acceptsEvents = false
        // A checkpoint precedes publication so a crash or failed write retains
        // the same result identity and every unconfirmed channel range.
        if let snapshot, var result = presentation.result, result.id == snapshot.resultID {
            result.document.finish(completedChannels: [])
            saveCheckpoint(result)
        }
        checkpointTask?.cancel(); checkpointTask = nil
        credentialTask?.cancel(); credentialTask = nil
        connectionTask?.cancel(); eventsTask?.cancel(); uploadTask?.cancel()
        service.close()
        isActive = false
        if let snapshot, presentation.result?.id == snapshot.resultID { presentation.finish(confirmedChannels: []) }
        if cloudState != .failed { cloudState = .completed }
        _ = recordings.configureLiveAudio(nil)
        removePublishedCheckpoint()
    }

    private func finishInput(token: UUID, forPause: Bool = false) async throws {
        guard generation == token, acceptsEvents, uploadedEnd > finishedInputEnd else { return }
        let end = uploadedEnd
        if forPause { try await service.pauseInput() }
        else { try await service.finishInput() }
        guard generation == token, acceptsEvents else { return }
        finishedInputEnd = end
    }
    private func drain(token: UUID, until deadline: ContinuousClock.Instant? = nil) async {
        let clock = ContinuousClock()
        let hardDeadline = deadline ?? clock.now.advanced(by: .seconds(responseTimeout * 3))
        var idleDeadline = clock.now.advanced(by: .seconds(responseTimeout))
        var progress = responseProgress
        while generation == token, acceptsEvents, !Task.isCancelled {
            let instant = clock.now
            if responseProgress != progress {
                progress = responseProgress; idleDeadline = instant.advanced(by: .seconds(responseTimeout))
            }
            guard instant < idleDeadline, instant < hardDeadline else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    private func suspendCloud() {
        guard acceptsEvents else { return }
        acceptsEvents = false; isAwaitingCredentials = false
        advanceContinuity()
        continuity.disconnect(generation: generation)
        route?.detach()
        synchronizeMissing()
        presentation.suspendCloud(generation: generation)
        cloudState = .idle
        credentialTask?.cancel(); credentialTask = nil
        connectionTask?.cancel(); eventsTask?.cancel(); uploadTask?.cancel()
        service.close()
    }
    private func fail(_ error: AudioProcessingError, token: UUID, reason: LiveCloudFailureReason) {
        guard generation == token, isActive, acceptsEvents else { return }
        isAwaitingCredentials = false
        cloudError = error; cloudFailureReason = reason; cloudState = .failed; acceptsEvents = false
        advanceContinuity(includeRecordedDuration: !captureHealthy)
        continuity.disconnect(generation: token)
        route?.detach()
        presentation.receive(.failed, generation: token)
        synchronizeMissing(); checkpoint()
        credentialTask?.cancel(); credentialTask = nil
        connectionTask?.cancel(); eventsTask?.cancel(); uploadTask?.cancel()
        service.close()
    }
    private func advanceContinuity(includeRecordedDuration: Bool = false) {
        var end = max(continuity.capturedEndFrame, route?.capturedEndFrame ?? 0)
        if includeRecordedDuration, let snapshot {
            let saved = recordings.recordings.first { $0.id == snapshot.recordingID }?.duration ?? 0
            let duration = recordings.hasActiveRecording ? max(saved, recordings.elapsed) : saved
            if let frames = try? BilingualAudioContinuity.recordedEndFrame(duration: duration) { end = max(end, frames) }
        }
        try? continuity.captureThroughFrame(end)
    }
    private func synchronizeMissing() {
        for channel in BilingualChannel.allCases { presentation.markMissing(continuity.missing(channel), channel: channel) }
    }
    public func checkpoint() {
        guard isActive || needsSaveRetry,
              let snapshot, let result = presentation.result, result.id == snapshot.resultID else { return }
        advanceContinuity(includeRecordedDuration: !captureHealthy)
        synchronizeMissing()
        if let result = presentation.result { saveCheckpoint(result) }
    }
    private func saveCheckpoint(_ result: BilingualResult) {
        guard let drafts else { return }
        do { try drafts.save(.init(result: result, continuity: continuity)); checkpointNeedsSaveRetry = false }
        catch { checkpointNeedsSaveRetry = true }
    }
    public func retrySave() {
        guard !isActive else { return }
        presentation.retrySave()
        if presentation.needsSaveRetry { checkpoint() }
        else { removePublishedCheckpoint() }
    }
    private func removePublishedCheckpoint() {
        guard !presentation.needsSaveRetry, let snapshot else { return }
        do { try drafts?.remove(snapshot.recordingID); checkpointNeedsSaveRetry = false }
        catch { checkpointNeedsSaveRetry = true }
    }
    private func abandonStart() {
        route?.detach(); acceptsEvents = false; isActive = false; cloudState = .idle
        _ = recordings.configureLiveAudio(nil)
    }
}
