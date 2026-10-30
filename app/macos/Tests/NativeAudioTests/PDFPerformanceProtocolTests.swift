import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct PDFPerformanceProtocolTests {
    @Test func fullMappingAndSafeUsageSurviveNativeProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controlled.sh"), observed = root.appendingPathComponent("observed.json")
        try Data("""
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}],"diagnostics":{"requestCount":3,"translationRequests":2,"termRequests":1,"translationCacheHits":4,"termCacheHits":0,"responsesWithUsage":2,"promptTokens":200,"completionTokens":40,"elapsedSeconds":2.5}}'
        """.utf8).write(to: script)
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        var options = PDFTranslationOptions(); options.performance.requestsPerSecond = 7; options.performance.translationWorkers = 2; options.performance.termWorkers = 3
        options.performance.ignoreCache = true; options.performance.progressInterval = 0.5; options.performance.sameTextFallback = false
        options.performance.jsonModeWhenRequested = true; options.performance.dashScopeHeader = true; options.performance.sendTemperature = false
        options.performance.reasoning = "low"; options.performance.thinking = .disabled; options.performance.diagnosticPDF = true; options.performance.characterBoxes = true
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot
        func request(_ options: PDFTranslationOptions) -> PDFEngineRequest { .init(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root, provider: provider, options: options) }
        let result = try await engine.translate(request(options), apiKey: "CONTROLLED_SECRET") { _ in }
        #expect(result.diagnostics?.requestCount == 3 && result.diagnostics?.termRequests == 1 && result.diagnostics?.promptTokens == 200)
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("CONTROLLED_SECRET"))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: observed)) as? [String: Any])
        let settings = try #require(payload["options"] as? [String: Any])
        for (key, value) in options.performance.engineSettings { #expect((settings[key] as? NSObject) == (value as? NSObject), "Missing mapping: \(key)") }
        options.autoExtractGlossary = false; options.performance.termWorkers = 0
        _ = try await engine.translate(request(options), apiKey: "CONTROLLED_SECRET") { _ in }
        let inactivePayload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: observed)) as? [String: Any])
        let inactiveSettings = try #require(inactivePayload["options"] as? [String: Any])
        #expect(inactiveSettings["term_pool_max_workers"] == nil && inactiveSettings["auto_extract_glossary"] as? Bool == false)
        #expect(options.performance.termWorkers == 0)
        try FileManager.default.removeItem(at: observed)
        options.performance.requestsPerSecond = 0
        do { _ = try await engine.translate(request(options), apiKey: "CONTROLLED_SECRET") { _ in }; Issue.record("Invalid limit started worker") }
        catch { #expect(error as? PDFPerformanceSettingsError == .invalidLimit) }
        #expect(!FileManager.default.fileExists(atPath: observed.path))
    }
    @Test func malformedMetricsFailBeforePublishingResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controlled.sh")
        try Data("""
        cat >/dev/null
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}],"diagnostics":{"requestCount":-1,"translationRequests":0,"termRequests":0,"translationCacheHits":0,"termCacheHits":0,"responsesWithUsage":0,"elapsedSeconds":1}}'
        """.utf8).write(to: script)
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot
        do { _ = try await engine.translate(.init(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root, provider: provider, options: .init()), apiKey: "CONTROLLED") { _ in }; Issue.record("Malformed metrics accepted") }
        catch { #expect(error as? PDFTranslationError == .invalidOutput) }
    }
}
