import Combine
import Foundation

/// Manual bilingual range repair. Restoring a journal only offers resume; the
/// same shared gate remains occupied until the underlying adapter returns.
@MainActor public final class BilingualRepairSession: ObservableObject {
    @Published public private(set) var tasks: [BilingualRepairTask] = []
    @Published public private(set) var runningID: UUID?
    @Published public private(set) var authorizingID: UUID?
    @Published public private(set) var needsSave = false
    @Published public private(set) var error: AudioProcessingError?
    private let recordings: RecordingSession
    private let results: BilingualResultStore
    private let journal: BilingualRepairStore
    private let credentials: any AudioCredentials
    private let service: any BilingualIntervalRepairing
    private let gate: BackgroundProcessingGate
    private var unsaved = Set<UUID>()
    private var unreadable = Set<UUID>()
    private var unreadableResults = Set<UUID>()
    private var worker: Task<Void, Never>?
    private var closing = false

    public init(recordings: RecordingSession, results: BilingualResultStore, journal: BilingualRepairStore,
                credentials: any AudioCredentials, service: any BilingualIntervalRepairing,
                gate: BackgroundProcessingGate) {
        self.recordings = recordings; self.results = results; self.journal = journal
        self.credentials = credentials; self.service = service; self.gate = gate
        for recording in recordings.recordings {
            do {
                var restored = try journal.load(recording.id)
                let saved: [BilingualResult]
                do { saved = try results.load(recording.id) }
                catch { saved = []; unreadableResults.insert(recording.id); self.error = .storage }
                for index in restored.indices {
                    if [.queued, .running].contains(restored[index].status) {
                        // A crash can occur after the final durable part but
                        // before result publication. Offer a local save instead
                        // of trapping complete text behind a no-op resume.
                        let unpublishedParts = restored[index].completedCount > 0
                            && !saved.contains(where: { $0.id == restored[index].resultID })
                        restored[index].status = unpublishedParts ? .awaitingLocalSave : .awaitingResume
                    }
                    if restored[index].status == .awaitingLocalSave, saved.contains(where: { $0.id == restored[index].resultID }) {
                        restored[index].status = restored[index].remainingParts.isEmpty && restored[index].result.document.isComplete ? .completed : .awaitingResume
                    }
                }
                tasks += restored
                if !restored.isEmpty { _ = persist(recording.id) }
            } catch { unreadable.insert(recording.id); self.error = .storage }
        }
    }
    public func supports(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) -> Bool {
        service.supports(configuration: configuration, direction: direction)
    }
    public func occupiesMaterial(_ id: UUID) -> Bool {
        unreadable.contains(id) || unreadableResults.contains(id) || unsaved.contains(id) || tasks.contains { $0.recordingID == id && ($0.status.occupiesMaterial || $0.id == runningID) }
    }
    @discardableResult public func submit(recordingID: UUID, sourceResultID: UUID, configuration: AudioServiceConfiguration) -> UUID? {
        guard !closing, !needsSave, !unreadable.contains(recordingID), recordings.activeID != recordingID,
              !tasks.contains(where: { $0.status == .awaitingLocalSave }),
              let recording = recordings.recordings.first(where: { $0.id == recordingID }), [.saved, .interrupted].contains(recording.status),
              let source = try? results.load(recordingID).first(where: { $0.id == sourceResultID }),
              !tasks.contains(where: { $0.recordingID == recordingID && $0.source.id == sourceResultID && $0.status.occupiesMaterial }) else { error = .processing; return nil }
        guard (try? configuration.validated()) == configuration,
              supports(configuration: configuration, direction: source.direction) else { error = .configuration; return nil }
        let gaps = source.document.source.missingIntervals + source.document.translation.missingIntervals
        guard !gaps.isEmpty, gaps.allSatisfy({ $0.isValid && $0.end <= recording.duration + 0.001 }) else { error = .configuration; return nil }
        let task = BilingualRepairTask(source: source, configuration: configuration, maximumIntervalFrames: service.maximumIntervalFrames)
        tasks.append(task)
        if persist(recordingID) { error = nil; dispatchQueued() }
        else if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].status = .awaitingResume }
        return task.id
    }
    public func resume(_ id: UUID) {
        guard !closing, !needsSave, let index = tasks.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled, .awaitingResume].contains(tasks[index].status), runningID != id,
              recordings.activeID != tasks[index].recordingID, !tasks[index].remainingParts.isEmpty,
              supports(configuration: tasks[index].configuration, direction: tasks[index].source.direction) else { return }
        guard let recording = recordings.recordings.first(where: { $0.id == tasks[index].recordingID }),
              tasks[index].parts.allSatisfy({ $0.interval.isValid && $0.interval.end <= recording.duration + 0.001 }) else { error = .configuration; return }
        tasks[index].subdivideUnfinishedParts(maximumIntervalFrames: service.maximumIntervalFrames)
        tasks[index].generation = UUID(); tasks[index].resultID = UUID(); tasks[index].status = .queued; tasks[index].failure = nil
        tasks[index].pendingDocument = nil
        for part in tasks[index].parts.indices where tasks[index].parts[part].document == nil { tasks[index].parts[part].failure = nil }
        if persist(tasks[index].recordingID) { error = nil; dispatchQueued() }
        else { tasks[index].status = .awaitingResume }
    }
    public func cancel(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), [.queued, .running, .awaitingResume].contains(tasks[index].status) else { return }
        tasks[index].status = .cancelled; tasks[index].failure = .interrupted
        _ = persist(tasks[index].recordingID)
        if runningID == id { worker?.cancel() } else { gate.cancelWaiting(id: id) }
    }
    public func retrySaving() {
        for id in Array(unreadableResults) where (try? results.load(id)) != nil { unreadableResults.remove(id) }
        for id in Array(unsaved) { _ = persist(id) }
        guard !needsSave else { return }
        for task in tasks where task.status == .awaitingLocalSave && task.id != runningID { publish(task.id) }
        // Only a failed submit/resume becomes awaitingResume at the failure
        // site. A quit preflight must not take healthy queued work out of FIFO.
        dispatchQueued()
        clearResolvedStorageError()
    }
    public func editPending(_ id: UUID, text: String, channel: BilingualChannel) {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .awaitingLocalSave }) else { return }
        var document = tasks[index].result.document
        document.edit(text, channel: channel)
        tasks[index].pendingDocument = document
        _ = persist(tasks[index].recordingID)
    }
    public func awaitShutdown() async {
        closing = true
        for index in tasks.indices where [.queued, .running].contains(tasks[index].status) {
            tasks[index].status = .awaitingResume; tasks[index].failure = .interrupted
            gate.cancelWaiting(id: tasks[index].id); _ = persist(tasks[index].recordingID)
        }
        worker?.cancel(); await worker?.value
    }
    public func continueAfterCancelledQuit() { closing = false }
    public func prepareToQuit() -> Bool {
        retrySaving()
        let ready = !needsSave && !tasks.contains { $0.status == .awaitingLocalSave }
        if !ready { closing = false }
        return ready
    }
    private func dispatchQueued() {
        guard !closing, !needsSave, !tasks.contains(where: { $0.status == .awaitingLocalSave }) else { return }
        for task in tasks where task.status == .queued { gate.enqueue(id: task.id) { [weak self] in self?.begin(task.id) } }
    }
    private func begin(_ id: UUID) {
        guard !closing, !needsSave, !tasks.contains(where: { $0.status == .awaitingLocalSave }),
              let index = tasks.firstIndex(where: { $0.id == id && $0.status == .queued }),
              recordings.activeID != tasks[index].recordingID else { gate.finish(id: id); return }
        tasks[index].status = .running
        guard persist(tasks[index].recordingID) else { tasks[index].status = .awaitingResume; gate.finish(id: id); return }
        runningID = id
        let snapshot = tasks[index]
        worker = Task { [weak self] in
            guard let self else { return }
            await self.execute(snapshot)
            self.runningID = nil; self.worker = nil; self.gate.finish(id: id); self.dispatchQueued()
        }
    }
    private func accepts(_ task: BilingualRepairTask) -> Bool {
        !Task.isCancelled && tasks.contains { $0.id == task.id && $0.generation == task.generation && $0.status == .running }
    }
    private func execute(_ task: BilingualRepairTask) async {
        do {
            authorizingID = task.id
            let key: String?
            do { key = try await credentials.readAsync(for: task.configuration) }
            catch { authorizingID = nil; throw error }
            authorizingID = nil
            guard accepts(task) else { return }
            guard let key, !key.isEmpty else { throw AudioProcessingError.credential }
            for partIndex in task.parts.indices where task.parts[partIndex].document == nil {
                guard accepts(task) else { break }
                do {
                    let part = task.parts[partIndex]
                    let response = try await service.repair(audio: recordings.audioURL(for: task.recordingID), interval: part.interval,
                        channel: part.channel, configuration: task.configuration, direction: task.source.direction, apiKey: key)
                    guard accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) else { break }
                    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.missingIntervals.isEmpty else { throw AudioProcessingError.processing }
                    // Native bilingual event clocks do not establish paragraph anchors.
                    tasks[index].parts[partIndex].document = .init(text: response.text)
                    tasks[index].parts[partIndex].failure = nil
                    if !persist(task.recordingID) { tasks[index].status = .awaitingLocalSave; break }
                } catch {
                    guard accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) else { break }
                    let failure = (error as? AudioRequestFailure)?.category ?? error as? AudioProcessingError ?? .processing
                    tasks[index].parts[partIndex].failure = failure; tasks[index].failure = failure
                    if !persist(task.recordingID) { tasks[index].status = .awaitingLocalSave; break }
                    if [.credential, .quotaExceeded, .configuration, .modelUnavailable, .unavailable, .rateLimited, .requestLimited].contains(failure) { break }
                }
            }
        } catch {
            if accepts(task), let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].failure = error as? AudioProcessingError ?? .processing }
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
        guard task.completedCount > 0 else { tasks[index].status = .awaitingResume; _ = persist(task.recordingID); return }
        tasks[index].status = .awaitingLocalSave
        guard persist(task.recordingID) else { return }
        do {
            _ = try results.publish(task.result)
            unreadableResults.remove(task.recordingID)
            if task.remainingParts.isEmpty && task.result.document.isComplete { tasks[index].status = .completed; tasks[index].failure = nil }
            else if [.cancelled, .awaitingResume].contains(task.status) { tasks[index].status = task.status }
            else { tasks[index].status = .failed }
            _ = persist(task.recordingID)
            clearResolvedStorageError()
        } catch { self.error = .storage }
    }
    private func clearResolvedStorageError() {
        if error == .storage, unsaved.isEmpty, unreadable.isEmpty, unreadableResults.isEmpty,
           !tasks.contains(where: { $0.status == .awaitingLocalSave }) { error = nil }
    }
    @discardableResult private func persist(_ recordingID: UUID) -> Bool {
        do {
            try journal.save(tasks.filter { $0.recordingID == recordingID }, recordingID: recordingID)
            unsaved.remove(recordingID); needsSave = !unsaved.isEmpty; return true
        } catch { unsaved.insert(recordingID); needsSave = true; self.error = .storage; return false }
    }
}
