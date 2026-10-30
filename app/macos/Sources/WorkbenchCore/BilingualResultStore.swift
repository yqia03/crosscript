import Foundation

public enum BilingualResultStoreError: Error { case staleDeletion, deletedResult }

/// Independent bilingual versions live beside their managed recording. This
/// store never mutates the original audio or a transcription-only result.
public final class BilingualResultStore {
    private let recordings: RecordingStore
    private struct Library: Codable {
        var version = 1
        var results: [BilingualResult]
        // Optional for pre-deletion libraries. A delayed completion/checkpoint
        // must not recreate an explicitly deleted stable result ID.
        var deletedResultIDs: Set<UUID>?
    }
    public init(recordings: RecordingStore) { self.recordings = recordings }
    public func load(_ recordingID: UUID) throws -> [BilingualResult] {
        try loadLibrary(recordingID).results
    }
    private func loadLibrary(_ recordingID: UUID) throws -> Library {
        let path = try location(recordingID)
        guard FileManager.default.fileExists(atPath: path.path) else { return Library(results: []) }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: path))
        guard library.version == 1, Set(library.results.map(\.id)).count == library.results.count,
              Set(library.results.map(\.id)).isDisjoint(with: library.deletedResultIDs ?? []) else { throw AudioProcessingError.storage }
        for result in library.results { try validate(result, recordingID: recordingID) }
        return library
    }
    @discardableResult public func publish(_ result: BilingualResult) throws -> BilingualResult {
        try validate(result, recordingID: result.recordingID)
        var library = try loadLibrary(result.recordingID)
        guard library.deletedResultIDs?.contains(result.id) != true else { throw BilingualResultStoreError.deletedResult }
        // Retried completion can never replace this version's persisted edits.
        if let saved = library.results.first(where: { $0.id == result.id }) { return saved }
        library.results.append(result)
        try persist(library, recordingID: result.recordingID)
        return result
    }
    public func saveEdit(_ result: BilingualResult, replacing previous: BilingualResult) throws {
        try validate(result, recordingID: previous.recordingID)
        var library = try loadLibrary(previous.recordingID)
        guard result.id == previous.id, result.configuration == previous.configuration,
              result.direction == previous.direction, result.createdAt == previous.createdAt,
              let index = library.results.firstIndex(where: { $0 == previous }) else { throw AudioProcessingError.storage }
        library.results[index] = result
        try persist(library, recordingID: previous.recordingID)
    }
    /// Delete only the exact result list shown in the confirmation. The audio,
    /// ordinary transcripts and repair journal remain untouched.
    @discardableResult public func delete(recordingID: UUID, resultID: UUID,
                                         confirmedResults: [BilingualResult]) throws -> [BilingualResult] {
        var library = try loadLibrary(recordingID)
        guard library.results == confirmedResults, library.results.contains(where: { $0.id == resultID }) else {
            throw BilingualResultStoreError.staleDeletion
        }
        library.results.removeAll { $0.id == resultID }
        library.deletedResultIDs = (library.deletedResultIDs ?? []).union([resultID])
        try persist(library, recordingID: recordingID)
        return library.results
    }
    private func validate(_ result: BilingualResult, recordingID: UUID) throws {
        guard result.recordingID == recordingID, result.document.isFinished,
              (try? result.configuration.validated()) == result.configuration else { throw AudioProcessingError.storage }
        for alignment in result.document.alignment {
            let length = result.document.text(alignment.channel).utf16.count
            guard alignment.connectionStartFrame >= 0, alignment.range.location >= 0,
                  alignment.range.length >= 0, alignment.range.location <= length,
                  alignment.range.length <= length - alignment.range.location,
                  alignment.elapsedMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw AudioProcessingError.storage }
        }
    }
    private func persist(_ library: Library, recordingID: UUID) throws {
        try JSONEncoder().encode(library).write(to: location(recordingID), options: .atomic)
    }
    private func location(_ id: UUID) throws -> URL {
        _ = try recordings.loadTranscription(for: id)
        let directory = recordings.audioURL(for: id).deletingLastPathComponent()
        let path = directory.appendingPathComponent("bilingual-results.json")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              path.standardizedFileURL == path.resolvingSymlinksInPath().standardizedFileURL else { throw RecordingStoreError.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular { throw RecordingStoreError.unsafePath }
        return path
    }
}
