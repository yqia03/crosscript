import Combine
import Foundation

public struct TranslationTerm: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var targetLanguage: String?
    public init(source: String, target: String, targetLanguage: String? = nil) {
        self.source = source; self.target = target; self.targetLanguage = targetLanguage
    }
}

public struct TranslationGlossary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [TranslationTerm]
    public init(id: UUID = UUID(), name: String, entries: [TranslationTerm]) {
        self.id = id; self.name = name; self.entries = entries
    }
    public var csv: String {
        ([ ["source", "target", "tgt_lng"] ] + entries.map { [$0.source, $0.target, $0.targetLanguage ?? ""] })
            .map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }
    public static func importCSV(_ text: String, name: String) throws -> Self {
        let rows = try GlossaryCSV.parse(text)
        guard let header = rows.first, Set(header).count == header.count,
              let source = header.firstIndex(of: "source"), let target = header.firstIndex(of: "target"),
              Set(header).isSubset(of: ["source", "target", "tgt_lng"]) else { throw TranslationResourceError.invalidCSV }
        let language = header.firstIndex(of: "tgt_lng")
        let entries = try rows.dropFirst().filter { $0.contains(where: { !$0.isEmpty }) }.map { row -> TranslationTerm in
            guard row.count == header.count else { throw TranslationResourceError.invalidCSV }
            let value = language.map { row[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            return TranslationTerm(source: row[source], target: row[target], targetLanguage: value)
        }
        let glossary = Self(name: name, entries: entries)
        try glossary.validate()
        return glossary
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120, entries.count <= 10_000 else {
            throw TranslationResourceError.invalidInput
        }
        for entry in entries {
            guard !entry.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.source.count <= 2000, entry.target.count <= 4000,
                  entry.targetLanguage.map({ value in
                      !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
                          CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
                      }
                  }) ?? true else {
                throw TranslationResourceError.invalidInput
            }
        }
    }
}

