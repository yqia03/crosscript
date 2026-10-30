import Combine
import Foundation

/// Manual, durable, range-only repair. Uses the same execution gate as file
/// transcription/PDF; restoring a journal never begins a chargeable operation.
@MainActor public final class TranscriptRepairSession: ObservableObject {
    @Published public private(set) var tasks: [TranscriptRepairTask] = []
    @Published public private(set) var needsSave = false
    @Published public private(set) var error: AudioProcessingError?
    @Published public private(set) var runningID: UUID?
    @Published public private(set) var authorizingID: UUID?
    private let recordings: RecordingSession
    private let processing: PostRecordingSession
    private let store: TranscriptRepairStore
    private let credentials: any AudioCredentials
    private let service: any IntervalTranscribing
    private let gate: BackgroundProcessingGate
    private var worker: Task<Void, Never>?
    private var unreadable = Set<UUID>()
    private var unsaved = Set<UUID>()
    private var closing = false

    public init(recordings: RecordingSession, processing: PostRecordingSession, store: TranscriptRepairStore,
                credentials: any AudioCredentials, service: any IntervalTranscribing, gate: BackgroundProcessingGate) {
        self.recordings = recordings; self.processing = processing; self.store = store
        self.credentials = credentials; self.service = service; self.gate = gate
        for recording in recordings.recordings {
            do {
                var values = try store.load(recording.id)
                for index in values.indices {
                    if [.queued, .running].contains(values[index].status) {
                        values[index].status = values[index].remainingIntervals.isEmpty && values[index].completedCount > 0 ? .awaitingLocalSave : .awaitingResume
                    }
                    // A result saved just before a crash is recognized by stable ID.
                    if values[index].status == .awaitingLocalSave,
                       processing.materials[recording.id]?.results.contains(where: { $0.id == values[index].resultID }) == true {
                        values[index].status = values[index].remainingIntervals.isEmpty ? .completed : .awaitingResume
                    }
                }
                tasks += values
                if !values.isEmpty { _ = persist(recording.id) }
            } catch { unreadable.insert(recording.id); self.error = .storage }
        }
        tasks.sort { $0.createdAt < $1.createdAt }
    }

    public func occupiesMaterial(_ id: UUID) -> Bool {
        unreadable.contains(id) || unsaved.contains(id) || tasks.contains { $0.recordingID == id && ($0.status.occupiesMaterial || $0.id == runningID) }
    }

    @discardableResult public func submit(recordingID: UUID, sourceResultID: UUID, configuration: AudioServiceConfiguration) -> UUID? {
        guard !closing, !needsSave, !tasks.contains(where: { $0.status == .awaitingLocalSave }), !unreadable.contains(recordingID), recordings.activeID != recordingID,
              let recording = recordings.recordings.first(where: { $0.id == recordingID }), [.saved, .interrupted].contains(recording.status),
              let source = processing.materials[recordingID]?.results.first(where: { $0.id == sourceResultID }),
              !source.currentDocument.missingIntervals.isEmpty,
              !tasks.contains(where: { $0.recordingID == recordingID && $0.sourceResultID == sourceResultID && $0.status.occupiesMaterial }) else {
            error = .processing; return nil
        }
        guard (try? configuration.validated()) == configuration, configuration.supportsSegmentTimestamps,
              source.currentDocument.missingIntervals.allSatisfy({ $0.start >= 0 && $0.end <= recording.duration + 0.001 }) else {
            error = .configuration; return nil
        }
        let task = TranscriptRepairTask(recordingID: recordingID, source: source, configuration: configuration)
        tasks.append(task)
        guard persist(recordingID) else { return task.id }
        error = nil; dispatchQueued(); return task.id
    }

