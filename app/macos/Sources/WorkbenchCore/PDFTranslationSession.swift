import Combine
import Foundation

/// A failed list operation is attached to its file, even when another item was
/// imported or submitted successfully in the same user action.
public struct PDFWorkspaceIssue: Identifiable, Equatable {
    public let id = UUID()
    public let materialID: UUID?
    public let name: String
    public let error: PDFTranslationError
}

@MainActor public final class PDFTranslationSession: ObservableObject {
    @Published public private(set) var materials: [PDFMaterial] = []
    @Published public private(set) var workspaceMaterialIDs: [UUID] = []
    @Published public private(set) var sourceMetadata: [UUID: PDFSourceMetadata] = [:]
    @Published public private(set) var workspaceIssues: [PDFWorkspaceIssue] = []
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var runningTaskID: UUID?
    @Published public private(set) var authorizingTaskID: UUID?
    @Published public private(set) var progress: PDFEngineProgress?
    @Published public private(set) var error: PDFTranslationError?
    @Published public private(set) var pendingSaveIDs: Set<UUID> = []
    @Published public private(set) var unreadableIDs: [UUID] = []
    @Published public private(set) var deletionConfirmation: PDFDeletionConfirmation?
    @Published public private(set) var deletionError: MaterialDeletionError?
    public private(set) var workspaceGeneration: UInt64 = 0
    private let store: PDFMaterialStore
    private let credentials: any ProviderCredentials
    private let engine: any PDFTranslating
    private let gate: BackgroundProcessingGate
    private var worker: Task<Void, Never>?
    private var cancellationRequested: Set<UUID> = []
    private typealias PendingResult = PDFPendingResultReceipt
    private var pendingResults: [UUID: PendingResult] = [:]
    public var selectedMaterial: PDFMaterial? { materials.first { $0.id == selectedID } }
    public var workspaceMaterials: [PDFMaterial] { workspaceMaterialIDs.compactMap(find) }
    public var hasSubmittableWorkspaceMaterials: Bool { workspaceMaterialIDs.contains { !hasQueuedOrRunningTask($0) } }
    public var hasActiveWork: Bool { runningTaskID != nil || materials.contains { $0.tasks.contains { $0.status == .queued } } }

