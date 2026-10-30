import Foundation

public struct TranslationLanguage: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) {
        let parts = rawValue.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        let normalized = parts.enumerated().map { index, part in
            index == 0 ? part.lowercased() : (part.count == 2 ? part.uppercased() : part.prefix(1).uppercased() + part.dropFirst().lowercased())
        }.joined(separator: "-")
        self.rawValue = ["zh", "zh-CN"].contains(normalized) ? "zh-Hans" : normalized
    }
    public static let english = Self(rawValue: "en")
    public static let simplifiedChinese = Self(rawValue: "zh-Hans")
    public var isValid: Bool {
        rawValue.count <= 35 && rawValue.range(of: #"^[a-z]{2,8}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }
    public func title(_ language: AppLanguage) -> String {
        if rawValue == "zh-Hans" { return language.text("简体中文", "Simplified Chinese") }
        if rawValue == "zh-Hant" { return language.text("繁体中文", "Traditional Chinese") }
        return Locale(identifier: language.isChinese ? "zh-Hans" : "en").localizedString(forIdentifier: rawValue) ?? rawValue
    }
    public var englishName: String { title(.english) }
    public var babelDOCCode: String {
        switch rawValue {
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh-TW"
        case "fil": return "tl"
        case "pt-PT": return "pt"
        case "nb": return "no"
        default: return rawValue
        }
    }
    public var exportCode: String {
        switch rawValue {
        case "zh-Hans": return "cn"
        case "zh-Hant", "zh-TW": return "tw"
        case "zh-HK": return "hk"
        default: return rawValue
        }
    }
    public func matchesGlossaryCode(_ code: String) -> Bool {
        let other = Self(rawValue: code)
        return other == self || other.babelDOCCode.lowercased() == babelDOCCode.lowercased()
    }
}

public enum TranslationLanguageCatalog: Equatable, Sendable {
    case text, pdf, live
    public var languages: [TranslationLanguage] {
        switch self {
        case .text: return Self.textLanguages
        case .pdf: return Self.pdfLanguages
        case .live: return Self.liveLanguages
        }
    }
    public func supports(_ direction: TextTranslationDirection) -> Bool {
        guard direction.sourceLanguage.isValid, direction.targetLanguage.isValid else { return false }
        if case .text = self { return true }
        let codes = Set(languages.map { self == .pdf ? $0.babelDOCCode : $0.rawValue })
        return [direction.sourceLanguage, direction.targetLanguage].allSatisfy {
            codes.contains(self == .pdf ? $0.babelDOCCode : $0.rawValue)
        }
    }
    // DeepSeek publishes no exhaustive translation-language allowlist. Common
    // ISO languages are conveniences, with custom BCP-47 input supported too.
    private static let textLanguages = ordered(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 } + ["zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "pt-BR", "pt-PT", "fil"])
    // Gemini Live Translate's published BCP-47 table, checked 2026-10-20:
    // https://ai.google.dev/gemini-api/docs/live-api/live-translate
    private static let liveLanguages = ordered("""
    af ak sq am ar hy az eu be bn bg my ca zh-Hans zh-Hant hr cs da nl en et fil fi fr gl ka de el gu ha he hi hu is id it ja jv kn kk km rw ko lo lv lt mk ms ml mr mn ne no nb fa pl pt-BR pt-PT pa ro ru sr sd si sk sl es su sw sv ta te th tr uk ur uz vi zu
    """.split(separator: " ").map(String.init))
    // The installed BabelDOC release's own language table, including its
    // partial-ligature languages. Unsupported shaping systems are excluded.
    // https://github.com/funstory-ai/BabelDOC/blob/v0.6.4/docs/supported_languages.md
    private static let pdfLanguages = ordered("""
    en zh-Hans zh-HK zh-TW ja ko pl ru es pt fr ms id tk tl vi kk de nl ga it el sv da no is fi uk cs ro hu sk hr et lv lt be mk sq sr sl ca bg mt sw am om ti ht la lo ml gu th my ta te or hy mn ka km bs lb rm tr si uz ky tg ab aa af ak an av ee ay oj oc os pi ba eu br ch ce cv tn nr ng fo fj fy lg kg kl cu gn ia hz ki rn rw gl kr kw kv xh co cr qu ku kj li ln gv mg mh mi nv na ny nn sc se sm sg sn eo gd so st tt ty to tw wa cy ve vo ie ho ig io iu ik ii yo za ts zu pt-BR
    """.split(separator: " ").map(String.init))
    private static func ordered(_ codes: [String]) -> [TranslationLanguage] {
        let preferred = ["en", "zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "ja", "ko", "fr", "de", "es"]
        let unique = Set(codes.map { TranslationLanguage(rawValue: $0) })
        return unique.sorted {
            let first = preferred.firstIndex(of: $0.rawValue) ?? preferred.count
            let second = preferred.firstIndex(of: $1.rawValue) ?? preferred.count
            return first == second ? $0.englishName < $1.englishName : first < second
        }
    }
}
