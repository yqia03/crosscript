import Foundation

/// An explicit adapter capability binds a file target and language direction.
/// Ordinary file transcription alone does not grant bilingual repair support.
public protocol BilingualIntervalRepairing: Sendable {
    /// Bound each durable task part to one request, so successful chunks survive
    /// a later failure and are not sent again during explicit resume.
    var maximumIntervalFrames: Int64? { get }
    func supports(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) -> Bool
    func repair(audio: URL, interval: MissingInterval, channel: BilingualChannel,
                configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                apiKey: String) async throws -> TranscriptDocument
}

public extension BilingualIntervalRepairing {
    var maximumIntervalFrames: Int64? { nil }
}

/// An explicitly disabled adapter for unavailable or unconfigured capabilities.
public struct UnavailableBilingualRepair: BilingualIntervalRepairing {
    public init() {}
    public func supports(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) -> Bool { false }
    public func repair(audio: URL, interval: MissingInterval, channel: BilingualChannel,
                       configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                       apiKey: String) async throws -> TranscriptDocument { throw AudioProcessingError.unavailable }
}

public struct BilingualRepairPart: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let channel: BilingualChannel
    public let interval: MissingInterval
    public var document: TranscriptDocument?
    public var failure: AudioProcessingError?
    public init(channel: BilingualChannel, interval: MissingInterval) {
        id = UUID(); self.channel = channel; self.interval = interval
    }
}

public struct BilingualRepairTask: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, awaitingResume, awaitingLocalSave, completed, failed, cancelled
        public var occupiesMaterial: Bool { [.queued, .running, .awaitingResume, .awaitingLocalSave].contains(self) }
    }
    public let id: UUID
    public let createdAt: Date
    public let source: BilingualResult
    public let configuration: AudioServiceConfiguration
    public var resultID: UUID
    public var generation: UUID
    public var status: Status
    public var parts: [BilingualRepairPart]
    public var failure: AudioProcessingError?
    /// User changes to a publication that has not reached durable history yet.
    /// Generated parts stay intact for diagnostics and later missing-part retry.
    public var pendingDocument: BilingualTranscriptDocument?
    public var recordingID: UUID { source.recordingID }
    public var completedCount: Int { parts.filter { $0.document != nil }.count }
    public var remainingParts: [BilingualRepairPart] { parts.filter { $0.document == nil } }
    public init(source: BilingualResult, configuration: AudioServiceConfiguration, maximumIntervalFrames: Int64? = nil) {
        id = UUID(); createdAt = Date(); self.source = source; self.configuration = configuration
        resultID = UUID(); generation = UUID(); status = .queued
        parts = source.document.source.missingIntervals.map { .init(channel: .source, interval: $0) }
            + source.document.translation.missingIntervals.map { .init(channel: .translation, interval: $0) }
        subdivideUnfinishedParts(maximumIntervalFrames: maximumIntervalFrames)
    }
    mutating func subdivideUnfinishedParts(maximumIntervalFrames: Int64?) {
        guard let maximumIntervalFrames, maximumIntervalFrames > 0 else { return }
        parts = parts.flatMap { part in
            guard part.document == nil, part.interval.isValid,
                  part.interval.endFrame - part.interval.startFrame > maximumIntervalFrames else { return [part] }
            var start = part.interval.startFrame
            var divided: [BilingualRepairPart] = []
            while start < part.interval.endFrame {
                let end = start + min(maximumIntervalFrames, part.interval.endFrame - start)
                divided.append(.init(channel: part.channel, interval: .init(startFrame: start, endFrame: end)))
                start = end
            }
            return divided
        }
    }
    /// A coarse live event is never used as an insertion/playback anchor. Keep
    /// the submitted text unchanged and append each repaired range explicitly.
    public var result: BilingualResult {
        var document = pendingDocument ?? source.document
        if pendingDocument == nil {
            for channel in BilingualChannel.allCases {
                let channelParts = parts.filter { $0.channel == channel }
                document.applyRepair(channel: channel,
                    additions: channelParts.filter { $0.document != nil }.sorted { $0.interval.startFrame < $1.interval.startFrame },
                    remaining: channelParts.filter { $0.document == nil }.map(\.interval))
            }
        }
        return .init(id: resultID, recordingID: recordingID, createdAt: createdAt,
                     configuration: configuration, direction: source.direction, document: document)
    }
}

extension BilingualTranscriptDocument {
    mutating func applyRepair(channel: BilingualChannel, additions: [BilingualRepairPart], remaining: [MissingInterval]) {
        guard !additions.isEmpty else { return }
        var updated = channel == .source ? source : translation
        var text = updated.text
        for part in additions {
            guard let fragment = part.document else { continue }
            if !text.isEmpty { text += "\n\n" }
            text += String(format: "[%.1f–%.1f s]\n", part.interval.start, part.interval.end) + fragment.text
        }
        _ = updated.replaceText(with: text)
        // The mutation itself is owned by the document; a repair task cannot
        // remove gaps from the other channel or claim absent text complete.
        replaceRepairedChannel(channel, document: .init(text: updated.text, missingIntervals: remaining))
    }
}
