import Foundation
import WorkbenchCore

/// The SSE wire format is independent of network packet and UTF-8 character boundaries.
struct ChatEventStreamParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var afterCR = false
    private var firstLine = true
    private let maximumEventBytes = 1_048_576

    mutating func append(_ byte: UInt8) throws -> String? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 13 { afterCR = true; return try finishLine() }
        if byte == 10 { return try finishLine() }
        guard line.count < maximumEventBytes else { throw TextTranslationError.processing }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> String? {
        guard var value = String(data: line, encoding: .utf8) else { throw TextTranslationError.processing }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if value.hasPrefix("\u{feff}") { value.removeFirst() } }
        if value.isEmpty {
            let message = dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true); eventBytes = 0
            return message
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts[0] == "data" else { return nil }
        var data = parts.count == 2 ? String(parts[1]) : ""
        if data.hasPrefix(" ") { data.removeFirst() }
        eventBytes += data.utf8.count + 1
        guard eventBytes <= maximumEventBytes else { throw TextTranslationError.processing }
        dataLines.append(data)
        return nil
    }
}

struct ChatTranslationStream {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let index: Int
            let delta: Delta
            let finishReason: String?
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
        }
        let choices: [Choice]
        let usage: Usage?
    }
    private var stopped = false
    private var hasText = false
    private(set) var completed = false
    private(set) var terminalError: TextTranslationError?

    mutating func consume(_ message: String) throws -> [TextTranslationEvent] {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        if message == "[DONE]" {
            guard stopped && hasText else { throw TextTranslationError.processing }
            completed = true
            return []
        }
        if let error = ChatServiceFailure.streamError(Data(message.utf8)) { throw error }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(message.utf8)) else { throw TextTranslationError.processing }
        var events: [TextTranslationEvent] = []
        if let choice = chunk.choices.first(where: { $0.index == 0 }) {
            if let text = choice.delta.content, !text.isEmpty {
                guard !stopped else { throw TextTranslationError.processing }
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                events.append(.delta(text))
            }
            if let reason = choice.finishReason {
                if reason == "stop" { stopped = true }
                else {
                    terminalError = ["length", "aborted", "insufficient_system_resource"].contains(reason) ? .interrupted : .processing
                }
            }
        } else if !chunk.choices.isEmpty {
            throw TextTranslationError.processing
        }
        if let usage = chunk.usage {
            guard [usage.promptTokens, usage.completionTokens, usage.totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                throw TextTranslationError.processing
            }
            events.append(.usage(TextTranslationUsage(promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens, totalTokens: usage.totalTokens)))
        }
        return events
    }
}
