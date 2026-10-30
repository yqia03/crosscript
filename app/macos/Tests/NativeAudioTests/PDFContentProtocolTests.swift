import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct PDFContentProtocolTests {
    @Test func localWorkerReceivesNoTargetOrKeyAndContentReportReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controlled.sh")
        try Data("""
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}],"contentReport":{"sourcePageCount":3,"selectedPageCount":2,"pagesWithoutExtractableText":1}}'
        """.utf8).write(to: script)
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        var options = PDFTranslationOptions(); options.content.operation = .typesetOnly
        options.content.scanMode = .forceWorkaround; options.content.processGraphicElements = false; options.content.minimumTextLength = 8
        let request = PDFEngineRequest(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root, provider: nil, options: options)
        let result = try await engine.translate(request, apiKey: "") { _ in }
        #expect(result.contentReport == .init(sourcePageCount: 3, selectedPageCount: 2, pagesWithoutExtractableText: 1))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("observed.json"))) as? [String: Any])
        #expect(object["provider"] == nil && object["termExtraction"] == nil)
        #expect(object["apiKey"] as? String == "")
        let settings = try #require(object["options"] as? [String: Any])
        #expect(settings["skip_translation"] as? Bool == true && settings["only_parse_generate_pdf"] as? Bool == false)
        #expect(settings["ocr_workaround"] as? Bool == true && settings["skip_scanned_detection"] as? Bool == true)
        #expect(settings["auto_enable_ocr_workaround"] as? Bool == false)
        #expect(settings["min_text_length"] as? Int == 8 && settings["enable_graphic_element_process"] as? Bool == false)
        #expect(settings["auto_extract_glossary"] as? Bool == false && settings["save_auto_extracted_glossary"] as? Bool == false)
    }
}