    public func resume(_ id: UUID) {
        guard !closing, !needsSave, let index = tasks.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled, .awaitingResume].contains(tasks[index].status), runningID != id,
              recordings.activeID != tasks[index].recordingID, !tasks[index].remainingIntervals.isEmpty else { return }
        error = nil
        tasks[index].generation = UUID(); tasks[index].resultID = UUID(); tasks[index].status = .queued; tasks[index].failure = nil
        for part in tasks[index].intervals.indices where tasks[index].intervals[part].document == nil { tasks[index].intervals[part].failure = nil }
        if persist(tasks[index].recordingID) { dispatchQueued() }
    }
    public func cancel(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              [.queued, .running, .awaitingResume].contains(tasks[index].status) else { return }
        tasks[index].status = .cancelled; tasks[index].failure = .interrupted
        _ = persist(tasks[index].recordingID)
        if runningID == id { worker?.cancel() } else { gate.cancelWaiting(id: id) }
    }
    public func cancelForDeletion(_ recordingID: UUID) {
        for task in tasks where task.recordingID == recordingID { cancel(task.id) }
    }
    public func retrySaving() {
        // A quit preflight also calls this. Healthy, already-submitted queued
        // work must stay queued when the user keeps the application open.
        guard needsSave || tasks.contains(where: { $0.status == .awaitingLocalSave }) else { return }
        for id in Array(unsaved) { _ = persist(id) }
        guard !needsSave else { return }
        for task in tasks where task.status == .awaitingLocalSave && task.id != runningID { publish(task.id) }
        if !tasks.contains(where: { $0.status == .awaitingLocalSave }) { error = nil }
        // A local-save retry never silently submits additional paid intervals.
        for index in tasks.indices where tasks[index].status == .queued {
            tasks[index].status = .awaitingResume; gate.cancelWaiting(id: tasks[index].id)
            _ = persist(tasks[index].recordingID)
        }
    }
    public func awaitShutdown() async {
        closing = true
        for index in tasks.indices where [.queued, .running].contains(tasks[index].status) {
            tasks[index].status = .awaitingResume; tasks[index].failure = .interrupted
            gate.cancelWaiting(id: tasks[index].id); _ = persist(tasks[index].recordingID)
        }
        worker?.cancel(); await worker?.value
    }
    /// Another material owner may refuse final App termination after this
    /// worker stopped. Re-enable manual commands without silently requeuing.
    public func continueAfterCancelledQuit() { closing = false }
    public func prepareToQuit() -> Bool {
        retrySaving()
        let ready = !needsSave && !tasks.contains { $0.status == .awaitingLocalSave }
        if !ready { closing = false }
        return ready
    }

    private func dispatchQueued() {
        guard !closing, !needsSave, !tasks.contains(where: { $0.status == .awaitingLocalSave }) else { return }
        for task in tasks where task.status == .queued {
            gate.enqueue(id: task.id) { [weak self] in self?.begin(task.id) }
        }
    }
    private func begin(_ id: UUID) {
        guard !closing, !needsSave, !tasks.contains(where: { $0.status == .awaitingLocalSave }), let index = tasks.firstIndex(where: { $0.id == id && $0.status == .queued }),
              recordings.activeID != tasks[index].recordingID else { gate.finish(id: id); return }
        tasks[index].status = .running
        guard persist(tasks[index].recordingID) else {
            tasks[index].status = .awaitingResume; gate.finish(id: id); return
        }
        runningID = id
        let snapshot = tasks[index]
        worker = Task { [weak self] in
            guard let self else { return }
            await self.execute(snapshot)
            self.runningID = nil; self.worker = nil
            // Late/uncooperative service work must actually return first.
            self.gate.finish(id: id)
            self.dispatchQueued()
        }
    }
    private func accepts(_ task: TranscriptRepairTask) -> Bool {
        !Task.isCancelled && tasks.contains { $0.id == task.id && $0.generation == task.generation && $0.status == .running }
    }
    private func execute(_ task: TranscriptRepairTask) async {
        do {
            authorizingID = task.id
            let key: String?
            do { key = try await credentials.readAsync(for: task.configuration) }
            catch { authorizingID = nil; throw error }
            authorizingID = nil
            guard accepts(task) else { return }
            guard let key, !key.isEmpty else { throw AudioProcessingError.credential }
            for part in task.intervals.indices where task.intervals[part].document == nil {
                guard accepts(task) else { break }
                do {
                    let response = try await service.transcribe(audio: recordings.audioURL(for: task.recordingID),
                        interval: task.intervals[part].interval, configuration: task.configuration, apiKey: key)
                    guard accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) else { break }
                    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudioProcessingError.processing }
                    let range = task.intervals[part].interval
                    // Keep text even if provider supplied unusable timestamps;
                    // never offer misleading paragraph playback for that text.
                    let anchors = response.anchors.filter { $0.sourceStart >= range.start - 0.001 && $0.sourceEnd <= range.end + 0.001 }
                    tasks[index].intervals[part].document = .init(text: response.text, anchors: anchors)
                    tasks[index].intervals[part].failure = nil
                    if !persist(task.recordingID) { tasks[index].status = .awaitingLocalSave; break }
                } catch {
                    guard accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) else { break }
                    let failure = (error as? AudioRequestFailure)?.category ?? error as? AudioProcessingError ?? .processing
                    tasks[index].intervals[part].failure = failure; tasks[index].failure = failure
                    if !persist(task.recordingID) { tasks[index].status = .awaitingLocalSave; break }
                    if [.credential, .quotaExceeded, .configuration, .modelUnavailable, .unavailable, .rateLimited, .requestLimited].contains(failure) { break }
                }
            }
        } catch {
            if accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].failure = error as? AudioProcessingError ?? .processing
            }
        }
        guard let index = tasks.firstIndex(where: { $0.id == task.id && $0.generation == task.generation }) else { return }
        if unsaved.contains(task.recordingID) { tasks[index].status = .awaitingLocalSave; return }
        if tasks[index].completedCount > 0 { publish(task.id) }
        else {
            if tasks[index].status == .running { tasks[index].status = .failed }
            _ = persist(task.recordingID)
        }
    }
    private func publish(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        guard task.completedCount > 0 else {
            tasks[index].status = .awaitingResume; _ = persist(task.recordingID); return
        }
        // Journal the stable publication ID before saving the visible version.
        tasks[index].status = .awaitingLocalSave
        guard persist(task.recordingID) else { return }
        guard processing.saveTranscriptResult(recordingID: task.recordingID, resultID: task.resultID, createdAt: Date(),
            configuration: task.configuration, document: task.repairedDocument) else { error = .storage; return }
        if task.remainingIntervals.isEmpty { tasks[index].status = .completed; tasks[index].failure = nil }
        else if [.cancelled, .awaitingResume].contains(task.status) { tasks[index].status = task.status }
        else { tasks[index].status = .failed }
        _ = persist(task.recordingID)
    }
    @discardableResult private func persist(_ recordingID: UUID) -> Bool {
        do {
            try store.save(tasks.filter { $0.recordingID == recordingID }, recordingID: recordingID)
            unsaved.remove(recordingID); needsSave = !unsaved.isEmpty; return true
        } catch { unsaved.insert(recordingID); needsSave = true; self.error = .storage; return false }
    }
}
