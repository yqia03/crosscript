import Combine
import Foundation

@MainActor public final class RecordingSession: ObservableObject {
    @Published public private(set) var recordings: [Recording] = []
    @Published public private(set) var isImporting = false
    @Published public private(set) var activeID: UUID?
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var selectedWorkflow: RecordingWorkflow = .transcription
    @Published public private(set) var selectedSource: AudioSource = .microphone
    public let telemetry = RecordingTelemetry()
    public private(set) var elapsed: TimeInterval {
        get { telemetry.elapsed }
        set { if telemetry.elapsed != newValue { telemetry.elapsed = newValue } }
    }
    public private(set) var inputLevel: Double {
        get { telemetry.inputLevel }
        set { if telemetry.inputLevel != newValue { telemetry.inputLevel = newValue } }
    }
    @Published public private(set) var quitConfirmationRequired = false
    @Published private var errorDetails: [ErrorDetail] = []
    @Published private var phase: Phase = .idle

    private enum Phase { case idle, starting, recording, pausing, paused, resuming, saving, awaitingSave }
    private enum ErrorDetail {
        case failure(Error)
        case text(String)
        case awaitingSave

        var localizedDescription: String {
            switch self {
            case .failure(let error): return error.localizedDescription
            case .text(let text): return text
            case .awaitingSave:
                return coreMessage("录音已停止，但录音信息尚未保存。请重试保存。", "The audio has stopped, but its recording details could not be saved. Retry saving.")
            }
        }
    }
    private let store: RecordingStore
    private let recorder: any AudioRecording
    private let inspectAudioDuration: ((URL) throws -> TimeInterval)?
    private let captureActivity: (AudioSource?) -> Void
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var timer: Timer?
    private var pendingSave: Recording?
    private var captureToken: UUID?
    private var startupFailure: Error?
    private var startingRecording: Recording?
    // Startup may select recent history; an explicit new project stays empty on refresh.
    private var emptyWorkspaces: Set<RecordingWorkflow> = []
    private var workflowSelections: [RecordingWorkflow: UUID] = [:]
    @Published private var transitionInFlight = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestedInterruption: RecordingInterruptionReason?

    public var selectedRecording: Recording? { recordings.first { $0.id == selectedID } }
    public func recordings(in workflow: RecordingWorkflow) -> [Recording] { recordings.filter { $0.workflow == workflow } }
    public var activeRecording: Recording? { recordings.first { $0.id == activeID } }
    public var isRecording: Bool { phase == .recording }
    public var isPaused: Bool { phase == .paused }
    public var isBusy: Bool { transitionInFlight || phase == .saving }
    public var hasActiveRecording: Bool { activeID != nil }
    public var needsSaveRetry: Bool { pendingSave != nil }
    public var canCreateProject: Bool {
        phase == .idle && !isBusy && !hasActiveRecording && !needsSaveRetry && !isImporting
    }
    // Existing errors follow a language change without retrying the failed action.
    public var lastError: String? {
        errorDetails.isEmpty ? nil : errorDetails.map(\.localizedDescription).joined(separator: "\n")
    }

