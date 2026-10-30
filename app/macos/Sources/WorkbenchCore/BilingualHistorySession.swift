import Combine
import Foundation

public struct BilingualResultDeletionConfirmation: Identifiable {
    public let id = UUID()
    public let recordingName: String
    public let result: BilingualResult
    public let resultNumber: Int
    public var otherResultCount: Int { confirmedResults.count - 1 }
    fileprivate let confirmedResults: [BilingualResult]
}

/// An editor owns one historical version. Failed writes keep its draft in
/// memory, while optimistic replacement prevents stale editors overwriting it.
@MainActor public final class BilingualHistorySession: ObservableObject {
    @Published public private(set) var results: [BilingualResult] = []
    @Published public private(set) var selectedID: UUID?
    @Published public var sourceText = ""
    @Published public var translationText = ""
    @Published public private(set) var loadFailed = false
    @Published public private(set) var saveFailed = false
    @Published public private(set) var pendingDeletion: BilingualResultDeletionConfirmation?
    @Published public private(set) var deletionError: MaterialDeletionError?
    public let recordingID: UUID
    private let loadResults: () throws -> [BilingualResult]
    private let saveResult: (BilingualResult, BilingualResult) throws -> Void
    private let deleteResult: ((UUID, [BilingualResult]) throws -> [BilingualResult])?
    public convenience init(recordingID: UUID, store: BilingualResultStore) {
        self.init(recordingID: recordingID, load: { try store.load(recordingID) },
                  save: { try store.saveEdit($0, replacing: $1) },
                  delete: { try store.delete(recordingID: recordingID, resultID: $0, confirmedResults: $1) })
    }
    public init(recordingID: UUID, load: @escaping () throws -> [BilingualResult],
                save: @escaping (BilingualResult, BilingualResult) throws -> Void,
                delete: ((UUID, [BilingualResult]) throws -> [BilingualResult])? = nil) {
        self.recordingID = recordingID; loadResults = load; saveResult = save; deleteResult = delete
    }
    public var selected: BilingualResult? { results.first { $0.id == selectedID } }
    public var hasUnsavedChanges: Bool {
        guard let selected else { return false }
        return sourceText != selected.document.source.text || translationText != selected.document.translation.text
    }
    public var exported: String { sourceText + "\n\n" + translationText }
    public func deletionBlockReason(_ external: () -> MaterialDeletionError?) -> MaterialDeletionError? {
        guard !loadFailed, selected != nil, deleteResult != nil else { return .unavailable }
        if hasUnsavedChanges { return .unsavedChanges }
        return external()
    }
    @discardableResult public func requestDeletion(recordingName: String,
                                                  blockingReason: () -> MaterialDeletionError?) -> Bool {
        if let reason = deletionBlockReason(blockingReason) { deletionError = reason; return false }
        guard let selected, let index = results.firstIndex(where: { $0.id == selected.id }) else { return false }
        pendingDeletion = .init(recordingName: recordingName, result: selected, resultNumber: index + 1, confirmedResults: results)
        deletionError = nil; return true
    }
    public func cancelDeletion() { pendingDeletion = nil; deletionError = nil }
    /// Return the exact deleted ID only after durable success, allowing both
    /// reading windows to invalidate it without touching another result.
    @discardableResult public func confirmDeletion(blockingReason: () -> MaterialDeletionError?) -> UUID? {
        guard let confirmation = pendingDeletion, let deleteResult else { return nil }
        if let reason = deletionBlockReason(blockingReason) { deletionError = reason; return nil }
        guard selectedID == confirmation.result.id, results == confirmation.confirmedResults else {
            deletionError = .staleConfirmation; return nil
        }
        do {
            let remaining = try deleteResult(confirmation.result.id, confirmation.confirmedResults)
            results = remaining; selectedID = remaining.last?.id; discardChanges()
            cancelDeletion(); return confirmation.result.id
        } catch BilingualResultStoreError.staleDeletion { deletionError = .staleConfirmation }
        catch { deletionError = .storage }
        return nil
    }
    public func reload() {
        guard !hasUnsavedChanges else { return }
        do {
            let loaded = try loadResults()
            guard loaded.allSatisfy({ $0.recordingID == recordingID }) else { throw AudioProcessingError.storage }
            results = loaded; loadFailed = false
            selectedID = loaded.contains(where: { $0.id == selectedID }) ? selectedID : loaded.last?.id
            discardChanges()
        } catch { loadFailed = true }
    }
    @discardableResult public func select(_ id: UUID) -> Bool {
        guard !hasUnsavedChanges, results.contains(where: { $0.id == id }) else { return false }
        selectedID = id; discardChanges(); return true
    }
    public func discardChanges() {
        sourceText = selected?.document.source.text ?? ""
        translationText = selected?.document.translation.text ?? ""
        saveFailed = false
    }
    @discardableResult public func save() -> BilingualResult? {
        guard let previous = selected else { return nil }
        guard hasUnsavedChanges else { return previous }
        var edited = previous
        if sourceText != previous.document.source.text { edited.document.edit(sourceText, channel: .source) }
        if translationText != previous.document.translation.text { edited.document.edit(translationText, channel: .translation) }
        do {
            try saveResult(edited, previous)
            if let index = results.firstIndex(where: { $0.id == edited.id }) { results[index] = edited }
            saveFailed = false; return edited
        } catch { saveFailed = true; return nil }
    }
}
