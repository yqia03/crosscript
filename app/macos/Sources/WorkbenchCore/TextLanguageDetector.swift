import Foundation
import NaturalLanguage

/// Returns a concrete local language, or nil when there is insufficient evidence.
public protocol TextLanguageDetecting: Sendable {
    func detectLanguage(in text: String) -> TranslationLanguage?
}

public struct TextLanguageDetector: TextLanguageDetecting {
    public init() {}
    public func detectLanguage(in text: String) -> TranslationLanguage? {
        let sample = String(text.prefix(16_000)).replacingOccurrences(of: #"https?://\S+|www\.\S+|\S+@\S+\.\S+"#, with: " ", options: .regularExpression)
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let han = letters.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let latin = letters.filter { (0x0041...0x007A).contains($0.value) }.count
        guard letters.count >= 5 || han >= 2 else { return nil }
        // Very short mixed strings do not establish a trustworthy direction.
        guard letters.count >= 20 || han == 0 || latin == 0 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        // Script variants compete in NaturalLanguage's distribution. They are
        // evidence for the same source language, not independent alternatives.
        var families: [String: (language: NLLanguage, probability: Double, bestVariant: Double)] = [:]
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 8) where language != .undetermined {
            let base = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
            if var family = families[base] {
                family.probability += probability
                if probability > family.bestVariant { family.language = language; family.bestVariant = probability }
                families[base] = family
            } else { families[base] = (language, probability, probability) }
        }
        let groups = families.values.sorted { $0.probability > $1.probability }
        guard let best = groups.first, best.probability >= 0.70,
              best.probability - (groups.dropFirst().first?.probability ?? 0) >= 0.20 else { return nil }
        let language = TranslationLanguage(rawValue: best.language.rawValue)
        return language.isValid ? language : nil
    }
}