    public init(store: RecordingStore, recorder: any AudioRecording, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent }, inspectAudioDuration: ((URL) throws -> TimeInterval)? = nil, captureActivity: @escaping (AudioSource?) -> Void = { _ in }) {
        self.inspectAudioDuration = inspectAudioDuration
        self.captureActivity = captureActivity
        self.store = store
        self.recorder = recorder
        self.now = now
        self.timeZone = timeZone
        refresh()
    }

    deinit { timer?.invalidate() }

    /// Live delivery is configured only between recordings. Navigation and
    /// pauses cannot replace the capture mode or source of an active session.
    @discardableResult public func configureLiveAudio(_ receive: (@Sendable (LiveAudioChunk) -> Void)?, onFailure: (@Sendable (Error) -> Void)? = nil) -> Bool {
        guard canCreateProject else { return false }
        recorder.onLiveAudio = receive
        recorder.onLiveAudioFailure = onFailure
        return true
    }

    public func newProject() {
        guard canCreateProject else { return }
        emptyWorkspaces.insert(selectedWorkflow)
        workflowSelections[selectedWorkflow] = nil
        selectedID = nil
        elapsed = 0
        inputLevel = 0
        errorDetails = []
    }

    public func start(workflow: RecordingWorkflow = .transcription) async {
        guard phase == .idle, !isBusy, !hasActiveRecording, !needsSaveRetry, !isImporting else { return }
        transitionInFlight = true
        defer { finishTransition() }
        let source = selectedSource
        let token = UUID()
        captureToken = token
        startupFailure = nil
        requestedInterruption = nil
        recorder.onFailure = { [weak self] error in
            self?.handleRecorderFailure(error, token: token)
        }
        phase = .starting
        errorDetails = []
        do {
            try await recorder.requestPermission(for: source)
            guard captureToken == token else { phase = .idle; return }
            if let startupFailure { throw startupFailure }
        } catch {
            guard captureToken == token else { phase = .idle; return }
            captureToken = nil
            phase = .idle
            errorDetails = [.failure(error)]
            return
        }
        let startedAt = now()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // Resolve the local zone for this start; stored default names never change.
        formatter.timeZone = timeZone()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let defaultName = formatter.string(from: startedAt)
        let recording = Recording(id: UUID(), startedAt: startedAt, defaultName: defaultName, name: defaultName, duration: 0, status: .recording, source: source, workflow: workflow)
        do {
            try store.save(recording)
            startingRecording = recording
            captureActivity(source)
            try await recorder.start(at: store.audioURL(for: recording.id), source: source)
            guard captureToken == token else { settleCancelledCapture(recording); return }
            if let startupFailure { throw startupFailure }
        } catch {
            guard captureToken == token else { settleCancelledCapture(recording); return }
            captureToken = nil
            let duration = recorder.stop()
            captureActivity(nil)
            startingRecording = nil
            if store.containsAudio(for: recording.id) {
                var interrupted = recording
                interrupted.status = .interrupted
                interrupted.interruptionReason = .captureFailure
                interrupted.duration = validDuration(duration)
                elapsed = interrupted.duration
                recordings.insert(interrupted, at: 0)
                activeID = interrupted.id
                select(interrupted.id)
                finishSaving(interrupted)
            } else {
                do { try store.discardUnstarted(recording.id) }
                catch { errorDetails = [.failure(error)] }
                phase = .idle
            }
            errorDetails.insert(.failure(error), at: 0)
            return
        }
        startingRecording = nil
        recordings.insert(recording, at: 0)
        activeID = recording.id
        select(recording.id)
        elapsed = 0
        inputLevel = 0
        phase = .recording
        beginMetering()
    }

    public func pause() async {
        guard phase == .recording, !isBusy, var recording = activeRecording, let token = captureToken else { return }
        transitionInFlight = true
        defer { finishTransition() }
        phase = .pausing
        do {
            try await recorder.pause()
            guard captureToken == token else { settleCancelledCapture(recording); return }
            endMetering()
            captureActivity(nil)
            recording.duration = validDuration(recorder.currentTime)
            recording.status = .paused
            elapsed = recording.duration
            try store.save(recording)
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
            phase = .paused
        } catch {
            guard captureToken == token else { settleCancelledCapture(recording); return }
            phase = .recording
            handleRecorderFailure(error, token: token)
        }
    }

    public func resume() async {
        guard phase == .paused, !isBusy, var recording = activeRecording, let token = captureToken else { return }
        transitionInFlight = true
        defer { finishTransition() }
        phase = .resuming
        captureActivity(recording.source)
        do {
            try await recorder.resume()
            guard captureToken == token else { settleCancelledCapture(recording); return }
            recording.status = .recording
            try store.save(recording)
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
            phase = .recording
            beginMetering()
        } catch {
            guard captureToken == token else { settleCancelledCapture(recording); return }
            phase = .recording
            handleRecorderFailure(error, token: token)
        }
    }

    public func requestQuit() -> Bool {
        guard hasActiveRecording || isBusy || needsSaveRetry else { return true }
        quitConfirmationRequired = true
        return false
    }

    public func cancelQuit() { quitConfirmationRequired = false }

    public func confirmQuit() async -> Bool {
        guard quitConfirmationRequired else { return false }
        quitConfirmationRequired = false
        stop()
        if transitionInFlight {
            await withCheckedContinuation { transitionWaiters.append($0) }
        }
        return !hasActiveRecording && !isBusy && !needsSaveRetry
    }

    public func systemWillSleep() { endCapture(interruption: .systemSleep) }

    public func stop() {
        if let pendingSave { finishSaving(pendingSave); return }
        endCapture(interruption: nil)
    }

    private func endCapture(interruption: RecordingInterruptionReason?) {
        guard captureToken != nil else { return }
        requestedInterruption = interruption
        captureToken = nil
        endMetering()
        let duration = validDuration(recorder.stop())
        captureActivity(nil)
        guard var recording = activeRecording ?? startingRecording else { phase = .idle; return }
        guard store.containsAudio(for: recording.id) else { phase = .idle; return }
        recording.duration = duration
        recording.status = interruption == nil ? .saved : .interrupted
        recording.interruptionReason = interruption
        elapsed = recording.duration
        if !recordings.contains(where: { $0.id == recording.id }) {
            recordings.insert(recording, at: 0)
            activeID = recording.id
            select(recording.id)
        }
        finishSaving(recording)
    }

    private func settleCancelledCapture(_ original: Recording) {
        let duration = validDuration(recorder.stop())
        captureActivity(nil)
        startingRecording = nil
        if store.containsAudio(for: original.id) {
            var recording = recordings.first(where: { $0.id == original.id }) ?? original
            recording.duration = max(recording.duration, duration)
            recording.status = requestedInterruption == nil ? .saved : .interrupted
            recording.interruptionReason = requestedInterruption
            elapsed = recording.duration
            if !recordings.contains(where: { $0.id == recording.id }) { recordings.insert(recording, at: 0) }
            activeID = recording.id
            select(recording.id)
            finishSaving(recording)
            if requestedInterruption == .captureFailure, let startupFailure {
                errorDetails.insert(.failure(startupFailure), at: 0)
            }
        } else {
            do { try store.discardUnstarted(original.id) }
            catch { errorDetails = [.failure(error)] }
            phase = .idle
        }
    }

    private func finishTransition() {
        transitionInFlight = false
        let waiters = transitionWaiters
        transitionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    public func rename(id: UUID, name: String) {
        guard !isBusy, let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var updated = recordings[index]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? updated.defaultName : trimmed
        do {
            try store.save(updated)
            recordings[index] = updated
            if pendingSave?.id == id {
                pendingSave = updated
                finishSaving(updated)
            }
        } catch {
            errorDetails = [.failure(error)]
        }
    }

    public func select(_ id: UUID) {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        selectedWorkflow = recording.workflow
        emptyWorkspaces.remove(recording.workflow)
        workflowSelections[recording.workflow] = id
        selectedID = id
    }

    /// Each workflow remembers its own material or intentionally empty project.
    /// Navigation never changes the active capture's mode or source.
    public func activateWorkflow(_ workflow: RecordingWorkflow) {
        guard selectedWorkflow != workflow else { return }
        selectedWorkflow = workflow
        restoreWorkflowSelection()
    }

    private func restoreWorkflowSelection() {
        if emptyWorkspaces.contains(selectedWorkflow) { selectedID = nil; return }
        let remembered = workflowSelections[selectedWorkflow]
        selectedID = recordings.first { $0.id == remembered && $0.workflow == selectedWorkflow }?.id
            ?? recordings.first { $0.workflow == selectedWorkflow }?.id
        workflowSelections[selectedWorkflow] = selectedID
    }

    public func selectSource(_ source: AudioSource) {
        guard phase == .idle, !isBusy, !hasActiveRecording, !needsSaveRetry else { return }
        selectedSource = source
    }

    public func refresh() {
        guard phase == .idle, !isBusy, !needsSaveRetry else { return }
        do {
            let loaded = try store.load()
            var warnings = loaded.warnings.map(ErrorDetail.text)
            recordings = loaded.recordings.map { recording in
                guard recording.status == .recording || recording.status == .paused || recording.interruptionReason == .unexpectedTermination else { return recording }
                var interrupted = recording
                interrupted.status = .interrupted
                interrupted.interruptionReason = .unexpectedTermination
                if let inspectAudioDuration {
                    do { interrupted.duration = validDuration(try inspectAudioDuration(store.audioURL(for: recording.id))) }
                    catch { warnings.append(.failure(error)) }
                }
                do { try store.save(interrupted) }
                catch { warnings.append(.failure(error)) }
                return interrupted
            }
            restoreWorkflowSelection()
            errorDetails = warnings
        } catch {
            errorDetails = [.failure(error)]
        }
    }

    public func importAudio(from source: URL, using importer: any AudioImporting) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let recording = try await store.importAudio(from: source, using: importer)
            recordings.insert(recording, at: 0)
            select(recording.id)
        } catch {
            errorDetails = [.failure(error as? AudioProcessingError ?? .storage)]
        }
    }

    public func dismissError() { errorDetails = [] }

    /// Called only after the processing use case has revalidated its confirmation.
    func trashMaterial(_ recording: Recording) throws {
        guard canCreateProject, recordings.contains(recording) else { throw RecordingStoreError.unsafePath }
        try store.trashMaterial(recording.id)
        recordings.removeAll { $0.id == recording.id }
        workflowSelections = workflowSelections.filter { $0.value != recording.id }
        if selectedID == recording.id {
            restoreWorkflowSelection()
            elapsed = selectedRecording?.duration ?? 0
        }
        if recordings(in: recording.workflow).isEmpty { emptyWorkspaces.insert(recording.workflow) }
        errorDetails = []
    }

    public func audioURL(for id: UUID) -> URL {
        recordings.first(where: { $0.id == id }).map { store.audioURL(for: $0) } ?? store.audioURL(for: id)
    }

    private func handleRecorderFailure(_ error: Error, token: UUID) {
        guard captureToken == token else { return }
        if phase == .starting {
            startupFailure = startupFailure ?? error
            return
        }
        guard phase == .recording || phase == .paused || phase == .pausing || phase == .resuming else { return }
        startupFailure = error
        endCapture(interruption: .captureFailure)
        errorDetails.insert(.failure(error), at: 0)
    }

    private func finishSaving(_ recording: Recording) {
        phase = .saving
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
        do {
            try store.save(recording)
            pendingSave = nil
            activeID = nil
            phase = .idle
            errorDetails = []
        } catch {
            pendingSave = recording
            phase = .awaitingSave
            errorDetails = [.awaitingSave, .failure(error)]
        }
    }

    private func beginMetering() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMeter() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateMeter() {
        guard phase == .recording else { return }
        elapsed = validDuration(recorder.currentTime)
        let amplitude = pow(10, Double(recorder.power) / 20)
        inputLevel = amplitude.isFinite ? min(1, max(0, amplitude)) : 0
    }

    private func endMetering() {
        timer?.invalidate()
        timer = nil
        inputLevel = 0
    }

    private func validDuration(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite ? max(0, duration) : 0
    }
}
