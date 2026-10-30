import AVFoundation
import Combine
import CoreServices
import Foundation

@MainActor final class TextSystemTools: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    @Published private(set) var speechUnavailable = false
    @Published private(set) var dictionaryTerm = ""
    @Published private(set) var definition: String?
    @Published private(set) var lookupPending = false
    var formattedDefinition: String? { definition.map(DictionaryDefinitionLayout.format) }
    private let speech = AVSpeechSynthesizer()
    private var activeSpeech: ObjectIdentifier?
    private var lookupGeneration = UUID()
    override init() { super.init(); speech.delegate = self }
    func toggleSpeech(_ text: String, chinese: Bool) {
        toggleSpeech(text, languageCode: chinese ? "zh-Hans" : "en")
    }
    func toggleSpeech(_ text: String, languageCode: String) {
        if speaking { stop(); return }
        let prefix = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        guard !text.isEmpty, let voice = voices.first(where: { $0.language == languageCode }) ?? voices.first(where: { $0.language.hasPrefix(prefix + "-") || $0.language == prefix }) else {
            speechUnavailable = true; return
        }
        speechUnavailable = false
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        beginSpeech(utterance); speech.speak(utterance)
    }
    func beginSpeech(_ utterance: AVSpeechUtterance) { activeSpeech = ObjectIdentifier(utterance); speaking = true }
    func stop() { activeSpeech = nil; speech.stopSpeaking(at: .immediate); speaking = false }
    func reset() { stop(); lookupGeneration = UUID(); dictionaryTerm = ""; definition = nil; lookupPending = false; speechUnavailable = false }
    func lookup(_ selected: String) {
        let term = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term != dictionaryTerm, term.utf16.count <= 256 else { return }
        dictionaryTerm = term; definition = nil; lookupPending = true
        let token = UUID(); lookupGeneration = token
        Task {
            let value = await Task.detached(priority: .utility) {
                DCSCopyTextDefinition(nil, term as CFString, CFRange(location: 0, length: term.utf16.count))?.takeRetainedValue() as String?
            }.value
            if lookupGeneration == token { definition = value; lookupPending = false }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finishSpeech(ObjectIdentifier(utterance)) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finishSpeech(ObjectIdentifier(utterance)) }
    nonisolated private func finishSpeech(_ identity: ObjectIdentifier) {
        Task { @MainActor in
            guard activeSpeech == identity else { return }
            activeSpeech = nil; speaking = false
        }
    }
}

/// Adds presentation breaks without rewriting the system dictionary's wording.
/// Sequential sense numbers avoid splitting years, decimals and ordinary numbers.
enum DictionaryDefinitionLayout {
    static func format(_ definition: String) -> String {
        var value = definition
        if let sections = try? NSRegularExpression(pattern: #"[①-⑳]|(?<![A-Z]\. )(?<![\p{L}\p{N}])(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection)[ \t]+(?=[①1])"#) {
            value = insertingBreaks(value, at: sections.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { $0.range.location })
        }
        if let headings = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])([A-Z])\.[ \t]+"#) {
            let matches = headings.matches(in: value, range: NSRange(value.startIndex..., in: value))
            var expected: UInt32 = 65, boundaries: [Int] = []
            for match in matches {
                guard let range = Range(match.range(at: 1), in: value), value[range].unicodeScalars.first?.value == expected else { continue }
                boundaries.append(match.range.location); expected += 1
            }
            if boundaries.count >= 2 { value = insertingBreaks(value, at: boundaries) }
        }
        if let numbers = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}.])([1-9][0-9]?)(?:[.)、．](?![0-9])[ \t]*|[ \t]+)(?=\S)"#) {
            let matches = numbers.matches(in: value, range: NSRange(value.startIndex..., in: value))
            var sequences: [[NSTextCheckingResult]] = [], current: [NSTextCheckingResult] = []
            for match in matches {
                guard let range = Range(match.range(at: 1), in: value), let number = Int(value[range]) else { continue }
                if number == 1 {
                    if current.count >= 2 { sequences.append(current) }
                    current = [match]
                } else if number == current.count + 1, !current.isEmpty { current.append(match) }
            }
            if current.count >= 2 { sequences.append(current) }
            var boundaries: [Int] = []
            for sequence in sequences {
                let first = sequence[0]
                let marker = (value as NSString).substring(with: first.range)
                let prefix = (value as NSString).substring(to: first.range.location).trimmingCharacters(in: .whitespaces)
                let bareList = prefix.isEmpty || prefix.hasSuffix("\n") || prefix.range(of: #"(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection|n\.|v\.|adj\.|adv\.|释义|词义|名词|动词|形容词)$"#, options: .regularExpression) != nil
                if marker.rangeOfCharacter(from: CharacterSet(charactersIn: ".)、．")) != nil || bareList {
                    boundaries.append(contentsOf: sequence.map { $0.range.location })
                }
            }
            value = insertingBreaks(value, at: boundaries)
        }
        return value
    }
    private static func insertingBreaks(_ value: String, at boundaries: [Int]) -> String {
        let output = NSMutableString(string: value)
        for offset in boundaries.reversed() where offset > 0 {
            let prefix = output.substring(to: offset)
            if !prefix.trimmingCharacters(in: .whitespaces).hasSuffix("\n") { output.insert("\n", at: offset) }
        }
        return output as String
    }
}
