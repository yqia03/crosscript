import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct PDFOutputProtocolTests {
    @Test func outputChoicesReachWorkerAlongsideTerminologyAndInvalidRangeNeverStartsWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("output-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controlled.sh")
        try Data("""
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}]}'
        """.utf8).write(to: script)
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        var options = PDFTranslationOptions()
        options.output.pages = "2-3"; options.output.onlyIncludeTranslatedPages = true; options.output.maximumPagesPerPart = 1
        options.output.mode = .both; options.output.layout = .alternatingPages; options.output.translatedFirst = true; options.output.watermark = .both
        options.autoExtractGlossary = false; options.resources = .init(prompt: .init(name: "Test", instruction: "Keep page markers."))
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot
        func request(_ options: PDFTranslationOptions) -> PDFEngineRequest {
            .init(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root, provider: provider, options: options)
        }
        _ = try await engine.translate(request(options), apiKey: "controlled") { _ in }
        let payloadFile = root.appendingPathComponent("observed.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: payloadFile)) as? [String: Any])
        let settings = try #require(object["options"] as? [String: Any])
        #expect(settings["pages"] as? String == "2-3")
        #expect(settings["no_mono"] as? Bool == false && settings["no_dual"] as? Bool == false)
        #expect(settings["max_pages_per_part"] as? Int == 1)
        #expect(settings["only_include_translated_page"] as? Bool == true)
        #expect(settings["use_alternating_pages_dual"] as? Bool == true && settings["dual_translate_first"] as? Bool == true)
        #expect(settings["watermark_output_mode"] as? String == "both")
        #expect(settings["auto_extract_glossary"] as? Bool == false)
        #expect(settings["custom_system_prompt"] as? String == "Keep page markers.")
        try FileManager.default.removeItem(at: payloadFile)
        options.output.pages = "0"
        do { _ = try await engine.translate(request(options), apiKey: "controlled") { _ in }; Issue.record("Invalid range started worker") }
        catch { #expect(error as? PDFOutputSettingsError == .invalidRange) }
        #expect(!FileManager.default.fileExists(atPath: payloadFile.path))
    }
}
