import Foundation

public final class BilingualRepairStore {
    private struct Journal: Codable { var version = 1; let tasks: [BilingualRepairTask] }
    private let recordings: RecordingStore
    public init(recordings: RecordingStore) { self.recordings = recordings }
    public func load(_ recordingID: UUID) throws -> [BilingualRepairTask] {
        let path = try location(recordingID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let value = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: path))
        guard value.version == 1 else { throw AudioProcessingError.storage }
        try validate(value.tasks, recordingID: recordingID); return value.tasks
    }
    public func save(_ tasks: [BilingualRepairTask], recordingID: UUID) throws {
        try validate(tasks, recordingID: recordingID)
        try JSONEncoder().encode(Journal(tasks: tasks)).write(to: location(recordingID), options: .atomic)
    }
    private func validate(_ tasks: [BilingualRepairTask], recordingID: UUID) throws {
        guard Set(tasks.map(\.id)).count == tasks.count else { throw AudioProcessingError.storage }
        for task in tasks {
            guard task.recordingID == recordingID, task.source.document.isFinished, !task.parts.isEmpty,
                  (try? task.configuration.validated()) == task.configuration,
                  Set(task.parts.map(\.id)).count == task.parts.count else { throw AudioProcessingError.storage }
            if let pending = task.pendingDocument {
                guard pending.isFinished else { throw AudioProcessingError.storage }
                for channel in BilingualChannel.allCases {
                    let document = channel == .source ? pending.source : pending.translation
                    let expected = task.parts.filter { $0.channel == channel && $0.document == nil }.map(\.interval)
                    guard document.missingIntervals == MissingInterval.normalized(expected) else { throw AudioProcessingError.storage }
                }
            }
            for channel in BilingualChannel.allCases {
                let expected = channel == .source ? task.source.document.source.missingIntervals : task.source.document.translation.missingIntervals
                let actual = task.parts.filter({ $0.channel == channel }).map(\.interval)
                guard Self.isExactPartition(actual, of: expected) else { throw AudioProcessingError.storage }
            }
            guard task.parts.allSatisfy({ $0.interval.isValid && ($0.document == nil ||
                (!$0.document!.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.document!.missingIntervals.isEmpty)) }) else { throw AudioProcessingError.storage }
        }
    }
    /// Accept durable subranges only when they cover each original gap exactly,
    /// in order, with no omitted, overlapping or additional audio.
    private static func isExactPartition(_ parts: [MissingInterval], of gaps: [MissingInterval]) -> Bool {
        var index = 0
        for gap in gaps {
            var cursor = gap.startFrame
            while cursor < gap.endFrame {
                guard index < parts.count, parts[index].startFrame == cursor,
                      parts[index].endFrame > cursor, parts[index].endFrame <= gap.endFrame else { return false }
                cursor = parts[index].endFrame
                index += 1
            }
        }
        return index == parts.count
    }
    private func location(_ id: UUID) throws -> URL {
        _ = try recordings.loadTranscription(for: id)
        let directory = recordings.audioURL(for: id).deletingLastPathComponent()
        let path = directory.appendingPathComponent("bilingual-repair-tasks.json")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              path.standardizedFileURL == path.resolvingSymlinksInPath().standardizedFileURL else { throw RecordingStoreError.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular { throw RecordingStoreError.unsafePath }
        return path
    }
}
