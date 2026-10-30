import Foundation

func coreMessage(_ chinese: String, _ english: String) -> String {
    AppLanguage.current.text(chinese, english)
}
