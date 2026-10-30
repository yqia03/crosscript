import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TextWorkspaceMigrationTests {
    @Test func everyLegacyResultMigratesOnceAndOriginalBytesRemainUntouched() throws {
        let f = try TextFixture(); defer { f.remove() }; let id = UUID(), original = Data("# Source\r\n".utf8)
        let first = result(f, input: "First", target: "First user edit")
        let second = result(f, input: "第二份原文", target: "Second user edit", direction: .chineseToEnglish)
        let bytes = try legacy(f, id, input: "Unused draft", results: [first, second], selected: second.id, imported: original)
        let store = TextWorkspaceStore(root: f.root)
        let loaded = try store.load()
        #expect(loaded.library.history.count == 2)
        #expect(loaded.library.history.first { $0.id == first.id }?.translation == "First user edit")
        #expect(loaded.library.workspace.inputDraft == second.input && loaded.library.workspace.translation == second.currentText)
        #expect(loaded.library.workspace.direction == .chineseToEnglish && loaded.library.workspace.importedMarkdown == original)
        let persisted = try Data(contentsOf: f.root.appendingPathComponent("TextWorkspace/workspace.json"))
        #expect(try store.load().library == loaded.library)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("TextWorkspace/workspace.json")) == persisted)
        #expect(try Data(contentsOf: directory(f, id).appendingPathComponent("material.json")) == bytes)
        #expect(try Data(contentsOf: directory(f, id).appendingPathComponent("source.md")) == original)
        #expect(f.credentials.readCount == 0)
    }
    @Test func mostRecentUntranslatedDraftBecomesWorkspaceWithoutAddingHistory() throws {
        let f = try TextFixture(); defer { f.remove() }
        let old = result(f, input: "Old", target: "Old edit")
        _ = try legacy(f, UUID(), input: "Old draft", results: [old], selected: old.id)
        _ = try legacy(f, UUID(), input: "Latest unsent draft", results: [], selected: nil, updatedAt: 800000000)
        let value = try f.store.load().library
        #expect(value.workspace.inputDraft == "Latest unsent draft" && value.workspace.currentResult == nil)
        #expect(value.history.map(\.id) == [old.id])
    }
    @Test func priorSchemaTwoUpgradeImportsArchivedVersionsAndCurrentEdits() throws {
        let f = try TextFixture(); defer { f.remove() }; let id = UUID()
        let old = result(f, input: "Old", target: "Archived edit")
        var current = result(f, input: "Selected", target: "Archived selected edit")
        let archived = try legacy(f, id, input: "Draft", results: [old, current], selected: current.id)
        let archive = directory(f, id).appendingPathComponent("legacy-schema-1")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try archived.write(to: archive.appendingPathComponent("material.json"))
        current.currentText = "Later current user edit"
        let active = try legacy(f, id, input: "Current unsent source", results: [current], selected: current.id, schema: 2)
        let value = try f.store.load().library
        #expect(value.history.count == 2)
        #expect(value.history.first { $0.id == current.id }?.translation == "Later current user edit")
        #expect(value.history.first { $0.id == old.id }?.translation == "Archived edit")
        #expect(value.workspace.inputDraft == "Current unsent source" && value.workspace.translation == "Later current user edit")
        #expect(try Data(contentsOf: archive.appendingPathComponent("material.json")) == archived)
        #expect(try Data(contentsOf: directory(f, id).appendingPathComponent("material.json")) == active)
    }
    @Test func generatingMarkdownBecomesInterruptedWithPartialAndNoRequest() throws {
        let f = try TextFixture(); defer { f.remove() }
        var document = MarkdownDocument(source: "First.\n\n```swift\nlet a = 1\n```\n")
        let leaf = try #require(document.leaves.first); let accepted = document.editLeaf(id: leaf.id, text: "用户编辑"); #expect(accepted)
        var result = TextTranslationResult(input: document.source, direction: .englishToChinese, provider: f.profile.snapshot, markdown: document)
        result.currentText = document.translated
        _ = try legacy(f, UUID(), input: "Different draft", results: [result], selected: result.id)
        let app = TextTranslationSession(store: f.store, credentials: f.credentials, service: ControlledTextTranslator())
        #expect(app.workspace.currentResult?.status == .interrupted && app.history.first?.result.status == .interrupted)
        #expect(app.workspace.currentResult?.markdown == document && app.workspace.inputDraft == document.source)
        #expect(f.credentials.readCount == 0)
    }
    @Test func invalidLegacyReferenceAndUnknownSchemaPreserveFilesAndWarn() throws {
        let f = try TextFixture(); defer { f.remove() }; let badID = UUID(), futureID = UUID()
        let bad = try legacy(f, badID, input: "Keep draft", results: [], selected: UUID())
        let future = try legacy(f, futureID, input: "Future draft", results: [], selected: nil, schema: 999)
        let loaded = try f.store.load()
        #expect(Set(loaded.unreadableIDs) == Set([badID, futureID]))
        #expect(try Data(contentsOf: directory(f, badID).appendingPathComponent("material.json")) == bad)
        #expect(try Data(contentsOf: directory(f, futureID).appendingPathComponent("material.json")) == future)
    }
    @Test func migrationWriteFailureCanRetryWithoutChangingLegacyFiles() throws {
        let f = try TextFixture(); defer { f.remove() }; let id = UUID()
        let original = try legacy(f, id, input: "Retain exact user draft", results: [], selected: nil)
        let failing = TextWorkspaceStore(root: f.root, beforeWrite: { throw TextTranslationError.storage })
        let recovered = try failing.load()
        #expect(recovered.hasPendingSave && recovered.library.workspace.inputDraft == "Retain exact user draft")
        let session = TextTranslationSession(store: failing, credentials: f.credentials, service: ControlledTextTranslator())
        #expect(session.hasPendingSave && session.workspace.inputDraft == "Retain exact user draft")
        #expect(!session.retrySaving() && session.workspace.inputDraft == "Retain exact user draft")
        #expect(try Data(contentsOf: directory(f, id).appendingPathComponent("material.json")) == original)
        #expect(try f.store.load().library.workspace.inputDraft == "Retain exact user draft")
        #expect(try f.store.load().library.history.isEmpty)
    }
    private func result(_ f: TextFixture, input: String, target: String, direction: TextTranslationDirection = .englishToChinese) -> TextTranslationResult {
        var result = TextTranslationResult(input: input, direction: direction, provider: f.profile.snapshot)
        result.currentText = target; result.generatedText = "Generated"; result.status = .completed; return result
    }
    private func directory(_ f: TextFixture, _ id: UUID) -> URL { f.root.appendingPathComponent("TextMaterials/\(id.uuidString)") }
    @discardableResult private func legacy(_ f: TextFixture, _ id: UUID, input: String, results: [TextTranslationResult], selected: UUID?, imported: Data? = nil, updatedAt: Double = 700000000, schema: Int = 1) throws -> Data {
        var object: [String: Any] = ["schemaVersion": schema, "id": id.uuidString, "createdAt": 700000000, "updatedAt": updatedAt, "inputDraft": input, "direction": "chineseToEnglish"]
        if schema == 2 { object["currentResult"] = try results.first.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } }
        else { object["results"] = try results.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }; if let selected { object["selectedResultID"] = selected.uuidString } }
        if let imported { object["importedMarkdown"] = imported.base64EncodedString(); object["importedFileName"] = "source.md" }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory(f, id), withIntermediateDirectories: true)
        try data.write(to: directory(f, id).appendingPathComponent("material.json"))
        if let imported { try imported.write(to: directory(f, id).appendingPathComponent("source.md")) }; return data
    }
}
