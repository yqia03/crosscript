import Foundation
import WorkbenchCore

/// A requested non-streaming response has a different envelope from SSE.
/// Only assistant content is user-visible; reasoning and raw error messages are ignored.
struct ChatTranslationCompletion {
    let events: [TextTranslationEvent]
    let terminalError: TextTranslationError?
    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let index: Int
            let message: Message
            let finishReason: String
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
        }
        let choices: [Choice]
        let usage: Usage?
    }
    init(data: Data) throws {
        if let error = ChatServiceFailure.streamError(data) { throw error }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(Envelope.self, from: data), value.choices.count == 1,
              let choice = value.choices.first, choice.index == 0,
              let text = choice.message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextTranslationError.processing
        }
        var events: [TextTranslationEvent] = [.delta(text)]
        if let usage = value.usage {
            guard [usage.promptTokens, usage.completionTokens, usage.totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                throw TextTranslationError.processing
            }
            events.append(.usage(.init(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, totalTokens: usage.totalTokens)))
        }
        self.events = events
        if choice.finishReason == "stop" { terminalError = nil }
        else { terminalError = ["length", "aborted", "insufficient_system_resource"].contains(choice.finishReason) ? .interrupted : .processing }
    }
}
