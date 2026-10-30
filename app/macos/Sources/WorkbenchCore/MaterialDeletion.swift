import Foundation

/// The selected result and its original material are distinct deletion scopes.
public enum MaterialDeletionTarget: Equatable {
    case result(recordingID: UUID, resultID: UUID)
    case material(recordingID: UUID)

    public var recordingID: UUID {
        switch self {
        case .result(let recordingID, _), .material(let recordingID): return recordingID
        }
    }
}

public enum MaterialDeletionError: Equatable {
    case busy, unsavedChanges, staleConfirmation, storage, unavailable
}

/// A confirmation describes the exact saved content shown to the user.
public struct MaterialDeletionConfirmation: Identifiable {
    public let id = UUID()
    public let target: MaterialDeletionTarget
    let recording: Recording
    let material: TranscriptionMaterial
    let bilingualResults: [BilingualResult]

    public var recordingName: String { recording.name }
    public var isImported: Bool { recording.isImported }
    public var resultCount: Int { material.results.count + bilingualResults.count }
    public var resultNumber: Int? {
        guard case .result(_, let resultID) = target,
              let index = material.results.firstIndex(where: { $0.id == resultID }) else { return nil }
        return index + 1
    }
    public var result: TranscriptResult? {
        guard case .result(_, let resultID) = target else { return nil }
        return material.results.first { $0.id == resultID }
    }
}
