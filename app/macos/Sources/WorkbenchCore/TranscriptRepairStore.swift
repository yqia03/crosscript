import Foundation

/// Repair journals belong to the same managed audio material. They contain no
/// secrets and never publish into or replace an editable transcription result.
public final class TranscriptRepairStore {
    private let recordings: RecordingStore
    public init(recordings: RecordingStore) { self.recordings = recordings }
    private struct Journal: Codable { var version = 1; let tasks: [TranscriptRepairTask] }
    public func load(_ recordingID: UUID) throws -> [TranscriptRepairTask] {
        let path = try location(recordingID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: path))
        guard journal.version == 1 else { throw AudioProcessingError.storage }
        try validate(journal.tasks, recordingID: recordingID)
        return journal.tasks
    }
    public func save(_ tasks: [TranscriptRepairTask], recordingID: UUID) throws {
        try validate(tasks, recordingID: recordingID)
        try JSONEncoder().encode(Journal(tasks: tasks)).write(to: location(recordingID), options: .atomic)
    }
    private func validate(_ tasks: [TranscriptRepairTask], recordingID: UUID) throws {
        guard Set(tasks.map(\.id)).count == tasks.count else { throw AudioProcessingError.storage }
        for task in tasks {
            guard task.recordingID == recordingID, !task.intervals.isEmpty,
                  (try? task.configuration.validated()) == task.configuration,
                  task.intervals.map(\.interval) == task.baseDocument.missingIntervals,
                  task.intervals.allSatisfy({ $0.interval.startFrame >= 0 && $0.interval.endFrame > $0.interval.startFrame }) else {
                throw AudioProcessingError.storage
            }
        }
    }
    private func location(_ id: UUID) throws -> URL {
        _ = try recordings.loadTranscription(for: id)
        let directory = recordings.audioURL(for: id).deletingLastPathComponent()
        let path = directory.appendingPathComponent("transcript-repair-tasks.json")
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              path.standardizedFileURL.path == path.resolvingSymlinksInPath().standardizedFileURL.path else { throw RecordingStoreError.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular { throw RecordingStoreError.unsafePath }
        return path
    }
}
