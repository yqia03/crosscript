import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TextResourceTests {
    @Test func submittedResourcesSurviveLibraryEditsCancellationRetryAndHistoryReopen() async throws {
        let service = SuspendedTextTranslator()
        let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let library = TranslationResourceLibrary(root: fixture.root)
        var glossary = TranslationGlossary(name: "Quantum", entries: [.init(source: "qubit", target: "量子比特", targetLanguage: "zh")])
        var prompt = TranslationPromptPreset(name: "Custom academic", instruction: "Preserve scientific qualifications.")
        #expect(library.saveGlossary(glossary)); #expect(library.savePrompt(prompt))
        let selection = TranslationResourceSelection(glossaryIDs: [glossary.id], promptID: prompt.id)
        #expect(library.setSelection(selection, for: .text))
        let pdfSelection = TranslationResourceSelection(promptID: TranslationPromptPreset.builtIns[1].id)
        #expect(library.setSelection(pdfSelection, for: .pdf))
        let expected = try library.snapshot(selection)

        #expect(fixture.app.updateInput(text: "A qubit is a quantum bit."))
        let work = Task { await fixture.app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese, resources: library) }
        await service.waitForRequests(1)
        glossary.entries[0].target = "New glossary wording"; prompt.instruction = "New instruction"
        #expect(library.saveGlossary(glossary)); #expect(library.savePrompt(prompt))
        #expect(library.setSelection(.init(), for: .text))
        #expect(library.selection(for: .pdf) == pdfSelection)
        #expect(await service.request(at: 0).resources == expected)
        let first = try #require(fixture.app.workspace.currentResult)
        #expect(first.resources == expected)
        await service.emit(0, .delta("初稿")); fixture.app.stop()
        await service.emit(0, .delta("late must not overwrite")); await service.finish(0); await work.value
        #expect(fixture.app.updateResult(resultID: first.id, text: "人工整理"))
        let retry = Task { await fixture.app.retry() }
        await service.waitForRequests(2)
        #expect(await service.request(at: 1).resources == expected)
        await service.emit(1, .delta("独立重试结果")); await service.finish(1); await retry.value
        let reopened = fixture.reopen(); let result = try #require(reopened.workspace.currentResult)
        #expect(result.resources == expected && result.id != first.id)
        #expect(result.currentText == "独立重试结果")
        #expect(library.deleteGlossary(glossary.id)); #expect(library.deletePrompt(prompt.id))
        #expect(fixture.reopen().workspace.currentResult?.resources == expected)
    }

    @Test func missingSelectionAndUnsavedLibraryPreventCloudSubmission() async throws {
        let service = ControlledTextTranslator(); let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let library = TranslationResourceLibrary(root: fixture.root)
        #expect(fixture.app.updateInput(text: "qubit"))
        #expect(fixture.app.selectResources(selection: .init(glossaryIDs: [UUID()])))
        await fixture.app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese, resources: library)
        #expect(fixture.app.error == .resources); #expect(await service.requests.isEmpty)
        #expect(fixture.app.selectResources(selection: .init()))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("translation-resources.json"), withIntermediateDirectories: false)
        #expect(!library.savePrompt(.init(name: "Unsaved", instruction: "Keep detail")))
        await fixture.app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese, resources: library)
        #expect(fixture.app.error == .resources); #expect(await service.requests.isEmpty)
        #expect(fixture.app.workspace.currentResult == nil)
    }

    @Test func configurationChangesDuringInitialSaveCancelBeforeCredentialsOrSubmission() async throws {
        for changeProvider in [false, true] {
            let service = ControlledTextTranslator(), fixture = try TextFixture(service: service), barrier = TextWriteBarrier()
            defer { barrier.release(); fixture.remove() }
            let library = TranslationResourceLibrary(root: fixture.root)
            let store = TextWorkspaceStore(root: fixture.root, beforeWrite: { barrier.beforeWrite() })
            let app = TextTranslationSession(store: store, credentials: fixture.credentials, service: service)
            _ = app.updateInput(text: "Source")
            barrier.arm()
            let request = Task { await app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese, resources: library) }
            for _ in 0..<500 { if barrier.started { break }; try await Task.sleep(for: .milliseconds(2)) }
            try #require(barrier.started)
            if changeProvider { app.providerConfigurationChanged() }
            else { #expect(library.savePrompt(.init(name: "Updated while saving", instruction: "Keep terminology."))) }
            barrier.release(); await request.value
            #expect(fixture.credentials.readCount == 0)
            #expect(await service.requests.isEmpty)
            #expect(app.workspace.inputDraft == "Source" && app.workspace.currentResult == nil)
            #expect(await app.flushPendingSaves())
        }
    }

    @Test func explicitNoPresetPersistsAndFailedResultSaveRetainsResourceSnapshot() async throws {
        let service = ControlledTextTranslator(); let fixture = try TextFixture(service: service); defer { fixture.remove() }
        let library = TranslationResourceLibrary(root: fixture.root)
        #expect(fixture.app.updateInput(text: "hello"))
        #expect(fixture.app.selectResources(selection: .init()))
        await fixture.app.submit(provider: fixture.profile.snapshot, direction: .englishToChinese, resources: library)
        let result = try #require(fixture.app.workspace.currentResult)
        #expect(result.resources == TranslationResourceSnapshot())
        let file = fixture.root.appendingPathComponent("TextWorkspace/workspace.json")
        let saved = try Data(contentsOf: file); try Data("broken".utf8).write(to: file)
        #expect(fixture.app.updateResult(resultID: result.id, text: "Retained unsaved edit"))
        #expect(!(await fixture.app.flushPendingSaves()))
        #expect(fixture.app.workspace.currentResult?.resources == result.resources)
        try saved.write(to: file); #expect(fixture.app.retrySaving())
        let restored = fixture.reopen().workspace
        #expect(restored.resourceSelection == TranslationResourceSelection())
        #expect(restored.currentResult?.currentText == "Retained unsaved edit")
        #expect(restored.currentResult?.resources == result.resources)
        #expect(await service.requests.count == 1)
    }

    @Test func olderResultWithoutResourceFieldsStillDecodes() throws {
        let fixture = try TextFixture(); defer { fixture.remove() }
        let result = TextTranslationResult(input: "Old", direction: .englishToChinese, provider: fixture.profile.snapshot)
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]); row.removeValue(forKey: "resources")
        let old = try JSONDecoder().decode(TextTranslationResult.self, from: JSONSerialization.data(withJSONObject: row))
        #expect(old.resources == nil)
    }

}

private final class TextWriteBarrier: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var armed = false
    private var didStart = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func release() { gate.signal() }
    func beforeWrite() {
        lock.lock()
        let wait = armed
        if wait { armed = false; didStart = true }
        lock.unlock()
        if wait { gate.wait() }
    }
}
