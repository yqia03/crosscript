import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct MarkdownSessionTests {
    @Test func importCopiesOriginalAndEditsExportReopenWithoutExternalFile() async throws {
        let service = MarkdownControlledTranslator()
        let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let source = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try Data(MarkdownDocumentTests.complex.utf8).write(to: source)
        let app = fixture.app
        #expect(app.importMarkdown(from: source))
        let original = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source)
        #expect(app.workspace.importedMarkdown == original)
        await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese)
        let result = try #require(app.workspace.currentResult)
        #expect(result.status == .completed)
        #expect(result.markdown?.isComplete == true)
        let leaf = try #require(result.markdown?.leaves.first)
        #expect(app.editMarkdownLeaf(resultID: result.id, leafID: leaf.id, text: "用户编辑标题"))
        #expect(app.updateInput(text: "Changed draft"))
        let exported = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: exported) }
        #expect(app.exportText(resultID: result.id, to: exported))
        #expect(try String(contentsOf: exported, encoding: .utf8) == app.text(resultID: result.id))
        let reopened = fixture.reopen()
        #expect(reopened.workspace.currentResult?.input == MarkdownDocumentTests.complex)
        #expect(reopened.workspace.currentResult?.markdown?.leaves.first?.translation == "用户编辑标题")
        #expect(reopened.workspace.importedMarkdown == original)
        #expect(reopened.workspace.inputDraft == "Changed draft")
        #expect(await service.requestCount == 1)
    }
    @Test func duplicateUnknownAndMalformedRecordsRetainPriorCompletedLeavesAndRawPartial() async throws {
        for mode in [MarkdownControlledTranslator.Mode.duplicate, .unknown, .malformed, .missing] {
            let service = MarkdownControlledTranslator(mode: mode)
            let fixture = try TextFixture(service: service); defer { fixture.remove() }
            _ = fixture.app.setMarkdown(enabled: true)
            #expect(fixture.app.updateInput(text: "First.\n\nSecond."))
            await fixture.app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese)
            let result = try #require(fixture.app.workspace.currentResult)
            #expect(result.status == .failed)
            #expect(result.failure == .structure)
            #expect(result.markdown?.translatedLeafCount == 1)
            #expect(result.markdown?.leaves.first?.translation == "译文 First.")
            #expect(result.markdownResponse?.isEmpty == false)
            #expect(fixture.reopen().workspace.currentResult?.markdown == result.markdown)
        }
    }
    @Test func stopAndLateResponseCannotOverrideEditedPartialAndRetryCreatesIndependentIdentity() async throws {
        let service = SuspendedTextTranslator()
        let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let app = fixture.app
        _ = app.setMarkdown(enabled: true)
        #expect(app.updateInput(text: "First.\n\nSecond."))
        let task = Task { await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1)
        let result = try #require(app.workspace.currentResult)
        let first = try #require(result.markdown?.leaves.first)
        await service.emit(0, .delta(try record(first.id, "部分译文") + "\n{\"id\":"))
        app.stop()
        #expect(app.editMarkdownLeaf(resultID: result.id, leafID: first.id, text: "用户保留修改。\n\n拆段。"))
        await service.emit(0, .delta(try record(first.id, "迟到破坏") + "\n"))
        await service.finish(0); await task.value
        #expect(app.workspace.currentResult?.markdown?.leaves.first?.translation == "用户保留修改。\n\n拆段。")
        let retry = Task { await app.retry() }
        await service.waitForRequests(2)
        #expect(app.workspace.currentResult?.markdown?.leaves.first?.id != first.id)
        app.stop(); await service.finish(1); await retry.value
        #expect(fixture.reopen().workspace.currentResult?.id != result.id)
        #expect(fixture.reopen().workspace.currentResult?.status == .stopped)
    }
    @Test func streamInterruptionAndRestartRetainAssociationWithoutAutomaticRequest() async throws {
        let service = SuspendedTextTranslator()
        let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let app = fixture.app; _ = app.setMarkdown(enabled: true)
        #expect(app.updateInput(text: "First.\n\nSecond."))
        let task = Task { await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1)
        let leaf = try #require(app.workspace.currentResult?.markdown?.leaves.first)
        await service.emit(0, .delta(try record(leaf.id, "已保存译文") + "\n"))
        let reopened = fixture.reopen()
        #expect(reopened.workspace.currentResult?.status == .interrupted)
        #expect(reopened.workspace.currentResult?.markdown?.leaves.first?.id == leaf.id)
        #expect(reopened.workspace.currentResult?.markdown?.leaves.first?.translation == "已保存译文")
        #expect(await service.requestCount == 1)
        await service.finish(0, error: .network); await task.value
        #expect(app.workspace.currentResult?.failure == .network)
    }
    @Test func failedSaveAndExportKeepEditedAssociationAndRetrySaveDoesNotTranslate() async throws {
        let service = MarkdownControlledTranslator()
        let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let app = fixture.app; _ = app.setMarkdown(enabled: true)
        #expect(app.updateInput(text: "First.\n\nSecond."))
        await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese)
        let result = try #require(app.workspace.currentResult)
        let leaf = try #require(result.markdown?.leaves.first)
        let file = fixture.root.appendingPathComponent("TextWorkspace/workspace.json")
        let saved = try Data(contentsOf: file); try Data("broken".utf8).write(to: file)
        #expect(app.editMarkdownLeaf(resultID: result.id, leafID: leaf.id, text: "必须保留的修改"))
        #expect(!(await app.flushPendingSaves()))
        #expect(app.hasPendingSave)
        #expect(!app.exportText(resultID: result.id, to: fixture.root.appendingPathComponent("escape.md")))
        #expect(app.workspace.currentResult?.markdown?.leaves.first?.translation == "必须保留的修改")
        #expect(!app.prepareToQuit())
        try saved.write(to: file); #expect(app.retrySaving())
        #expect(fixture.reopen().workspace.currentResult?.markdown?.leaves.first?.translation == "必须保留的修改")
        #expect(await service.requestCount == 1)
    }
    @Test func directEditorProjectsTextEditsButRejectsProtectedSyntaxAndCrossPassageChanges() throws {
        var document = MarkdownDocument(source: "Hello 🌟 [world](https://example.test).\n\n```swift\nlet a = 1\n```\n\nLast paragraph.\n")
        let edited = document.replaceTranslation(with: document.translated.replacingOccurrences(of: "Hello 🌟", with: "你好 🌞")); #expect(edited)
        #expect(document.translated.contains("你好 🌞"))
        let before = document
        let linkEdit = document.replaceTranslation(with: document.translated.replacingOccurrences(of: "https://example.test", with: "https://changed.test")); #expect(!linkEdit)
        let codeEdit = document.replaceTranslation(with: document.translated.replacingOccurrences(of: "let a = 1", with: "let a = 2")); #expect(!codeEdit)
        let wholeEdit = document.replaceTranslation(with: "Replace the entire document"); #expect(!wholeEdit)
        #expect(document == before)
        #expect(document.bilingual.components(separatedBy: "let a = 1").count == 2)
        var grouped = MarkdownDocument(source: "First.\n\nSecond.\n")
        let group = try #require(grouped.groups.first)
        _ = grouped.mergeWithNext(group.id); _ = grouped.editGroup(id: group.id, text: "Merged")
        let beforeRejectedEdit = grouped
        let removedRequiredNewline = grouped.replaceTranslation(with: "Edited merged")
        #expect(!removedRequiredNewline && grouped == beforeRejectedEdit)
    }
    @Test func changedSourceCannotExportOldBilingualPairAsCurrentButMonolingualRemainsAvailable() async throws {
        let f = try TextFixture(service: MarkdownControlledTranslator()); defer { f.remove() }
        _ = f.app.setMarkdown(enabled: true); _ = f.app.updateInput(text: "Original paragraph.")
        await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        let result = try #require(f.app.workspace.currentResult)
        #expect(f.app.bilingualText(resultID: result.id) != nil)
        _ = f.app.updateInput(text: "Edited original paragraph.")
        #expect(f.app.bilingualText(resultID: result.id) == nil)
        #expect(f.app.text(resultID: result.id) == result.currentText)
    }
    @Test func directionAndFormatChangesRetainTranslationButInvalidateCurrentBilingualAssociation() async throws {
        let service = MarkdownControlledTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        _ = f.app.setMarkdown(enabled: true); _ = f.app.updateInput(text: "Original café.\n\nSecond paragraph.")
        await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        let result = try #require(f.app.workspace.currentResult)
        let firstGroup = try #require(result.markdown?.groups.first)
        #expect(f.app.workspace.currentResultMatchesWorkspace == true)
        _ = f.app.setDirection(direction: .chineseToEnglish)
        #expect(f.app.workspace.currentResultMatchesWorkspace == false)
        #expect(f.app.bilingualText(resultID: result.id) == nil)
        let mergedAfterDirectionChange = f.app.mergeMarkdownGroup(resultID: result.id, groupID: firstGroup.id)
        #expect(!mergedAfterDirectionChange)
        #expect(f.app.workspace.translation == result.currentText)
        #expect(f.app.workspace.currentResult?.direction == .englishToChinese)
        _ = f.app.setDirection(direction: .englishToChinese)
        #expect(f.app.workspace.currentResultMatchesWorkspace == true)
        _ = f.app.setMarkdown(enabled: false)
        #expect(f.app.workspace.currentResultMatchesWorkspace == false)
        #expect(f.app.bilingualText(resultID: result.id) == nil)
        let mergedAfterFormatChange = f.app.mergeMarkdownGroup(resultID: result.id, groupID: firstGroup.id)
        #expect(!mergedAfterFormatChange)
        #expect(f.reopen().workspace.translation == result.currentText)
        #expect(f.reopen().workspace.currentResultMatchesWorkspace == false)
        _ = f.app.setMarkdown(enabled: true)
        #expect(f.app.workspace.currentResultMatchesWorkspace == true)
        _ = f.app.updateInput(text: "Original cafe\u{301}.\n\nSecond paragraph.")
        #expect(f.app.workspace.currentResultMatchesWorkspace == false)
        #expect(await service.requestCount == 1)
    }
    private func record(_ id: UUID, _ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(["id": id.uuidString, "text": text]), as: UTF8.self)
    }
}

actor MarkdownControlledTranslator: TextTranslating {
    enum Mode { case valid, duplicate, unknown, malformed, missing }
    let mode: Mode
    var requestCount = 0
    init(mode: Mode = .valid) { self.mode = mode }
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        requestCount += 1
        guard request.responseContract != nil else { throw TextTranslationError.structure }
        let records = try request.input.split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let encoded = try records.map { String(decoding: try JSONEncoder().encode(["id": $0["id"]!, "text": "译文 " + $0["text"]!]), as: UTF8.self) }
        if mode == .valid {
            for line in encoded.reversed() {
                for character in line + "\n" { await onEvent(.delta(String(character))) }
            }
        } else {
            let first = encoded[0] + "\n"
            switch mode {
            case .duplicate: await onEvent(.delta(first + first))
            case .unknown: await onEvent(.delta(first + "{\"id\":\"\(UUID())\",\"text\":\"未知\"}\n"))
            case .malformed: await onEvent(.delta(first + "{\"id\":"))
            case .missing: await onEvent(.delta(first))
            case .valid: break
            }
        }
    }
}
