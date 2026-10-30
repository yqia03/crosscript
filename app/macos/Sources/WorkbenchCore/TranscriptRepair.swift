import Foundation

public protocol IntervalTranscribing: Sendable {
    /// Transcribe only this recording media range. Returned times are relative
    /// to the original recording, never to the temporary sliced upload.
    func transcribe(audio: URL, interval: MissingInterval, configuration: AudioServiceConfiguration,
                    apiKey: String) async throws -> TranscribedAudio
}

public struct TranscriptRepairInterval: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { interval.id }
    public let interval: MissingInterval
    public var document: TranscriptDocument?
    public var failure: AudioProcessingError?
    public init(interval: MissingInterval) { self.interval = interval }
}

public struct TranscriptRepairTask: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, awaitingResume, awaitingLocalSave, completed, failed, cancelled
        public var occupiesMaterial: Bool {
            [.queued, .running, .awaitingResume, .awaitingLocalSave].contains(self)
        }
    }
    public let id: UUID
    public let recordingID: UUID
    public let sourceResultID: UUID
    public let createdAt: Date
    public let configuration: AudioServiceConfiguration
    public let baseDocument: TranscriptDocument
    public var resultID: UUID
    public var generation: UUID
    public var status: Status
    public var intervals: [TranscriptRepairInterval]
    public var failure: AudioProcessingError?
    public var completedCount: Int { intervals.filter { $0.document != nil }.count }
    public var remainingIntervals: [MissingInterval] { intervals.filter { $0.document == nil }.map(\.interval) }
    init(recordingID: UUID, source: TranscriptResult, configuration: AudioServiceConfiguration) {
        id = UUID(); self.recordingID = recordingID; sourceResultID = source.id; createdAt = Date()
        self.configuration = configuration; baseDocument = source.currentDocument
        resultID = UUID(); generation = UUID(); status = .queued
        intervals = source.currentDocument.missingIntervals.map(TranscriptRepairInterval.init)
    }

    /// Preserve all text from the submitted version, including user edits. Insert
    /// repaired text before the next known media anchor; when location was lost
    /// through editing, append rather than guess or replace user-authored text.
    public var repairedDocument: TranscriptDocument {
        let source = baseDocument.text as NSString
        let repaired = intervals.filter { $0.document != nil }.sorted { $0.interval.startFrame < $1.interval.startFrame }
        var insertions: [(offset: Int, frame: Int64, document: TranscriptDocument)] = repaired.map { item in
            let next = baseDocument.anchors.filter { $0.sourceStart >= item.interval.end }.min { $0.sourceStart < $1.sourceStart }
            return (next?.range.location ?? source.length, item.interval.startFrame, item.document!)
        }
        insertions.sort { $0.offset == $1.offset ? $0.frame < $1.frame : $0.offset < $1.offset }
        var text = "", anchors: [TranscriptAnchor] = [], cursor = 0
        var shifts: [(offset: Int, delta: Int)] = []
        func append(_ part: String) { text += part }
        for insertion in insertions {
            let offset = max(cursor, min(source.length, insertion.offset))
            append(source.substring(with: NSRange(location: cursor, length: offset - cursor)))
            let insertionStart = text.utf16.count
            if !text.isEmpty, !text.hasSuffix("\n\n") { append("\n\n") }
            let begin = text.utf16.count
            append(insertion.document.text)
            anchors += insertion.document.anchors.map { anchor in
                var moved = TranscriptAnchor(id: anchor.id, sourceStart: anchor.sourceStart, sourceEnd: anchor.sourceEnd,
                    range: .init(location: begin + anchor.range.location, length: anchor.range.length), chunkStartFrame: anchor.chunkStartFrame)
                moved.isStartReliable = anchor.isStartReliable
                return moved
            }
            append("\n\n"); cursor = offset
            shifts.append((offset, text.utf16.count - insertionStart))
        }
        append(source.substring(from: cursor))
        // Merge sorted offsets once; no text search and no per-anchor rebuild.
        var shiftIndex = 0, cumulativeShift = 0
        for anchor in baseDocument.anchors.sorted(by: { $0.range.location < $1.range.location }) {
            while shiftIndex < shifts.count, shifts[shiftIndex].offset <= anchor.range.location {
                cumulativeShift += shifts[shiftIndex].delta; shiftIndex += 1
            }
            let shifted = anchor.range.location + cumulativeShift
            var moved = TranscriptAnchor(id: anchor.id, sourceStart: anchor.sourceStart, sourceEnd: anchor.sourceEnd,
                range: .init(location: shifted, length: anchor.range.length), chunkStartFrame: anchor.chunkStartFrame)
            moved.isStartReliable = anchor.isStartReliable
            anchors.append(moved)
        }
        return TranscriptDocument(text: text, anchors: anchors, missingIntervals: remainingIntervals)
    }
}
