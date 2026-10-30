import Foundation

/// The fixed Gemini Live Translate wire. Text channels remain independent;
/// provider offsets never become original-media timing anchors here.
public struct GeminiLiveTranslationProtocol: Sendable {
    public let configuration: AudioServiceConfiguration
    public let direction: TextTranslationDirection
    private let connectionID = UUID()
    private var messageNumber: UInt64 = 0

    public init(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) throws {
        let value = try configuration.validated()
        guard value.provider == .gemini, value.model == "gemini-3.5-live-translate-preview",
              TranslationLanguageCatalog.live.supports(direction) else {
            throw AudioProcessingError.configuration
        }
        self.configuration = value; self.direction = direction
    }

    public var webSocketURL: URL { URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")! }
    public func setupMessage() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["setup": [
            "model": "models/" + configuration.model,
            "inputAudioTranscription": [:], "outputAudioTranscription": [:],
            "generationConfig": ["responseModalities": ["AUDIO"], "translationConfig": [
                "targetLanguageCode": direction.targetLanguage.rawValue,
                "echoTargetLanguage": false
            ]]
        ]])
    }
    public func audioMessage(_ pcm16: Data) throws -> Data {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2), pcm16.count <= 3200 else {
            throw AudioProcessingError.configuration
        }
        return try JSONSerialization.data(withJSONObject: ["realtimeInput": ["audio": [
            "data": pcm16.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"
        ]]])
    }
    public func finishInputMessage() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["realtimeInput": ["audioStreamEnd": true]])
    }

    public mutating func events(_ data: Data) throws -> [LiveBilingualTransportEvent] {
        guard data.count <= 16_777_216 else { throw AudioProcessingError.processing }
        let message: Message
        do { message = try JSONDecoder().decode(Message.self, from: data) }
        catch { throw AudioProcessingError.processing }
        if let failure = message.error {
            switch failure.code {
            case 400: throw AudioProcessingError.configuration
            case 401, 403: throw AudioProcessingError.credential
            case 404: throw AudioProcessingError.modelUnavailable
            case 429: throw AudioProcessingError.rateLimited
            case 500...599: throw AudioProcessingError.unavailable
            default: throw AudioProcessingError.processing
            }
        }
        guard messageNumber < UInt64.max else { throw AudioProcessingError.processing }
        messageNumber += 1
        var result: [LiveBilingualTransportEvent] = []
        if message.setupComplete != nil { result.append(.configured) }
        if let content = message.serverContent {
            for (channel, transcript) in [(BilingualChannel.source, content.inputTranscription), (.translation, content.outputTranscription)] {
                guard let transcript else { continue }
                let start = try Self.duration(transcript.startOffset), end = try Self.duration(transcript.endOffset)
                guard start == nil || end == nil || end! >= start! else { throw AudioProcessingError.processing }
                result.append(.text(channel: channel, eventID: "\(connectionID):\(messageNumber):\(channel.rawValue)",
                                    delta: transcript.text ?? "", startOffset: start, endOffset: end, finished: transcript.finished))
            }
            for part in content.modelTurn?.parts ?? [] {
                guard let audio = part.inlineData, audio.mimeType.hasPrefix("audio/") else { continue }
                guard let bytes = Data(base64Encoded: audio.data) else { throw AudioProcessingError.processing }
                result.append(.audioDiscarded(byteCount: bytes.count))
            }
            if content.turnComplete == true { result.append(.turnComplete) }
            if content.generationComplete == true { result.append(.generationComplete) }
            if content.interrupted == true { result.append(.interrupted) }
            if let raw = content.interactionStatus, let status = LiveBilingualInteractionStatus(rawValue: raw) {
                result.append(.interactionStatus(status))
            }
        }
        if let away = message.goAway { result.append(.goAway(timeLeft: try Self.duration(away.timeLeft))) }
        if let usage = message.usageMetadata { result.append(.usage(usage.value)) }
        return result
    }

    private static func duration(_ value: String?) throws -> TimeInterval? {
        guard let value else { return nil }
        guard value.range(of: #"^[0-9]+(\.[0-9]{1,9})?s$"#, options: .regularExpression) != nil,
              let seconds = Double(value.dropLast()), seconds.isFinite, seconds >= 0 else { throw AudioProcessingError.processing }
        return seconds
    }
    private struct Message: Decodable {
        let serverContent: Content?; let setupComplete: Empty?; let goAway: GoAway?
        let usageMetadata: Usage?; let error: Failure?
    }
    private struct Empty: Decodable {}
    private struct Failure: Decodable { let code: Int }
    private struct GoAway: Decodable { let timeLeft: String? }
    private struct Content: Decodable {
        let inputTranscription: Transcription?; let outputTranscription: Transcription?
        let modelTurn: Turn?; let turnComplete: Bool?; let generationComplete: Bool?
        let interrupted: Bool?; let interactionStatus: String?
    }
    private struct Turn: Decodable { let parts: [Part]? }
    private struct Part: Decodable { let inlineData: InlineData? }
    private struct InlineData: Decodable { let mimeType: String; let data: String }
    private struct Transcription: Decodable {
        let text: String?; let startOffset: String?; let endOffset: String?; let finished: Bool?
    }
    private struct Usage: Decodable {
        let value: LiveBilingualUsage
        private enum Key: String, CodingKey, CaseIterable {
            case promptTokenCount, cachedContentTokenCount, responseTokenCount, toolUsePromptTokenCount, thoughtsTokenCount, totalTokenCount
            case promptTokensDetails, cacheTokensDetails, responseTokensDetails, toolUsePromptTokensDetails
        }
        private struct ModalityCount: Decodable { let modality: String; let tokenCount: Int }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var counts: [String: Int] = [:], modalities: [String: [String: Int]] = [:]
            for key in Key.allCases {
                if key.rawValue.hasSuffix("Count") {
                    if let count = try container.decodeIfPresent(Int.self, forKey: key) {
                        guard count >= 0 else { throw AudioProcessingError.processing }
                        counts[key.rawValue] = count
                    }
                } else if let details = try container.decodeIfPresent([ModalityCount].self, forKey: key) {
                    var values: [String: Int] = [:]
                    for detail in details {
                        guard detail.tokenCount >= 0 else { throw AudioProcessingError.processing }
                        guard ["MODALITY_UNSPECIFIED", "TEXT", "IMAGE", "VIDEO", "AUDIO", "DOCUMENT"].contains(detail.modality) else { continue }
                        guard values[detail.modality] == nil else { throw AudioProcessingError.processing }
                        values[detail.modality] = detail.tokenCount
                    }
                    modalities[key.rawValue] = values
                }
            }
            value = LiveBilingualUsage(tokenCounts: counts, modalityTokenCounts: modalities)
        }
    }
}
