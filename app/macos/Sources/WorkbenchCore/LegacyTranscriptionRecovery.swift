import Foundation

public struct LegacyTranscriptionSnapshot: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let resultID: UUID
    public let createdAt: Date
    public let source: AudioSource
    public let configuration: AudioServiceConfiguration
}

/// Compatibility decoder for checkpoints produced by the removed live-transcription feature.
/// No current workflow creates checkpoints in this format.
public struct LegacyTranscriptionDraft: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let snapshot: LegacyTranscriptionSnapshot
    public let document: TranscriptDocument
    public let capturedEndFrame: Int64
    public let unconfirmedStartFrame: Int64
    public let finished: Bool
    public init(snapshot: LegacyTranscriptionSnapshot, document: TranscriptDocument, capturedEndFrame: Int64,
                unconfirmedStartFrame: Int64? = nil, finished: Bool) {
        self.snapshot = snapshot; self.document = document; self.capturedEndFrame = capturedEndFrame
        self.unconfirmedStartFrame = unconfirmedStartFrame ?? capturedEndFrame; self.finished = finished
    }
}

/// Imports old received text into History without credentials, capture, or a cloud request.
/// Original checkpoint bytes remain in the material until the user deletes it.
public final class LegacyTranscriptionRecovery {
    private let recordings: RecordingStore
    public init(recordings: RecordingStore) { self.recordings = recordings }
    public func load(_ recordingID: UUID) throws -> LegacyTranscriptionDraft? {
        let path = try location(recordingID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let draft = try JSONDecoder().decode(LegacyTranscriptionDraft.self, from: Data(contentsOf: path))
        guard draft.schemaVersion == 1, draft.snapshot.recordingID == recordingID, draft.capturedEndFrame >= 0, draft.unconfirmedStartFrame >= 0, draft.unconfirmedStartFrame <= draft.capturedEndFrame else { throw AudioProcessingError.storage }
        return draft
    }
    /// Startup recovery is local only. It publishes received text and marks any
    /// captured tail after the last checkpoint as missing text, never lost audio.
    @MainActor @discardableResult public func recover(recordings: RecordingSession, processing: PostRecordingSession) -> Bool {
        var success = true
        for recording in recordings.recordings where recording.id != recordings.activeID {
            processing.pendingLegacyRecovery.insert(recording.id)
            do {
                guard let draft = try load(recording.id) else {
                    processing.pendingLegacyRecovery.remove(recording.id)
                    continue
                }
                let marker = try location(recording.id, filename: "legacy-transcription-recovered.json")
                if FileManager.default.fileExists(atPath: marker.path) {
                    guard try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker)) == draft.snapshot.resultID else { throw AudioProcessingError.storage }
                    processing.pendingLegacyRecovery.remove(recording.id)
                    continue
                }
                let frames = recording.duration * LiveAudioChunk.sampleRate
                guard frames.isFinite, frames >= 0, frames < Double(Int64.max) else { throw AudioProcessingError.storage }
                let end = Int64(frames)
                var intervals = draft.document.missingIntervals
                if !draft.finished, end > draft.unconfirmedStartFrame {
                    intervals.append(.init(startFrame: draft.unconfirmedStartFrame, endFrame: end))
                }
                let document = TranscriptDocument(text: draft.document.text, anchors: draft.document.anchors, missingIntervals: intervals)
                let value = draft.snapshot
                // Keep the source checkpoint bytes as an additional recovery copy.
                if !processing.saveTranscriptResult(recordingID: recording.id, resultID: value.resultID,
                    createdAt: value.createdAt, configuration: value.configuration, document: document) { success = false }
                else {
                    try JSONEncoder().encode(value.resultID).write(to: marker, options: .atomic)
                    processing.pendingLegacyRecovery.remove(recording.id)
                }
            } catch { success = false }
        }
        return success
    }
    private func location(_ id: UUID, filename: String = "live-transcript-draft.json") throws -> URL {
        // Reuse the owning recording store's material validation, including all
        // managed parents, before admitting the additional private draft leaf.
        _ = try recordings.loadTranscription(for: id)
        let directory = recordings.audioURL(for: id).deletingLastPathComponent()
        let path = directory.appendingPathComponent(filename)
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              path.standardizedFileURL.path == path.resolvingSymlinksInPath().standardizedFileURL.path else { throw RecordingStoreError.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular { throw RecordingStoreError.unsafePath }
        return path
    }
}
