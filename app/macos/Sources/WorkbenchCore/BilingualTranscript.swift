import Foundation

public enum BilingualChannel: String, Codable, CaseIterable, Sendable { case source, translation }

/// Alignment metadata belongs to one event, not a paired sentence. The service
/// may emit several deltas at the same elapsed time or omit timing altogether.
public struct BilingualAlignment: Codable, Equatable, Sendable {
    public let eventID: String
    public let channel: BilingualChannel
    public let elapsedMilliseconds: Double?
    public let connectionStartFrame: Int64
    public let range: TranscriptTextRange
}

public struct BilingualTranscriptDocument: Codable, Equatable, Sendable {
    public private(set) var source = TranscriptDocument(text: "")
    public private(set) var translation = TranscriptDocument(text: "")
    public private(set) var alignment: [BilingualAlignment] = []
    public private(set) var receivedEventIDs: Set<String> = []
    public private(set) var isFinished = false
    public private(set) var completedChannels: Set<BilingualChannel> = []
    public init() {}
    public var isComplete: Bool {
        isFinished && completedChannels.count == 2 && !source.text.isEmpty && !translation.text.isEmpty &&
        source.missingIntervals.isEmpty && translation.missingIntervals.isEmpty
    }
    public func text(_ channel: BilingualChannel) -> String { channel == .source ? source.text : translation.text }
    public mutating func append(_ text: String, channel: BilingualChannel, eventID: String,
                                elapsedMilliseconds: Double?, connectionStartFrame: Int64) {
        guard !isFinished, !eventID.isEmpty, connectionStartFrame >= 0,
              !receivedEventIDs.contains(eventID) else { return }
        receivedEventIDs.insert(eventID)
        let original = channel == .source ? source : translation
        let document = TranscriptDocument(text: original.text + text, missingIntervals: original.missingIntervals)
        if channel == .source { source = document } else { translation = document }
        let elapsed = elapsedMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        alignment.append(.init(eventID: eventID, channel: channel, elapsedMilliseconds: elapsed,
            connectionStartFrame: connectionStartFrame,
            range: .init(location: original.text.utf16.count, length: text.utf16.count)))
    }
    public mutating func addMissing(_ intervals: [MissingInterval], channel: BilingualChannel) {
        let current = channel == .source ? source : translation
        let next = TranscriptDocument(text: current.text, missingIntervals: current.missingIntervals + intervals)
        if channel == .source { source = next } else { translation = next }
    }
    public mutating func finish(completedChannels: Set<BilingualChannel> = Set(BilingualChannel.allCases)) {
        isFinished = true
        self.completedChannels = completedChannels.filter {
            let value = $0 == .source ? source : translation
            return !value.text.isEmpty && value.missingIntervals.isEmpty
        }
    }
    public mutating func edit(_ text: String, channel: BilingualChannel) {
        // Editing a finished version cannot be overwritten by a late delta, and
        // no source-range alignment is retained for text the user has rewritten.
        guard isFinished else { return }
        if channel == .source { _ = source.replaceText(with: text) }
        else { _ = translation.replaceText(with: text) }
        alignment.removeAll { $0.channel == channel }
    }
    mutating func replaceRepairedChannel(_ channel: BilingualChannel, document: TranscriptDocument) {
        guard isFinished else { return }
        if channel == .source { source = document } else { translation = document }
        alignment.removeAll { $0.channel == channel }
        if !document.text.isEmpty && document.missingIntervals.isEmpty { completedChannels.insert(channel) }
        else { completedChannels.remove(channel) }
    }
    public func exported(channels: Set<BilingualChannel> = Set(BilingualChannel.allCases)) -> String {
        BilingualChannel.allCases.filter(channels.contains).map { text($0) }.joined(separator: "\n\n")
    }
}

public struct BilingualResult: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let createdAt: Date
    public let configuration: AudioServiceConfiguration
    public let direction: TextTranslationDirection
    public var document: BilingualTranscriptDocument
    public init(id: UUID = UUID(), recordingID: UUID, createdAt: Date = Date(),
                configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                document: BilingualTranscriptDocument) {
        self.id = id; self.recordingID = recordingID; self.createdAt = createdAt
        self.configuration = configuration; self.direction = direction; self.document = document
    }
}

/// Availability and evidence are separate: Gemini has retained real short-session
/// and English-tail evidence; the current local release explicitly waives new
/// upload checks and retains language-quality and long-session limitations.
public enum LiveBilingualCapability: Equatable, Sendable {
    case availableWithLimitations, documentedButUnverified, unavailable
    public static func forConfiguration(_ value: AudioServiceConfiguration) -> Self {
        guard let configuration = try? value.validated() else { return .unavailable }
        if configuration == AudioServiceConfiguration(provider: .gemini) { return .availableWithLimitations }
        if configuration.provider == .openAI, configuration.model == "gpt-realtime-translate" { return .documentedButUnverified }
        return .unavailable
    }
    public var canStart: Bool { self == .availableWithLimitations }
}
