import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import WorkbenchCore
@Suite struct PDFOutputSettingsTests {
    @Test func historicalOutputSettingsAndAllFilesSurviveExternalMoveAndFailedExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("output-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf"), dataRoot = root.appendingPathComponent("library")
        var bounds = CGRect(x: 0, y: 0, width: 100, height: 150)
        let context = try #require(CGContext(original as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
        let store = PDFMaterialStore(root: dataRoot)
        var material = try store.importPDF(original)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved.pdf"))
        #expect(try store.pageCount(material.id) == 3)
        var options = PDFTranslationOptions(); options.output.pages = "2-3"; options.output.onlyIncludeTranslatedPages = true
        options.output.mode = .both; options.output.watermark = .both; options.output.maximumPagesPerPart = 1
        options.output.layout = .alternatingPages; options.output.translatedFirst = true
        let task = PDFBackgroundTask(provider: try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot, options: options)
        let staging = try store.stagingDirectory(task.id, materialID: material.id)
        var generated: [PDFGeneratedOutput] = []
        for kind in PDFOutputKind.allCases where kind.isPDF {
            let url = staging.appendingPathComponent(kind.rawValue + ".pdf")
            try FileManager.default.copyItem(at: store.originalURL(material.id), to: url)
            generated.append(.init(kind: kind, url: url))
        }
        let result = try store.install(.init(outputs: generated), task: task, material: material, resultID: UUID())
        material.results.append(result); material.selectedResultID = result.id; try store.save(material)
        options.output = .init()
        let reopened = try #require(PDFMaterialStore(root: dataRoot).load().materials.first)
        #expect(reopened.selectedResult?.options.output == task.options.output)
        #expect(reopened.selectedResult?.options.output != options.output)
        #expect(reopened.selectedResult?.outputs.count == 4)
        for output in result.outputs {
            let readingURL = try store.resultURL(materialID: material.id, resultID: result.id, output: output)
            let exported = root.appendingPathComponent("export-" + output.filename)
            try store.export(readingURL, to: exported)
            #expect(try Data(contentsOf: readingURL) == Data(contentsOf: exported))
            #expect(PDFDocument(url: readingURL)?.pageCount == 3)
            #expect(throws: (any Error).self) { try store.export(readingURL, to: root.appendingPathComponent("missing/output.pdf")) }
            #expect(FileManager.default.fileExists(atPath: readingURL.path))
        }
        #expect(try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{\"direction\":\"englishToChinese\"}".utf8)).output == PDFOutputSettings())
    }
    @Test func defaultAndAllOutputModesMapWithoutImpossibleNoOutputCombination() throws {
        var settings = PDFOutputSettings(); try settings.validate(pageCount: 3)
        #expect(settings.mode == .bilingual && settings.layout == .sideBySide && !settings.translatedFirst)
        #expect(settings.engineSettings["no_mono"] as? Bool == true)
        for mode in PDFOutputSettings.Mode.allCases {
            settings.mode = mode
            #expect(!(settings.engineSettings["no_mono"] as! Bool && settings.engineSettings["no_dual"] as! Bool))
        }
        settings.layout = .alternatingPages; settings.translatedFirst = true; settings.watermark = .noWatermark
        #expect(settings.engineSettings["use_alternating_pages_dual"] as? Bool == true)
        #expect(settings.engineSettings["dual_translate_first"] as? Bool == true)
        #expect(settings.engineSettings["watermark_output_mode"] as? String == "no_watermark")
        #expect(try JSONDecoder().decode(PDFOutputSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func explicitAndOpenRangesRespectActualDocumentPageCount() throws {
        var settings = PDFOutputSettings(); settings.pages = " 1-3,5,7-,-2 "
        #expect(try settings.selectedPages(pageCount: 8) == [1...3,5...5,7...8,1...2])
        settings.onlyIncludeTranslatedPages = true; settings.maximumPagesPerPart = 2
        try settings.validate(pageCount: 8)
        #expect(settings.engineSettings["max_pages_per_part"] as? Int == 2)
        settings.pages = ""
        #expect(throws: PDFOutputSettingsError.rangeRequired) { try settings.validate(pageCount: 8) }
        settings.pages = "9-"
        #expect(throws: PDFOutputSettingsError.outsideDocument(8)) { try settings.validate(pageCount: 8) }
        settings.pages = "1"; settings.maximumPagesPerPart = 0
        #expect(throws: PDFOutputSettingsError.invalidPartSize) { try settings.validate(pageCount: 8) }
    }
    @Test(arguments: ["0", "-", "3-2", "1,,2", "x", "1-2-3", "-0", "9999999999999999999999999", "1,", "１"])
    func malformedRangeFailsBeforeEngine(_ text: String) {
        var settings = PDFOutputSettings(); settings.pages = text
        #expect(throws: PDFOutputSettingsError.invalidRange) { try settings.validate(pageCount: 8) }
    }
}
