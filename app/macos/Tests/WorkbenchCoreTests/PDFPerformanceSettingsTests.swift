import CoreGraphics
import Foundation
import Testing
@testable import WorkbenchCore

@Suite struct PDFPerformanceSettingsTests {
    @Test func defaultsDependenciesBoundsAndLocalInactiveValues() throws {
        var options = PDFTranslationOptions()
        #expect(options.performance.requestsPerSecond == 4 && options.performance.effectiveTranslationWorkers == 4 && options.performance.effectiveTermWorkers == 4)
        #expect(options.performance.sameTextFallback && options.performance.sendTemperature && !options.performance.ignoreCache)
        #expect(options.performance.engineSettings["pool_max_workers"] == nil && options.performance.progressInterval == 0.1)
        options.performance.requestsPerSecond = 10; options.performance.translationWorkers = 2
        #expect(options.performance.effectiveTermWorkers == 2)
        options.performance.termWorkers = 1; #expect(options.performance.effectiveTermWorkers == 1)
        for qps in [0, -1, 101] { options.performance.requestsPerSecond = qps; #expect(throws: PDFPerformanceSettingsError.invalidLimit) { try options.validated() } }
        options.performance.requestsPerSecond = 4
        for interval in [Double.nan, .infinity, 0, 61] { options.performance.progressInterval = interval; #expect(throws: PDFPerformanceSettingsError.invalidInterval) { try options.validated() } }
        options.performance.progressInterval = 0.1; options.performance.reasoning = "bad\nvalue"
        #expect(throws: PDFPerformanceSettingsError.invalidReasoning) { try options.validated() }
        options.content.operation = .typesetOnly; options.performance.requestsPerSecond = -1
        _ = try options.validated()
        #expect(options.effectivePerformanceSettings["qps"] == nil && options.performance.requestsPerSecond == -1)
        #expect(options.effectivePerformanceSettings.count == 3)
        #expect(try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{}".utf8)).performance == PDFPerformanceSettings())
    }
    @Test func disabledTermExtractionRetainsDraftWithoutRejectingTranslation() throws {
        var options = PDFTranslationOptions(); options.autoExtractGlossary = false
        for inactive in [0, -1, 101] {
            options.performance.termWorkers = inactive
            let submitted = try options.validated()
            #expect(submitted.performance.termWorkers == inactive)
            #expect(submitted.effectivePerformanceSettings["term_pool_max_workers"] == nil)
            #expect(submitted.effectivePerformanceSettings["qps"] as? Int == 4)
            let reopened = try JSONDecoder().decode(PDFTranslationOptions.self, from: JSONEncoder().encode(submitted))
            #expect(reopened == submitted)
            options.autoExtractGlossary = true
            #expect(throws: PDFPerformanceSettingsError.invalidLimit) { try options.validated() }
            options.autoExtractGlossary = false
        }
    }
    @Test func persistedDiagnosticsKeepUnknownUsageAndIndependentHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"); var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil)); context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let store = PDFMaterialStore(root: root.appendingPathComponent("library")); var material = try store.importPDF(source)
        var options = PDFTranslationOptions(); options.performance.requestsPerSecond = 2; options.performance.translationWorkers = 3; options.performance.termWorkers = 1
        options.performance.ignoreCache = true; options.performance.sendTemperature = false; options.performance.thinking = .disabled; options.performance.reasoning = "low"
        let task = PDFBackgroundTask(provider: try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot, options: options)
        let staging = try store.stagingDirectory(task.id, materialID: material.id), output = staging.appendingPathComponent("generated.pdf")
        try FileManager.default.copyItem(at: source, to: output)
        let diagnostics = PDFRunDiagnostics(requestCount: 3, translationRequests: 2, termRequests: 1, translationCacheHits: 7, responsesWithUsage: 2, promptTokens: 40, completionTokens: 10, elapsedSeconds: 1.5)
        let generated = PDFEngineResult(outputs: [.init(kind: .dual, url: output)], diagnostics: diagnostics)
        let resultID = UUID()
        try store.savePendingResult(.init(task: task, generated: generated, resultID: resultID), materialID: material.id)
        let recovered = try #require(try store.pendingResult(task.id, materialID: material.id))
        #expect(recovered.generated.diagnostics == diagnostics)
        let result = try store.install(recovered.generated, task: task, material: material, resultID: resultID)
        material.results = [result]; material.selectedResultID = result.id; try store.save(material)
        options.performance = .init()
        let reopened = try #require(store.load().materials.first?.selectedResult)
        #expect(reopened.options.performance != options.performance && reopened.diagnostics == diagnostics)
        #expect(reopened.diagnostics?.summary(.english).contains("2/3 requests") == true)
        let unknown = PDFRunDiagnostics(requestCount: 1, translationRequests: 1, termRequests: 0, elapsedSeconds: 1)
        try unknown.validate(); #expect(unknown.promptTokens == nil && unknown.summary(.english).contains("not reported"))
        let encoded = try JSONEncoder().encode(unknown)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("promptTokens"))
        #expect(try Data(contentsOf: store.originalURL(material.id)) == Data(contentsOf: source))
    }
    @Test func malformedDiagnosticsCannotBecomeSavedSuccess() throws {
        let invalid = [PDFRunDiagnostics(requestCount: 2, translationRequests: 2, termRequests: 1, elapsedSeconds: 0),
            PDFRunDiagnostics(requestCount: 1, translationRequests: 1, termRequests: 0, responsesWithUsage: 0, promptTokens: 0, completionTokens: 0, elapsedSeconds: 0),
            PDFRunDiagnostics(requestCount: 0, translationRequests: 0, termRequests: 0, elapsedSeconds: .nan)]
        for value in invalid { #expect(throws: PDFTranslationError.invalidOutput) { try value.validate() } }
    }
}
