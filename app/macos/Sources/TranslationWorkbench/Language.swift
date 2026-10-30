import Foundation
import WorkbenchCore

extension AppLanguage {
    func title(using language: WorkbenchLanguage) -> String {
        switch self {
        case .system: return language.text("跟随系统", "System")
        case .zhHans: return "简体中文"
        case .english: return "English"
        }
    }
}

struct WorkbenchLanguage {
    let choice: AppLanguage
    var isChinese: Bool { choice.isChinese }
    var locale: Locale { Locale(identifier: isChinese ? "zh_Hans" : "en") }
    func text(_ chinese: String, _ english: String) -> String { choice.text(chinese, english) }
    func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