public struct TranslationPromptPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var instruction: String
    public let isBuiltIn: Bool
    public init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id; self.name = name; self.instruction = instruction; isBuiltIn = false
    }
    private init(id: UUID, name: String, instruction: String, builtIn: Bool) {
        self.id = id; self.name = name; self.instruction = instruction; isBuiltIn = builtIn
    }
    public static let builtIns: [Self] = [
        .init(id: UUID(uuidString: "FB281F2C-C436-4CB1-8744-ED2E81762A20")!, name: "准确翻译 / Faithful translation",
            instruction: "Translate faithfully and clearly. Preserve the meaning, technical detail, names and numerical values. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "8477F4DA-FAB5-433C-A2A3-209413F17486")!, name: "学术阅读 / Academic reading",
            instruction: "Translate for academic reading. Use precise terminology and clear prose. Preserve citations, qualifications and the author's degree of certainty. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "CD640ADC-93FC-42BF-B60D-8883DF8151D1")!, name: "学术论文 / Research papers",
            instruction: "Translate research papers in a formal scholarly register. Preserve the research question, methods, results, limitations, statistical notation, citations and distinctions between correlation and causation. Keep technical terms consistent and never strengthen the claims. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "90B03CD9-765A-497B-94BD-14F1B9294F11")!, name: "技术文档 / Technical documentation",
            instruction: "Translate technical documentation with precise, consistent terminology and clear procedural wording. Preserve API names, identifiers, commands, code, paths, placeholders, units, version numbers and Markdown structure. Distinguish requirements, recommendations and optional steps. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "74CECC9F-88CE-4402-A777-C235E81CFD58")!, name: "商务邮件 / Business email",
            instruction: "Translate business email in a professional, courteous and natural tone. Preserve the sender's intent, requests, commitments, degree of urgency, names, dates, amounts, greeting and sign-off. Do not add promises or omit conditions. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "A5F4C9FA-2B25-407B-A711-E4A1E6B63E14")!, name: "日常交流 / Everyday conversation",
            instruction: "Translate everyday conversation into natural, idiomatic language suited to the original relationship and level of formality. Preserve intent, emotion, politeness, humor and concise conversational rhythm. Do not add explanations or invent context. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "62822E08-4349-4FAE-9ACD-4A21E16A1B2D")!, name: "文学作品 / Literature",
            instruction: "Translate literary prose with attention to the author's voice, imagery, rhythm, point of view and character dialogue. Preserve ambiguity, cultural references and emotional nuance without inventing plot details or explanatory additions. Keep paragraph structure. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "6319B4DA-E7B8-4BB8-BEAA-5A8520559DF6")!, name: "法律与合同 / Legal and contracts",
            instruction: "Translate legal documents and contracts with precise, consistent defined terms. Preserve clause numbering, cross-references, parties, obligations, permissions, prohibitions, exceptions, deadlines and jurisdiction-specific distinctions. Do not simplify away legal qualifications, resolve ambiguity or add legal advice. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "D57CD48A-21C2-49A7-B017-79A470620F36")!, name: "新闻报道 / News reporting",
            instruction: "Translate news reporting in clear, neutral prose. Preserve attribution, quotations, chronology, names, figures and distinctions between confirmed facts, allegations and opinion. Keep the source's emphasis without sensationalizing or adding background. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "11EB3E0E-0438-4318-B908-AAC532F57F72")!, name: "市场营销 / Marketing copy",
            instruction: "Translate marketing copy into fluent, engaging language appropriate to the original audience and brand voice. Adapt idioms while preserving product facts, benefits, calls to action, prices and disclaimers. Do not invent features, guarantees or claims. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "EBFAE25E-1C8F-4482-B96A-2B5569DE6DA5")!, name: "软件界面 / Software interface",
            instruction: "Translate software interface strings using concise, consistent and action-oriented language. Preserve placeholders, interpolation tokens, markup, keyboard shortcuts and product names exactly. Keep labels and messages appropriate to their original function without inventing UI context. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "A998B0A7-3F80-4C76-9A2F-46C2E569C4EF")!, name: "教学材料 / Learning materials",
            instruction: "Translate learning materials in clear language appropriate to the source's level. Preserve definitions, examples, instructions, question numbering, equations and distinctions between concepts. Keep established subject terminology consistent and do not solve exercises or add explanations absent from the source. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "0359D040-1D9E-44D0-9DD3-A1D62BED1CA0")!, name: "字幕与对白 / Subtitles and dialogue",
            instruction: "Translate subtitles and dialogue naturally and concisely while preserving meaning, speaker voice, emotional tone and turn order. Preserve subtitle numbering, timestamps and segment boundaries exactly. Do not merge cues, invent speakers or add commentary. Return only the translation.", builtIn: true),
        .init(id: UUID(uuidString: "3E237168-7154-4F52-814A-072BCF1C2518")!, name: "财务报告 / Financial reporting",
            instruction: "Translate financial reports with consistent accounting terminology. Preserve currencies, amounts, percentages, dates, reporting periods, table structure, footnotes and risk qualifications. Distinguish actual results, forecasts and estimates without adding investment advice or changing numerical precision. Return only the translation.", builtIn: true),
    ]
    /// Keep serialized names stable for task snapshots and localize only their
    /// presentation. User-defined names always remain exactly as entered.
    public func displayName(_ language: AppLanguage) -> String {
        guard isBuiltIn else { return name }
        let parts = name.components(separatedBy: " / ")
        guard parts.count == 2 else { return name }
        return language.text(parts[0], parts[1])
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instruction.count <= 20_000,
              !isBuiltIn, !Self.builtIns.contains(where: { $0.id == id }) else { throw TranslationResourceError.invalidInput }
    }
}

