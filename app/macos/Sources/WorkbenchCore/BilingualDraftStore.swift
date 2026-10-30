import Foundation

/// A checkpoint is private working state. Its result ID is reserved once and
/// publication never overwrites an already saved version or its user edits.
public struct BilingualDraft: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let result: BilingualResult
    public let continuity: BilingualAudioContinuity
    public init(result: BilingualResult, continuity: BilingualAudioContinuity) {
        self.result = result; self.continuity = continuity
    }
    public func recovered(recordedEndFrame: Int64) throws -> BilingualResult {
        guard schemaVersion == 1, continuity.isValid, recordedEndFrame >= continuity.capturedEndFrame else {
            throw AudioProcessingError.storage
        }
        var value = result
        for channel in BilingualChannel.allCases {
            if result.document.isFinished {
                if recordedEndFrame > continuity.capturedEndFrame {
                    value.document.addMissing([.init(startFrame: continuity.capturedEndFrame, endFrame: recordedEndFrame)], channel: channel)
                }
            } else {
                value.document.addMissing(try continuity.recoveryMissing(channel, recordedEndFrame: recordedEndFrame), channel: channel)
            }
        }
        value.document.finish(completedChannels: result.document.isFinished ? result.document.completedChannels : [])
        return value
    }
}

public final class BilingualDraftStore {
    private let recordings: RecordingStore
    public init(recordings: RecordingStore) { self.recordings = recordings }
    public func save(_ draft: BilingualDraft) throws {
        try validate(draft, recordingID: draft.result.recordingID)
        try JSONEncoder().encode(draft).write(to: location(draft.result.recordingID), options: .atomic)
    }
    public func load(_ recordingID: UUID) throws -> BilingualDraft? {
        let path = try location(recordingID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(BilingualDraft.self, from: Data(contentsOf: path))
        try validate(value, recordingID: recordingID)
        return value
    }
    public func remove(_ recordingID: UUID) throws {
        let path = try location(recordingID)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// No key access, socket or repair dispatch. Failed drafts stay on disk and
    /// their IDs are returned so the application can retain a recovery warning.
    @MainActor public func recover(recordings session: RecordingSession, results: BilingualResultStore,
                                  including recordingIDs: Set<UUID>? = nil) -> Set<UUID> {
        var failed = Set<UUID>()
        for recording in session.recordings where recording.id != session.activeID && (recordingIDs?.contains(recording.id) ?? true) {
            do {
                guard let draft = try load(recording.id) else { continue }
                let frames = try BilingualAudioContinuity.recordedEndFrame(duration: recording.duration)
                _ = try results.publish(draft.recovered(recordedEndFrame: frames))
                try remove(recording.id)
            } catch { failed.insert(recording.id) }
        }
        return failed
    }
    private func validate(_ draft: BilingualDraft, recordingID: UUID) throws {
        guard draft.schemaVersion == 1, draft.result.recordingID == recordingID, draft.continuity.isValid,
              (try? draft.result.configuration.validated()) == draft.result.configuration else { throw AudioProcessingError.storage }
        for channel in BilingualChannel.allCases {
            let document = channel == .source ? draft.result.document.source : draft.result.document.translation
            guard document.missingIntervals.allSatisfy({ $0.isValid && $0.endFrame <= draft.continuity.capturedEndFrame }) else { throw AudioProcessingError.storage }
        }
        for alignment in draft.result.document.alignment {
            let length = draft.result.document.text(alignment.channel).utf16.count
            guard alignment.connectionStartFrame >= 0, alignment.connectionStartFrame <= draft.continuity.capturedEndFrame,
                  alignment.range.location >= 0, alignment.range.length >= 0, alignment.range.location <= length,
                  alignment.range.length <= length - alignment.range.location,
                  alignment.elapsedMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw AudioProcessingError.storage }
        }
    }
    private func location(_ id: UUID) throws -> URL {
        _ = try recordings.loadTranscription(for: id)
        let directory = recordings.audioURL(for: id).deletingLastPathComponent()
        let path = directory.appendingPathComponent("bilingual-draft.json")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              path.standardizedFileURL == path.resolvingSymlinksInPath().standardizedFileURL else { throw RecordingStoreError.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular { throw RecordingStoreError.unsafePath }
        return path
    }
}
