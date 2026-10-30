import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct ExportFilenameTests {
    @Test func exportedTextUsesWorkflowAndLocalExportTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2003-02-27T08:32:21Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        #expect(ExportFilename.record(bilingual: true, extension: "txt", at: date, timeZone: zone) == "record-billingual-2003-02-27-16-32-21.txt")
        #expect(ExportFilename.record(bilingual: false, extension: "md", at: date, timeZone: zone) == "record-2003-02-27-16-32-21.md")
        #expect(ExportFilename.transcript(extension: "txt", at: date, timeZone: zone) == "transcrips-2003-02-27-16-32-21.txt")
    }

    @Test func translatedPDFNamesIdentifyTheLanguagesAndPreserveOriginalBasename() {
        #expect(ExportFilename.pdf("Lecture1.pdf", direction: .englishToChinese, kind: .dual) == "Lecture1-en_cn.pdf")
        #expect(ExportFilename.pdf("lecture1", direction: .englishToChinese, kind: .monoNoWatermark) == "lecture1-cn.pdf")
        #expect(ExportFilename.pdf("笔记 v1.2", direction: .chineseToEnglish, kind: .dualNoWatermark) == "笔记 v1.2-cn_en.pdf")
        #expect(ExportFilename.pdf("Lecture1.PDF", direction: .chineseToEnglish, kind: .mono) == "Lecture1-en.pdf")
    }

    @Test func timestampRecordingNamesSuggestUsableTXTAndMarkdownNames() {
        // Actual candidate6 native failure: the colon-containing default was
        // shown with slashes and Save stayed disabled. This locks the input
        // contract; it does not pretend to execute the native panel validator.
        let name = "2026-10-15 21:41:10"
        #expect(ExportFilename.suggested(name, extension: "txt") == "2026-10-15 21-41-10.txt")
        #expect(ExportFilename.suggested(name, extension: "md") == "2026-10-15 21-41-10.md")
    }

    @Test func legitimateUnicodeAndInternalDotsRemainUnchanged() {
        let name = "量子研究 👩🏽‍💻 · café e\u{301} · v1.2"
        #expect(ExportFilename.suggested(name, extension: "pdf") == name + ".pdf")
        #expect(ExportFilename.suggested(name + "-terms", extension: "csv") == name + "-terms.csv")
        // No arbitrary truncation of a valid user-visible suggestion.
        let longName = String(repeating: "研究", count: 80)
        #expect(ExportFilename.suggested(longName, extension: "txt") == longName + ".txt")
    }

    @Test func separatorsAndControlsCannotCreateAPathOrInvalidName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-name-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "章节:一/二\n备注\u{0}\t末\u{7f}"
        let bytes = Data("保留当前编辑\nEdited source + translation".utf8)
        for ext in ["txt", "md", "pdf", "csv"] {
            let filename = ExportFilename.suggested(name, extension: ext)
            #expect(filename == "章节-一-二-备注--末-." + ext)
            #expect(!filename.contains(":"))
            let destination = folder.appendingPathComponent(filename)
            #expect(destination.deletingLastPathComponent() == folder)
            #expect(destination.lastPathComponent == filename)
            try bytes.write(to: destination, options: .atomic)
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }

    @Test func emptyOrDotOnlySuggestionsHaveAnExplicitBasename() {
        for name in ["", " ", "\n\t", ".", "..", "  ..  "] {
            #expect(ExportFilename.suggested(name, extension: "txt") == "export.txt")
        }
    }
}
