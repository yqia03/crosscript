import Foundation
import Testing
@testable import WorkbenchCore

@Suite struct PDFInactiveLayoutTests {
    @Test func parseOnlyKeepsEditableInvalidLayoutButUsesOnlyRenderingSettings() throws {
        var options = PDFTranslationOptions()
        options.layout.formulaFontPattern = "("
        options.layout.formulaCharacterPattern = String(repeating: "x", count: 4097)
        options.layout.shortLineSplitFactor = -1
        options.layout.nonFormulaLineOverlapThreshold = 5
        options.layout.enhanceCompatibility = true
        options.layout.renderForms = false
        let savedLayout = options.layout
        options.content.operation = .parseOnly; options.output.watermark = .noWatermark
        _ = try options.validated()
        #expect(options.layout == savedLayout)
        #expect(!options.effectiveOutput.translatedFirst)
        #expect(options.effectiveOutput.summary(.english, localOnly: true).contains("Comparison"))
        #expect(!options.effectiveOutput.summary(.english, localOnly: true).contains("Bilingual"))
        #expect(options.effectiveLayoutSettings.count == 2)
        #expect(options.effectiveLayoutSettings["skip_form_render"] as? Bool == true)
        #expect(options.effectiveLayoutSettings["skip_curve_render"] as? Bool == false)
        let reopened = try JSONDecoder().decode(PDFTranslationOptions.self, from: JSONEncoder().encode(options))
        #expect(reopened.layout == savedLayout)
        options.content.operation = .translate
        #expect(throws: PDFLayoutSettingsError.invalidShortLineFactor) { try options.validated() }
    }
}