    public init(store: PDFMaterialStore, credentials: any ProviderCredentials, engine: any PDFTranslating, gate: BackgroundProcessingGate? = nil) {
        self.store = store; self.credentials = credentials; self.engine = engine; self.gate = gate ?? BackgroundProcessingGate()
        do {
            let loaded = try store.load(); materials = loaded.materials; unreadableIDs = loaded.unreadableIDs
            selectedID = materials.first?.id
            if let selectedID { workspaceMaterialIDs = [selectedID]; cacheMetadata(selectedID) }
            for var material in materials {
                var changed = false
                for index in material.tasks.indices {
                    if material.tasks[index].status == .running { material.tasks[index].status = .interrupted; material.tasks[index].failure = .interrupted; changed = true }
                    if material.tasks[index].status == .queued { material.tasks[index].status = .awaitingResume; changed = true }
                }
                if changed { _ = persist(material) }
            }
            for material in materials {
                for task in material.tasks {
                    if let receipt = try store.pendingResult(task.id, materialID: material.id), !material.results.contains(where: { $0.id == receipt.resultID }) {
                        pendingResults[material.id] = receipt; pendingSaveIDs.insert(material.id)
                    }
                }
            }
            if !unreadableIDs.isEmpty || !pendingSaveIDs.isEmpty { error = .storage }
        } catch { self.error = .storage }
    }
    /// A delayed import can retain its source workspace generation. Its managed
    /// copy still enters history after New project, without changing the new list.
    @discardableResult public func importPDF(_ url: URL, workspaceGeneration: UInt64? = nil) -> UUID? {
        let joinsWorkspace = workspaceGeneration == nil || workspaceGeneration == self.workspaceGeneration
        do {
            let material = try store.importPDF(url)
            materials.insert(material, at: 0)
            if joinsWorkspace { open(material.id); error = nil }
            return material.id
        } catch {
            if joinsWorkspace { self.error = error as? PDFTranslationError ?? .storage }
            return nil
        }
    }
    /// Picker and drag/drop imports share the same append-and-report behavior.
    @discardableResult public func importPDFs(_ urls: [URL], workspaceGeneration: UInt64? = nil) -> [UUID] {
        let joinsWorkspace = workspaceGeneration == nil || workspaceGeneration == self.workspaceGeneration
        if joinsWorkspace { workspaceIssues = [] }
        var imported: [UUID] = []
        for url in urls {
            if let id = importPDF(url, workspaceGeneration: workspaceGeneration) { imported.append(id) }
            else if joinsWorkspace { workspaceIssues.append(.init(materialID: nil, name: url.lastPathComponent, error: error ?? .invalidPDF)) }
        }
        return imported
    }
    /// Browsing history loads only local source metadata and leaves workspace
    /// membership, selection, drafts and processing attempts unchanged.
    public func prepareHistoryMetadata() { for material in materials { cacheMetadata(material.id) } }
    public func open(_ id: UUID) {
        guard find(id) != nil else { return }
        if !workspaceMaterialIDs.contains(id) { workspaceMaterialIDs.append(id) }
        cacheMetadata(id)
        selectedID = id
    }
    /// Start an empty working list without changing the retained material library,
    /// pending saves or workers. Empty projects have no durable record of their own.
    public func newProject() {
        workspaceGeneration &+= 1
        workspaceMaterialIDs = []
        selectedID = nil
        workspaceIssues = []
        if pendingSaveIDs.isEmpty && unreadableIDs.isEmpty { error = nil }
    }
    /// Removing a card changes only this session's working list. The journal,
    /// original copy, results and any running/queued worker remain untouched.
    public func removeFromWorkspace(_ id: UUID) {
        workspaceMaterialIDs.removeAll { $0 == id }
        workspaceIssues.removeAll { $0.materialID == id }
        if selectedID == id { selectedID = workspaceMaterialIDs.first }
    }
    public func hasQueuedOrRunningTask(_ materialID: UUID) -> Bool {
        find(materialID)?.tasks.contains { $0.status == .queued || $0.status == .running || $0.id == runningTaskID } ?? false
    }
    /// Freeze the form once at the caller, then submit each available file in
    /// list order. A bad page range never prevents another valid PDF running.
    @discardableResult public func submitWorkspace(provider: ProviderSnapshot?, options: PDFTranslationOptions) -> [UUID] {
        workspaceIssues = []
        var submitted: [UUID] = []
        for id in workspaceMaterialIDs {
            guard let material = find(id), !hasQueuedOrRunningTask(id) else { continue }
            if let task = submit(materialID: id, provider: provider, options: options) { submitted.append(task) }
            else { workspaceIssues.append(.init(materialID: id, name: material.name, error: error ?? .configuration)) }
        }
        return submitted
    }
    @discardableResult public func selectResult(materialID: UUID, resultID: UUID?) -> Bool {
        guard var material = find(materialID), resultID == nil || material.results.contains(where: { $0.id == resultID }) else { return false }
        material.selectedResultID = resultID; return persist(material)
    }
    public func originalURL(_ materialID: UUID) -> URL? { try? store.originalURL(materialID) }
    public func resultURL(materialID: UUID, resultID: UUID, output: PDFOutput) -> URL? { try? store.resultURL(materialID: materialID, resultID: resultID, output: output) }
    @discardableResult public func export(_ source: URL, to destination: URL) -> Bool {
        do { try store.export(source, to: destination); return true } catch { self.error = .storage; return false }
    }
    @discardableResult public func submit(materialID: UUID, provider: ProviderSnapshot?, options: PDFTranslationOptions) -> UUID? {
        guard pendingSaveIDs.isEmpty, var material = find(materialID) else { error = .storage; return nil }
        do { guard options.requiresService == (provider != nil) else { throw PDFTranslationError.configuration }; _ = try provider?.validated(); _ = try options.validated(pageCount: store.pageCount(materialID)) } catch { self.error = .configuration; return nil }
        let task = PDFBackgroundTask(provider: provider, options: options)
        material.tasks.append(task); material.updatedAt = Date()
        guard persist(material) else { return nil }
        enqueue(materialID: materialID, taskID: task.id)
        return task.id
    }
    /// Resume/retry creates a new immutable attempt and retains the old attempt.
    @discardableResult public func retry(materialID: UUID, taskID: UUID) -> UUID? {
        guard var material = find(materialID), let index = material.tasks.firstIndex(where: { $0.id == taskID }),
              runningTaskID != taskID, [.failed, .cancelled, .interrupted, .awaitingResume].contains(material.tasks[index].status) else { return nil }
        let old = material.tasks[index]
        if old.status == .awaitingResume || old.status == .interrupted {
            material.tasks[index].status = .cancelled
            guard persist(material) else { return nil }
        }
        return submit(materialID: materialID, provider: old.provider, options: old.options)
    }
    public func cancel(materialID: UUID, taskID: UUID) {
        guard var material = find(materialID), let index = material.tasks.firstIndex(where: { $0.id == taskID }), material.tasks[index].status.occupiesMaterial else { return }
        guard material.tasks[index].status != .awaitingLocalSave else { error = .storage; return }
        gate.cancelWaiting(id: taskID)
        if runningTaskID == taskID { cancellationRequested.insert(taskID); worker?.cancel() }
        material.tasks[index].status = .cancelled; material.tasks[index].failure = .cancelled
        _ = persist(material)
    }
    @discardableResult public func retrySaving() -> Bool { savePending(resumeQueued: true) }
    private func savePending(resumeQueued: Bool) -> Bool {
        for (id, pending) in pendingResults { finishGenerated(materialID: id, task: pending.task, generated: pending.generated, resultID: pending.resultID) }
        for id in Array(pendingSaveIDs) where pendingResults[id] == nil { if let material = find(id) { _ = persist(material) } }
        if pendingSaveIDs.isEmpty {
            error = unreadableIDs.isEmpty ? nil : .storage
            if resumeQueued { for material in materials { for task in material.tasks where task.status == .queued { enqueue(materialID: material.id, taskID: task.id) } } }
        }
        return pendingSaveIDs.isEmpty
    }
    public func prepareToQuit() -> Bool { savePending(resumeQueued: false) }
    public func prepareForConfirmedQuit() -> Bool {
        guard pendingSaveIDs.isEmpty else { error = .storage; return false }
        var changes: [(original: PDFMaterial, updated: PDFMaterial)] = []
        for material in materials {
            var updated = material
            for index in updated.tasks.indices where updated.tasks[index].status == .queued || updated.tasks[index].status == .running {
                updated.tasks[index].status = .interrupted; updated.tasks[index].failure = .interrupted
            }
            if updated != material { changes.append((material, updated)) }
        }
        var saved: [PDFMaterial] = []
        do {
            // Persist the exit decision before stopping any worker. A save failure
            // vetoes quit while the current process remains available.
            for change in changes { try store.save(change.updated); saved.append(change.original) }
        } catch {
            for original in saved { if (try? store.save(original)) == nil { pendingSaveIDs.insert(original.id) } }
            self.error = .storage; return false
        }
        for change in changes {
            replace(change.updated)
            for task in change.original.tasks where task.status == .queued || task.status == .running {
                gate.cancelWaiting(id: task.id)
                if runningTaskID == task.id { cancellationRequested.insert(task.id); worker?.cancel() }
            }
        }
        return true
    }
    /// The application must await this after accepting quit, before terminating.
    /// Native PDF workers implement TERM, bounded KILL, and waitUntilExit.
    public func awaitConfirmedShutdown() async { let active = worker; await active?.value }
    @discardableResult public func requestDeletion(_ target: PDFDeletionTarget) -> Bool {
        guard let material = deletionMaterial(target) else { return false }
        deletionConfirmation = .init(target: target, material: material); deletionError = nil; return true
    }
    public func cancelDeletion() { deletionConfirmation = nil; deletionError = nil }
    @discardableResult public func confirmDeletion() -> Bool {
        guard let confirmation = deletionConfirmation, let material = deletionMaterial(confirmation.target) else { return false }
        guard material == confirmation.material else { deletionError = .staleConfirmation; return false }
        do {
            switch confirmation.target {
            case .material:
                try store.trash(material); materials.removeAll { $0.id == material.id }
                removeFromWorkspace(material.id); sourceMetadata.removeValue(forKey: material.id)
            case .result(_, let id): replace(try store.deleteResult(material, resultID: id))
            }
            cancelDeletion(); return true
        } catch { deletionError = .storage; return false }
    }
    private func deletionMaterial(_ target: PDFDeletionTarget) -> PDFMaterial? {
        guard let material = find(target.materialID) else { deletionError = .unavailable; return nil }
        guard !material.isBusy, !material.tasks.contains(where: { $0.id == runningTaskID }) else { deletionError = .busy; return nil }
        guard !pendingSaveIDs.contains(material.id) else { deletionError = .unsavedChanges; return nil }
        if case .result(_, let id) = target, !material.results.contains(where: { $0.id == id }) { deletionError = .unavailable; return nil }
        return material
    }
    private func enqueue(materialID: UUID, taskID: UUID) {
        let gate = gate
        gate.enqueue(id: taskID) { [weak self] in
            guard let self else { gate.finish(id: taskID); return }
            self.start(materialID: materialID, taskID: taskID)
        }
    }
    private func start(materialID: UUID, taskID: UUID) {
        guard var material = find(materialID), let index = material.tasks.firstIndex(where: { $0.id == taskID }), material.tasks[index].status == .queued else { gate.finish(id: taskID); return }
        guard pendingSaveIDs.isEmpty else { gate.finish(id: taskID); return }
        material.tasks[index].status = .running
        guard persist(material) else {
            material.tasks[index].status = .queued; replace(material)
            gate.finish(id: taskID); return
        }
        let task = material.tasks[index]
        runningTaskID = taskID; progress = nil; error = nil
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.authorizingTaskID = nil
                self.runningTaskID = nil; self.progress = nil; self.worker = nil
                self.cancellationRequested.remove(taskID)
                self.gate.finish(id: taskID)
            }
            do {
                var key = "", termKey: String?
                if task.options.requiresService { self.authorizingTaskID = taskID }
                if task.options.requiresService {
                    guard let provider = task.provider, let value = try await self.credentials.readAsync(reference: provider.credentialReference), !value.isEmpty else { throw PDFTranslationError.credential }
                    try Task.checkCancellation()
                    guard !self.cancellationRequested.contains(taskID) else { return }
                    key = value
                }
                if task.options.requiresService, let termProvider = task.options.termExtractionProvider {
                    guard let selectedKey = try await self.credentials.readAsync(reference: termProvider.credentialReference), !selectedKey.isEmpty else { throw PDFTranslationError.credential }
                    try Task.checkCancellation()
                    guard !self.cancellationRequested.contains(taskID) else { return }
                    termKey = selectedKey
                }
                self.authorizingTaskID = nil
                try Task.checkCancellation()
                guard !self.cancellationRequested.contains(taskID) else { return }
                let input = try self.store.originalURL(materialID)
                let output = try self.store.stagingDirectory(taskID, materialID: materialID)
                let request = PDFEngineRequest(id: taskID, inputURL: input, outputDirectory: output, provider: task.provider, options: task.options, termExtractionAPIKey: termKey)
                let result = try await self.engine.translate(request, apiKey: key) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.runningTaskID == taskID, !self.cancellationRequested.contains(taskID) else { return }
                        self.progress = update
                    }
                }
                guard !self.cancellationRequested.contains(taskID), !Task.isCancelled else { return }
                self.finishGenerated(materialID: materialID, task: task, generated: result, resultID: UUID())
            } catch {
                guard !self.cancellationRequested.contains(taskID), !Task.isCancelled else { return }
                if var current = self.find(materialID), let index = current.tasks.firstIndex(where: { $0.id == taskID }) {
                    let failure = error as? PDFTranslationError ?? .processing
                    current.tasks[index].status = .failed; current.tasks[index].failure = failure
                    _ = self.persist(current); self.error = failure
                }
            }
        }
    }
    private func finishGenerated(materialID: UUID, task: PDFBackgroundTask, generated: PDFEngineResult, resultID: UUID) {
        guard var material = find(materialID), let index = material.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        do {
            try store.savePendingResult(.init(task: task, generated: generated, resultID: resultID), materialID: materialID)
            if !material.results.contains(where: { $0.id == resultID }) {
                material.results.append(try store.install(generated, task: task, material: material, resultID: resultID))
            }
            material.selectedResultID = resultID; material.tasks[index].status = .completed; material.tasks[index].failure = nil; material.updatedAt = Date()
            if persist(material) { pendingResults.removeValue(forKey: materialID); store.clearPendingResult(task.id, materialID: materialID) }
            else { pendingResults[materialID] = .init(task: task, generated: generated, resultID: resultID) }
        } catch {
            if let failure = error as? PDFTranslationError, failure == .invalidOutput {
                material.tasks[index].status = .failed; material.tasks[index].failure = failure
                _ = persist(material); self.error = failure; pendingResults.removeValue(forKey: materialID); store.clearPendingResult(task.id, materialID: materialID)
                return
            }
            material.tasks[index].status = .awaitingLocalSave; material.tasks[index].failure = .storage
            replace(material); pendingSaveIDs.insert(materialID)
            pendingResults[materialID] = .init(task: task, generated: generated, resultID: resultID); self.error = .storage
        }
    }
    private func find(_ id: UUID) -> PDFMaterial? { materials.first { $0.id == id } }
    private func cacheMetadata(_ id: UUID) {
        if sourceMetadata[id] == nil { sourceMetadata[id] = try? store.sourceMetadata(id) }
    }
    private func replace(_ material: PDFMaterial) {
        if let index = materials.firstIndex(where: { $0.id == material.id }) { materials[index] = material }
    }
    @discardableResult private func persist(_ material: PDFMaterial) -> Bool {
        replace(material)
        do { try store.save(material); pendingSaveIDs.remove(material.id); return true }
        catch { pendingSaveIDs.insert(material.id); self.error = .storage; return false }
    }
}
