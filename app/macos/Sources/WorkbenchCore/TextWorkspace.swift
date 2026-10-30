import Foundation

public enum TextTranslationStatus: String, Codable, Sendable {
    case generating, completed, failed, stopped, interrupted
}

public struct TextTranslationResult: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let input: String
    public let direction: TextTranslationDirection
    public let provider: ProviderSnapshot
    public var generatedText: String
    public var currentText: String
    public var status: TextTranslationStatus
    public var failure: TextTranslationError?
    public var usage: TextTranslationUsage?
    public var markdown: MarkdownDocument?
    public var markdownResponse: String?
    public let sourceWasAutomatic: Bool?
    public let resources: TranslationResourceSnapshot?
    public init(id: UUID = UUID(), createdAt: Date = Date(), input: String, direction: TextTranslationDirection, provider: ProviderSnapshot, markdown: MarkdownDocument? = nil, resources: TranslationResourceSnapshot? = nil, sourceWasAutomatic: Bool? = nil) {
        self.id = id; self.createdAt = createdAt; self.input = input; self.direction = direction; self.provider = provider
        self.markdown = markdown; self.resources = resources; self.sourceWasAutomatic = sourceWasAutomatic
        generatedText = markdown?.translated ?? ""; currentText = generatedText; status = .generating
    }
}

public struct TextWorkspace: Codable, Equatable, Sendable {
    public var updatedAt: Date = Date()
    public var isMarkdown: Bool = false
    public var importedFileName: String?
    public var importedMarkdown: Data?
    public var inputDraft = ""
    public var direction: TextTranslationDirection = .englishToChinese
    /// Missing in earlier libraries: their saved direction was chosen explicitly.
    public var sourceLanguageIsAutomatic: Bool? = true
    public var automaticallyDetectsSourceLanguage: Bool { sourceLanguageIsAutomatic == true }
    public var resourceSelection: TranslationResourceSelection?
    public var currentResult: TextTranslationResult?
    public var translationDraft = ""
    public init() {}
    public var translation: String { currentResult?.currentText ?? translationDraft }
    public var currentResultMatchesWorkspace: Bool {
        guard let result = currentResult else { return false }
        return result.direction == direction && (result.markdown != nil) == isMarkdown && result.input.utf8.elementsEqual(inputDraft.utf8)
    }
}

/// A submitted translation is retained independently from subsequent workspace edits.
public struct TextTranslationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var result: TextTranslationResult
    public let isMarkdown: Bool
    public let importedFileName: String?
    public let importedMarkdown: Data?
    public var id: UUID { result.id }
    public var createdAt: Date { result.createdAt }
    public var input: String { result.input }
    public var translation: String { result.currentText }
    public var title: String {
        let first = input.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? AppLanguage.current.text("未命名文本", "Untitled text") : String(first.prefix(60))
    }
    public init(result: TextTranslationResult, isMarkdown: Bool, importedFileName: String? = nil, importedMarkdown: Data? = nil) {
        self.result = result; self.isMarkdown = isMarkdown; self.importedFileName = importedFileName; self.importedMarkdown = importedMarkdown
    }
}

struct TextWorkspaceLibrary: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var workspace = TextWorkspace()
    var history: [TextTranslationHistoryEntry] = []
    var imports: [TextImportedCopy] = []
    var migratedLegacyIDs: [UUID] = []
}
struct TextImportedCopy: Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let bytes: Data
}

/// Read-only compatibility for the removed project and version storage.
struct LegacyTextMaterial: Decodable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let isMarkdown: Bool?
    let importedFileName: String?
    let importedMarkdown: Data?
    let inputDraft: String
    let direction: TextTranslationDirection
    let resourceSelection: TranslationResourceSelection?
    let currentResult: TextTranslationResult?
    let translationDraft: String?
    let results: [TextTranslationResult]?
    let selectedResultID: UUID?
    var selectedResult: TextTranslationResult? {
        schemaVersion == 1 ? results?.first { $0.id == selectedResultID } : currentResult
    }
    var workspace: TextWorkspace {
        var value = TextWorkspace()
        value.sourceLanguageIsAutomatic = false
        value.updatedAt = updatedAt; value.isMarkdown = isMarkdown == true
        value.importedFileName = importedFileName; value.importedMarkdown = importedMarkdown
        value.resourceSelection = resourceSelection; value.currentResult = selectedResult
        value.inputDraft = schemaVersion == 1 ? selectedResult?.input ?? inputDraft : inputDraft
        value.direction = schemaVersion == 1 ? selectedResult?.direction ?? direction : direction
        if schemaVersion == 1, let result = selectedResult { value.isMarkdown = result.markdown != nil }
        value.translationDraft = translationDraft ?? ""
        return value
    }
}