public struct TranslationResourceSelection: Codable, Equatable, Sendable {
    public var glossaryIDs: [UUID]
    public var promptID: UUID?
    public init(glossaryIDs: [UUID] = [], promptID: UUID? = nil) { self.glossaryIDs = glossaryIDs; self.promptID = promptID }
}

/// A value snapshot travels with a submitted task, so future library edits and
/// deletion cannot rewrite its instructions or terminology.
public struct TranslationResourceSnapshot: Codable, Equatable, Sendable {
    public let glossaries: [TranslationGlossary]
    public let prompt: TranslationPromptPreset?
    public init(glossaries: [TranslationGlossary] = [], prompt: TranslationPromptPreset? = nil) {
        self.glossaries = glossaries; self.prompt = prompt
    }
    public func validated() throws -> Self {
        guard Set(glossaries.map(\.id)).count == glossaries.count else { throw TranslationResourceError.invalidInput }
        for glossary in glossaries { try glossary.validate() }
        if let prompt {
            if prompt.isBuiltIn {
                guard TranslationPromptPreset.builtIns.contains(prompt) else { throw TranslationResourceError.invalidInput }
            } else { try prompt.validate() }
        }
        return self
    }
    public func terms(for direction: TextTranslationDirection) -> [TranslationTerm] {
        return glossaries.flatMap(\.entries).filter {
            guard let code = $0.targetLanguage else { return true }
            return direction.targetLanguage.matchesGlossaryCode(code)
        }
    }
}

public enum TranslationResourceError: String, Error { case invalidInput, invalidCSV, storage, unavailable }

private struct TranslationResourceDocument: Codable {
    var version = 1
    var glossaries: [TranslationGlossary] = []
    var prompts: [TranslationPromptPreset] = []
    var text = TranslationResourceSelection()
    var pdf = TranslationResourceSelection()
}

