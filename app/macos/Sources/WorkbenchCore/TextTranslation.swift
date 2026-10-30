import Foundation

public struct TextTranslationDirection: RawRepresentable, Codable, Hashable, Sendable {
    public let sourceLanguage: TranslationLanguage
    public let targetLanguage: TranslationLanguage
    public init(sourceLanguage: TranslationLanguage, targetLanguage: TranslationLanguage) {
        self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
    }
    public static let englishToChinese = Self(sourceLanguage: .english, targetLanguage: .simplifiedChinese)
    public static let chineseToEnglish = Self(sourceLanguage: .simplifiedChinese, targetLanguage: .english)
    /// Original directions retained for compatibility with existing clients.
    public static let allCases: [Self] = [.englishToChinese, .chineseToEnglish]
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceLanguage == rhs.sourceLanguage && lhs.targetLanguage == rhs.targetLanguage
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceLanguage); hasher.combine(targetLanguage)
    }
    public var reversed: Self { .init(sourceLanguage: targetLanguage, targetLanguage: sourceLanguage) }
    public var rawValue: String {
        if self == .englishToChinese { return "englishToChinese" }
        if self == .chineseToEnglish { return "chineseToEnglish" }
        return sourceLanguage.rawValue + ">" + targetLanguage.rawValue
    }
    public init?(rawValue: String) {
        if rawValue == "englishToChinese" { self = .englishToChinese; return }
        if rawValue == "chineseToEnglish" { self = .chineseToEnglish; return }
        let parts = rawValue.split(separator: ">", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let source = TranslationLanguage(rawValue: String(parts[0])), target = TranslationLanguage(rawValue: String(parts[1]))
        guard source.isValid, target.isValid else { return nil }
        self.init(sourceLanguage: source, targetLanguage: target)
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let direction = Self(rawValue: try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid translation language pair")
        }
        self = direction
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(rawValue)
    }
    public func title(_ language: AppLanguage) -> String { sourceLanguage.title(language) + " → " + targetLanguage.title(language) }
}

public struct TextTranslationRequest: Equatable, Sendable {
    public let input: String
    public let direction: TextTranslationDirection
    public let provider: ProviderSnapshot
    public let responseContract: String?
    public let resources: TranslationResourceSnapshot?
    public init(input: String, direction: TextTranslationDirection, provider: ProviderSnapshot, responseContract: String? = nil, resources: TranslationResourceSnapshot? = nil) {
        self.input = input; self.direction = direction; self.provider = provider; self.responseContract = responseContract; self.resources = resources
    }
}

public struct TextTranslationUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.totalTokens = totalTokens
    }
}

public enum TextTranslationEvent: Equatable, Sendable {
    case delta(String)
    case usage(TextTranslationUsage)
}

/// Returning normally means the provider completed the response successfully.
/// An incomplete or invalid stream throws after emitting any valid partial text.
public protocol TextTranslating: Sendable {
    func translate(_ request: TextTranslationRequest, apiKey: String,
                   onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws
}

public enum TextTranslationError: String, Error, Codable, Sendable {
    case configuration, credential, modelUnavailable, rateLimited, network, processing, storage, interrupted, emptyInput, structure, resources, languageUndetermined
}
