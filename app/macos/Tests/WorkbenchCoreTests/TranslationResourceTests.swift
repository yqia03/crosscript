import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct TranslationResourceTests {
    @Test func updatedBuiltInsAppearInAnExistingLibraryWithoutChangingSavedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let customID = UUID(uuidString: "DC75D62D-96D1-4641-8C4F-43DB515756ED")!
        let oldLibrary = #"{"version":1,"glossaries":[],"prompts":[{"id":"DC75D62D-96D1-4641-8C4F-43DB515756ED","name":"My preset / 保留名称","instruction":"Keep my instruction.","isBuiltIn":false}],"text":{"glossaryIDs":[],"promptID":"8477F4DA-FAB5-433C-A2A3-209413F17486"},"pdf":{"glossaryIDs":[],"promptID":"DC75D62D-96D1-4641-8C4F-43DB515756ED"}}"#
        let path = root.appendingPathComponent("translation-resources.json")
        try Data(oldLibrary.utf8).write(to: path)
        let library = TranslationResourceLibrary(root: root)
        #expect(library.error == nil)
        #expect(library.prompts.count >= 12)
        #expect(Set(library.prompts.map(\.id)).count == library.prompts.count)
        #expect(library.customPrompts == [.init(id: customID, name: "My preset / 保留名称", instruction: "Keep my instruction.")])
        #expect(try library.snapshot(library.selection(for: .text)).prompt == TranslationPromptPreset.builtIns[1])
        #expect(try library.snapshot(library.selection(for: .pdf)).prompt?.id == customID)
        #expect(try Data(contentsOf: path) == Data(oldLibrary.utf8))
        #expect(TranslationPromptPreset.builtIns[0].id == UUID(uuidString: "FB281F2C-C436-4CB1-8744-ED2E81762A20"))
        #expect(TranslationPromptPreset.builtIns[0].instruction == "Translate faithfully and clearly. Preserve the meaning, technical detail, names and numerical values. Return only the translation.")
        #expect(TranslationPromptPreset.builtIns[1].instruction == "Translate for academic reading. Use precise terminology and clear prose. Preserve citations, qualifications and the author's degree of certainty. Return only the translation.")
        for prompt in TranslationPromptPreset.builtIns {
            #expect(try TranslationResourceSnapshot(prompt: prompt).validated().prompt == prompt)
            #expect(!prompt.displayName(.zhHans).contains(" / "))
            #expect(!prompt.displayName(.english).contains(" / "))
            #expect(prompt.displayName(.zhHans) != prompt.displayName(.english))
        }
        #expect(library.customPrompts[0].displayName(.zhHans) == "My preset / 保留名称")
        #expect(library.customPrompts[0].displayName(.english) == "My preset / 保留名称")
    }

    @Test(arguments: ["/tmp", "/private/tmp"])
    func firstAndSecondSavesToNewNestedAliasPathReopenTheSameLibrary(prefix: String) throws {
        let parent = URL(fileURLWithPath: prefix).appendingPathComponent("resource-first-use-\(UUID())")
        let root = parent.appendingPathComponent("nested/library")
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let library = TranslationResourceLibrary(root: root)
        let glossary = TranslationGlossary(name: "First", entries: [.init(source: "qubit", target: "量子比特")])
        let prompt = TranslationPromptPreset(name: "Second", instruction: "Preserve uncertainty.")
        #expect(library.saveGlossary(glossary))
        #expect(library.savePrompt(prompt))
        let selection = TranslationResourceSelection(glossaryIDs: [glossary.id], promptID: prompt.id)
        #expect(library.setSelection(selection, for: .text))
        let reopened = TranslationResourceLibrary(root: root.resolvingSymlinksInPath())
        #expect(reopened.error == nil)
        #expect(reopened.glossaries == [glossary] && reopened.customPrompts == [prompt])
        #expect(reopened.selection(for: .text) == selection)
        #expect(try reopened.snapshot(selection) == library.snapshot(selection))
    }

    @Test func sharedLibraryReopensIndependentDefaultsAndSubmittedSnapshotsSurviveEditingAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TranslationResourceLibrary(root: root)
        var glossary = TranslationGlossary(name: "Engineering", entries: [.init(source: "latency", target: "延迟", targetLanguage: "zh")])
        let prompt = TranslationPromptPreset(name: "Custom", instruction: "Use clear technical language.")
        #expect(library.saveGlossary(glossary)); #expect(library.savePrompt(prompt))
        let text = TranslationResourceSelection(glossaryIDs: [glossary.id], promptID: prompt.id)
        let pdf = TranslationResourceSelection(glossaryIDs: [glossary.id], promptID: TranslationPromptPreset.builtIns[0].id)
        #expect(library.setSelection(text, for: .text)); #expect(library.setSelection(pdf, for: .pdf))
        let submitted = try library.snapshot(text)
        glossary.entries[0].target = "时延"
        #expect(library.saveGlossary(glossary))
        let reopened = TranslationResourceLibrary(root: root)
        #expect(reopened.selection(for: .text) == text); #expect(reopened.selection(for: .pdf) == pdf)
        #expect(try reopened.snapshot(text).glossaries[0].entries[0].target == "时延")
        #expect(reopened.deleteGlossary(glossary.id)); #expect(reopened.deletePrompt(prompt.id))
        #expect(submitted.glossaries[0].entries[0].target == "延迟")
        #expect(submitted.prompt == prompt)
        #expect(reopened.selection(for: .text) == .init())
        #expect(reopened.selection(for: .pdf).promptID == pdf.promptID)
        #expect(!reopened.deletePrompt(TranslationPromptPreset.builtIns[0].id))
    }

    @Test func csvImportRoundTripsQuotesNewlinesAndLanguageColumnsWithoutLosingEntries() throws {
        let source = "\u{FEFF}source,target,tgt_lng\r\n\"signal, noise\",\"信号，噪声\",zh\r\n\"say \"\"hello\"\"\",\"说你好\",\r\n\"multi\nline\",\"多行\",zh\r\nlatency,遅延,ja\r\n"
        let imported = try TranslationGlossary.importCSV(source, name: "Imported")
        #expect(imported.entries.count == 4)
        #expect(try TranslationGlossary.importCSV(imported.csv, name: "Round trip").entries == imported.entries)
        #expect(TranslationResourceSnapshot(glossaries: [imported]).terms(for: .englishToChinese).count == 3)
        #expect(TranslationResourceSnapshot(glossaries: [imported]).terms(for: .chineseToEnglish).count == 1)
        #expect(throws: TranslationResourceError.self) { try TranslationGlossary.importCSV("source,target\n\"unfinished", name: "Invalid") }
        #expect(throws: TranslationResourceError.self) { try TranslationGlossary.importCSV("source,target\na,b,extra", name: "Invalid") }
    }

    @Test func failedSavingPreservesDraftThenLocalRetrySavesItWithoutReplacingOtherResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TranslationResourceLibrary(root: root)
        let original = TranslationGlossary(name: "Original", entries: [])
        #expect(library.saveGlossary(original))
        let path = root.appendingPathComponent("translation-resources.json")
        let saved = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let draft = TranslationPromptPreset(name: "Unsaved", instruction: "Keep this instruction.")
        #expect(!library.savePrompt(draft)); #expect(library.needsSave)
        #expect(library.customPrompts == [draft]); #expect(library.glossaries == [original])
        #expect(!library.prepareToQuit())
        #expect(throws: TranslationResourceError.self) { try library.snapshot(.init(promptID: draft.id)) }
        try FileManager.default.removeItem(at: path); try saved.write(to: path)
        #expect(library.retrySaving()); #expect(library.prepareToQuit())
        let reopened = TranslationResourceLibrary(root: root)
        #expect(reopened.customPrompts == [draft]); #expect(reopened.glossaries == [original])
    }

    @Test func unreadableLibraryAndSymlinkAreNeverOverwrittenByAnEmptyLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let path = root.appendingPathComponent("translation-resources.json")
        let bytes = Data("preserve invalid library".utf8)
        try bytes.write(to: external)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        let library = TranslationResourceLibrary(root: root)
        #expect(library.error == .storage)
        #expect(!library.saveGlossary(.init(name: "Must not overwrite", entries: [])))
        #expect(library.prepareToQuit())
        #expect(try Data(contentsOf: external) == bytes)
    }
}