@MainActor public final class TranslationResourceLibrary: ObservableObject {
    @Published public private(set) var glossaries: [TranslationGlossary] = []
    @Published public private(set) var customPrompts: [TranslationPromptPreset] = []
    @Published public private(set) var error: TranslationResourceError?
    @Published public private(set) var needsSave = false
    public var prompts: [TranslationPromptPreset] { TranslationPromptPreset.builtIns + customPrompts }
    private var document = TranslationResourceDocument()
    private let root: URL
    private var readable = true
    public init(root: URL) {
        self.root = Self.canonical(root)
        do {
            let file = try location()
            if FileManager.default.fileExists(atPath: file.path) {
                document = try JSONDecoder().decode(TranslationResourceDocument.self, from: Data(contentsOf: file))
                try validate(document)
            }
            publish()
        } catch { readable = false; self.error = .storage }
    }
    public func selection(for use: ProviderUse) -> TranslationResourceSelection { use == .text ? document.text : document.pdf }
    public func snapshot(_ selection: TranslationResourceSelection) throws -> TranslationResourceSnapshot {
        guard readable, !needsSave, Set(selection.glossaryIDs).count == selection.glossaryIDs.count else { throw TranslationResourceError.unavailable }
        let selected = try selection.glossaryIDs.map { id -> TranslationGlossary in
            guard let item = glossaries.first(where: { $0.id == id }) else { throw TranslationResourceError.unavailable }; return item
        }
        let prompt = selection.promptID.flatMap { id in prompts.first { $0.id == id } }
        guard selection.promptID == nil || prompt != nil else { throw TranslationResourceError.unavailable }
        return .init(glossaries: selected, prompt: prompt)
    }
    @discardableResult public func saveGlossary(_ glossary: TranslationGlossary) -> Bool {
        do { try glossary.validate() } catch { self.error = .invalidInput; return false }
        var next = document
        if let index = next.glossaries.firstIndex(where: { $0.id == glossary.id }) { next.glossaries[index] = glossary }
        else { next.glossaries.append(glossary) }
        return save(next)
    }
    @discardableResult public func savePrompt(_ prompt: TranslationPromptPreset) -> Bool {
        do { try prompt.validate() } catch { self.error = .invalidInput; return false }
        var next = document
        if let index = next.prompts.firstIndex(where: { $0.id == prompt.id }) { next.prompts[index] = prompt }
        else { next.prompts.append(prompt) }
        return save(next)
    }
    @discardableResult public func setSelection(_ selection: TranslationResourceSelection, for use: ProviderUse) -> Bool {
        do { _ = try snapshot(selection) } catch { self.error = .unavailable; return false }
        var next = document
        if use == .text { next.text = selection } else { next.pdf = selection }
        return save(next)
    }
    @discardableResult public func deleteGlossary(_ id: UUID) -> Bool {
        var next = document
        next.glossaries.removeAll { $0.id == id }
        next.text.glossaryIDs.removeAll { $0 == id }; next.pdf.glossaryIDs.removeAll { $0 == id }
        return save(next)
    }
    @discardableResult public func deletePrompt(_ id: UUID) -> Bool {
        guard !TranslationPromptPreset.builtIns.contains(where: { $0.id == id }) else { error = .invalidInput; return false }
        var next = document
        next.prompts.removeAll { $0.id == id }
        if next.text.promptID == id { next.text.promptID = nil }; if next.pdf.promptID == id { next.pdf.promptID = nil }
        return save(next)
    }
    @discardableResult public func retrySaving() -> Bool { save(document) }
    public func prepareToQuit() -> Bool { !needsSave || retrySaving() }
    private func publish() { glossaries = document.glossaries; customPrompts = document.prompts }
    private func location() throws -> URL {
        let file = root.appendingPathComponent("translation-resources.json")
        guard Self.canonical(root).path == root.path, Self.canonical(file).path == file.path else { throw TranslationResourceError.storage }
        return file
    }
    /// Resolve the existing ancestor before appending not-yet-created folders.
    /// Foundation otherwise changes /private/tmp aliases after the first save.
    private static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missing.append(ancestor.lastPathComponent); ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }
    private func validate(_ value: TranslationResourceDocument) throws {
        guard value.version == 1, Set(value.glossaries.map(\.id)).count == value.glossaries.count,
              Set(value.prompts.map(\.id)).count == value.prompts.count else { throw TranslationResourceError.storage }
        for glossary in value.glossaries { try glossary.validate() }; for prompt in value.prompts { try prompt.validate() }
        for selection in [value.text, value.pdf] {
            guard Set(selection.glossaryIDs).count == selection.glossaryIDs.count,
                  selection.glossaryIDs.allSatisfy({ id in value.glossaries.contains { $0.id == id } }),
                  selection.promptID == nil || (value.prompts + TranslationPromptPreset.builtIns).contains(where: { $0.id == selection.promptID }) else { throw TranslationResourceError.storage }
        }
    }
    private func save(_ next: TranslationResourceDocument) -> Bool {
        guard readable else { error = .storage; return false }
        do { try validate(next) } catch { self.error = .invalidInput; return false }
        document = next; publish()
        do {
            let file = try location()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            needsSave = false; error = nil; return true
        } catch { needsSave = true; self.error = .storage; return false }
    }
}

private enum GlossaryCSV {
    static func parse(_ source: String) throws -> [[String]] {
        guard source.utf8.count <= 10_000_000 else { throw TranslationResourceError.invalidCSV }
        var text = source
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let chars = Array(text); var index = 0; var quoted = false; var closed = false
        var field = ""; var row: [String] = []; var rows: [[String]] = []
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "\"" {
                guard field.isEmpty, !closed else { throw TranslationResourceError.invalidCSV }; quoted = true
            } else if c == "," {
                row.append(field); field = ""; closed = false
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
                row.append(field); rows.append(row); row = []; field = ""; closed = false
            } else {
                guard !closed else { throw TranslationResourceError.invalidCSV }; field.append(c)
            }
            index += 1
        }
        guard !quoted else { throw TranslationResourceError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}
