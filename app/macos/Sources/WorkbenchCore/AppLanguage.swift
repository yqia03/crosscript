import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans, english

    public var id: String { rawValue }

    public init(preference: String) {
        self = Self(rawValue: preference) ?? .system
    }

    public static var current: Self {
        Self(preference: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system")
    }

    public var isChinese: Bool {
        switch self {
        case .zhHans: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    public func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}
