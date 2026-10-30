import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct MarkdownBilingualTests {
    @Test func editedSplitsAndMergedSourcesHaveIdenticalPreviewCopyExportAndReopen() async throws {
        let fixture = try TextFixture(service: MarkdownControlledTranslator()); defer { fixture.remove() }
        let app = fixture.app
        _ = app.setMarkdown(enabled: true)
        #expect(app.updateInput(text: "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n"))
        await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese)
        let result = try #require(app.workspace.currentResult)
        let group = try #require(result.markdown?.groups.first)
        let leaf = try #require(result.markdown?.leaves.first)
        #expect(app.editMarkdownLeaf(resultID: result.id, leafID: leaf.id, text: "第一原段。\n\n拆成另一译段。"))
        let split = try #require(app.bilingualText(resultID: result.id))
        #expect(split.contains("First paragraph.\n\n第一原段。\n\n拆成另一译段。"))
        #expect(app.mergeMarkdownGroup(resultID: result.id, groupID: group.id))
        #expect(app.editMarkdownGroup(resultID: result.id, groupID: group.id, text: "前两原段合并译文。\n\n用户又拆开。"))
        let preview = try #require(app.workspace.currentResult?.markdown?.bilingual)
        let copy = try #require(app.bilingualText(resultID: result.id))
        #expect(preview == copy)
        #expect(preview.contains("First paragraph.\n\nSecond paragraph.\n\n前两原段合并译文。\n\n用户又拆开。"))
        #expect(preview.contains("Third paragraph.\n\n译文 Third paragraph."))
        let target = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: target) }
        #expect(app.exportBilingual(resultID: result.id, to: target))
        #expect(try String(contentsOf: target, encoding: .utf8) == copy)
        #expect(fixture.reopen().bilingualText(resultID: result.id) == copy)
        #expect(app.mergeMarkdownGroup(resultID: result.id, groupID: group.id))
        #expect(app.workspace.currentResult?.markdown?.groups.count == 1)
        #expect(app.workspace.currentResult?.markdown?.source == result.input)
    }
    @Test func bilingualKeepsRepeatedCodeLocationsAndValidTablesReferencesAndNestedListStructure() async throws {
        let fixture = try TextFixture(service: MarkdownControlledTranslator()); defer { fixture.remove() }
        let app = fixture.app; _ = app.setMarkdown(enabled: true)
        #expect(app.updateInput(text: MarkdownDocumentTests.complex))
        await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese)
        let result = try #require(app.workspace.currentResult)
        let output = try #require(app.bilingualText(resultID: result.id))
        #expect(output.components(separatedBy: "// Never translate this comment").count - 1 == 2)
        #expect(output.components(separatedBy: "````swift").count - 1 == 1)
        #expect(output.components(separatedBy: "~~~swift").count - 1 == 1)
        #expect(output.contains("  - 译文 Child with [译文 reference][guide]"))
        #expect(output.contains("| 译文 Name | 译文 Meaning |\n| :--- | ---: |"))
        #expect(output.contains("[译文 docs](https://example.test/a_(b)?x=1 \"title\")"))
        #expect(output.components(separatedBy: "[guide]: https://example.test/reference \"Guide\"").count - 1 == 1)
        #expect(output.components(separatedBy: "$$\nx = y + z\n$$").count - 1 == 1)
        #expect(output.components(separatedBy: "\\[a + b\\]").count - 1 == 1)
        #expect(output.contains("![diagram](images/a.png)"))
        let before = app.workspace
        #expect(!app.exportBilingual(resultID: result.id, to: fixture.root.appendingPathComponent("overwrite.md")))
        #expect(app.workspace == before)
    }
}
