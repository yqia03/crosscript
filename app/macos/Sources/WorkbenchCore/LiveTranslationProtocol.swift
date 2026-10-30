import Foundation

public enum LiveTranslationEvent: Equatable, Sendable {
    case configured
    case text(channel: BilingualChannel, eventID: String, delta: String, elapsedMilliseconds: Double?)
    case closed
    case failed
    case ignored
}

/// Dedicated official translation protocol. It deliberately accepts neither the
/// conversation protocol nor a compatible endpoint whose capability is unknown.
public struct LiveTranslationProtocol: Sendable {
    public let configuration: AudioServiceConfiguration
    public let direction: TextTranslationDirection
    public init(configuration: AudioServiceConfiguration, direction: TextTranslationDirection) throws {
        let value = try configuration.validated()
        guard value.provider == .openAI, value.model == "gpt-realtime-translate",
              TextTranslationDirection.allCases.contains(direction) else { throw AudioProcessingError.configuration }
        self.configuration = value; self.direction = direction
    }
    public var webSocketURL: URL { URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")! }
    public func configurationMessage() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "session.update", "session": ["audio": [
            "input": ["transcription": ["model": "gpt-4o-transcribe"]],
            "output": ["language": direction == .englishToChinese ? "zh" : "en"]]]])
    }
    public func audioMessage(_ chunk: LiveAudioChunk) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "session.input_audio_buffer.append", "audio": chunk.pcm16.base64EncodedString()])
    }
    public func closeMessage() throws -> Data { try JSONSerialization.data(withJSONObject: ["type": "session.close"]) }
    public func event(_ data: Data) throws -> LiveTranslationEvent {
        guard data.count <= 16_777_216,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else {
            throw AudioProcessingError.processing
        }
        switch type {
        case "session.updated": return .configured
        case "session.closed": return .closed
        case "error": return .failed
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let id = object["event_id"] as? String, !id.isEmpty,
                  let delta = object["delta"] as? String else { throw AudioProcessingError.processing }
            let elapsed = object["elapsed_ms"] as? Double
            guard object["elapsed_ms"] == nil || elapsed != nil else { throw AudioProcessingError.processing }
            guard elapsed == nil || (elapsed!.isFinite && elapsed! >= 0) else { throw AudioProcessingError.processing }
            return .text(channel: type == "session.input_transcript.delta" ? .source : .translation,
                         eventID: id, delta: delta, elapsedMilliseconds: elapsed)
        default: return .ignored // Output audio is intentionally never played.
        }
    }
}
