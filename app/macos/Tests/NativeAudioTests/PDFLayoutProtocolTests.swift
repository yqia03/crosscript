import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct PDFLayoutProtocolTests {
    @Test func allLayoutSettingsReachWorkerAndInvalidThresholdStartsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layout-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controlled.sh"), observed = root.appendingPathComponent("observed.json")
        try Data("""
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}]}'
        """.utf8).write(to: script)
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        var options = PDFTranslationOptions()
        options.layout.fontFamily = .script; options.layout.formulaFontPattern = ".*Courier.*"; options.layout.formulaCharacterPattern = "[=+]"
        options.layout.splitShortLines = true; options.layout.shortLineSplitFactor = 0.4; options.layout.skipCleaning = true; options.layout.richText = false
        options.layout.enhanceCompatibility = true; options.layout.formulaPlaceholderHint = true; options.layout.mergeAlternatingLineNumbers = false
        options.layout.renderForms = false; options.layout.renderCurves = false; options.layout.removeNonFormulaLines = true
        options.layout.nonFormulaLineOverlapThreshold = 0.3; options.layout.figureTableProtectionThreshold = 0.7; options.layout.calculateFormulaOffsets = false
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot
        func request(_ options: PDFTranslationOptions) -> PDFEngineRequest { .init(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root, provider: provider, options: options) }
        _ = try await engine.translate(request(options), apiKey: "CONTROLLED") { _ in }
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: observed)) as? [String: Any])
        let settings = try #require(payload["options"] as? [String: Any])
        for (key, value) in options.layout.engineSettings {
            #expect((settings[key] as? NSObject) == (value as? NSObject), "Missing mapping: \(key)")
        }
        #expect(settings["dual_translate_first"] as? Bool == true)
        try FileManager.default.removeItem(at: observed)
        options.layout.figureTableProtectionThreshold = 2
        do { _ = try await engine.translate(request(options), apiKey: "CONTROLLED") { _ in }; Issue.record("Invalid layout started worker") }
        catch { #expect(error as? PDFLayoutSettingsError == .invalidThreshold) }
        #expect(!FileManager.default.fileExists(atPath: observed.path))
    }
}
