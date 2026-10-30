import CoreGraphics
import Foundation
import Testing
@testable import WorkbenchCore

@Suite struct PDFLayoutSettingsTests {
    @Test func defaultsConflictsAndNumericBoundsMatchPinnedEngine() throws {
        var options = PDFTranslationOptions()
        #expect(options.layout.fontFamily == .automatic && options.layout.richText)
        #expect(options.layout.renderForms && options.layout.renderCurves && options.layout.calculateFormulaOffsets)
        #expect(options.layout.mergeAlternatingLineNumbers && options.layout.shortLineSplitFactor == 0.8)
        #expect(options.layout.nonFormulaLineOverlapThreshold == 0.9 && options.layout.figureTableProtectionThreshold == 0.9)
        #expect(options.layout.engineSettings["primary_font_family"] == nil)
        options.layout.enhanceCompatibility = true
        #expect(options.effectiveOutput.translatedFirst && !options.output.translatedFirst)
        for value in [Double.nan, .infinity, -1, 0] {
            options.layout.shortLineSplitFactor = value
            #expect(throws: PDFLayoutSettingsError.invalidShortLineFactor) { try options.validated() }
        }
        options.layout.shortLineSplitFactor = 1.2; _ = try options.validated()
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            options.layout.nonFormulaLineOverlapThreshold = value
            #expect(throws: PDFLayoutSettingsError.invalidThreshold) { try options.validated() }
        }
        options.layout.nonFormulaLineOverlapThreshold = 0
        options.layout.figureTableProtectionThreshold = 1; _ = try options.validated()
        options.layout.formulaFontPattern = String(repeating: "x", count: 4097)
        #expect(throws: PDFLayoutSettingsError.patternTooLong) { try options.validated() }
        #expect(try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{}".utf8)).layout == PDFLayoutSettings())
    }
    @Test func fullLayoutSnapshotSurvivesDefaultEditsAndHistoryReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.pdf"); var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(original as CFURL, mediaBox: &bounds, nil)); context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let store = PDFMaterialStore(root: root.appendingPathComponent("library")); var material = try store.importPDF(original)
        var options = PDFTranslationOptions(); options.layout = configuredLayout()
        let task = PDFBackgroundTask(provider: try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot, options: options)
        let staging = try store.stagingDirectory(task.id, materialID: material.id), output = staging.appendingPathComponent("generated.pdf")
        try FileManager.default.copyItem(at: original, to: output)
        let result = try store.install(.init(outputs: [.init(kind: .dual, url: output)]), task: task, material: material, resultID: UUID())
        material.results = [result]; material.selectedResultID = result.id; try store.save(material)
        options.layout = .init()
        let reopened = try #require(store.load().materials.first?.selectedResult)
        #expect(reopened.options.layout == configuredLayout() && reopened.options.layout != options.layout)
        #expect(reopened.options.effectiveOutput.translatedFirst)
        #expect(reopened.options.layout.snapshotLines(.english).contains { $0.contains("Courier") })
        #expect(try Data(contentsOf: store.originalURL(material.id)) == Data(contentsOf: original))
    }
    private func configuredLayout() -> PDFLayoutSettings {
        var value = PDFLayoutSettings(); value.fontFamily = .script; value.formulaFontPattern = ".*Courier.*"; value.formulaCharacterPattern = "[=+]"
        value.splitShortLines = true; value.shortLineSplitFactor = 0.5; value.skipCleaning = true; value.richText = false; value.enhanceCompatibility = true
        value.formulaPlaceholderHint = true; value.mergeAlternatingLineNumbers = false; value.renderForms = false; value.renderCurves = false
        value.removeNonFormulaLines = true; value.nonFormulaLineOverlapThreshold = 0.5; value.figureTableProtectionThreshold = 0.8; value.calculateFormulaOffsets = false
        return value
    }
}
