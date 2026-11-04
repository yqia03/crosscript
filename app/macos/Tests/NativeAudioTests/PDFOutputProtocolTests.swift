import CoreGraphics
import PDFKit
import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite struct PDFOutputProtocolTests {
    @Test(arguments: [nil, PDFOutputSettings.Mode.translated, .bilingual])
    @MainActor func freshFormOutputsReachTaskWorkerHistoryAndIndividualExports(_ choice: PDFOutputSettings.Mode?) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-form-output-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Original synthetic PDFs stand in for the external worker's artifacts;
        // this verifies protocol and retention, not translation quality.
        let original = root.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(original as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let script = root.appendingPathComponent("controlled.sh")
        try Data("""
        root="$(dirname "$0")"
        cat > "$root/observed.json"
        output=$(/usr/bin/plutil -extract outputDirectory raw -o - "$root/observed.json")
        outputs=""
        if [ "$(/usr/bin/plutil -extract options.no_mono raw -o - "$root/observed.json")" = false ]; then
            cp "$root/source.pdf" "$output/mono.pdf"
            outputs="$(printf '{"kind":"mono","path":"%s/mono.pdf"}' "$output")"
        fi
        if [ "$(/usr/bin/plutil -extract options.no_dual raw -o - "$root/observed.json")" = false ]; then
            cp "$root/source.pdf" "$output/dual.pdf"
            if [ -n "$outputs" ]; then outputs="$outputs,"; fi
            outputs="$outputs$(printf '{"kind":"dual","path":"%s/dual.pdf"}' "$output")"
        fi
        printf '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[%s]}\\n' "$outputs"
        """.utf8).write(to: script)
        let draft = PDFSubmissionDraft()
        draft.contentSettings.operation = .typesetOnly
        if let choice { draft.outputSettings.mode = choice }
        let snapshot = try draft.snapshot(profiles: [], resources: nil)
        let expectedMode = choice ?? .both
        #expect(snapshot.options.output.mode == expectedMode)
        let store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: script, cacheDirectory: root)
        let session = PDFTranslationSession(store: store, credentials: OutputProtocolCredentials(), engine: engine)
        let materialID = try #require(session.importPDF(original))
        let taskID = try #require(session.submit(materialID: materialID, provider: snapshot.provider, options: snapshot.options))
        // Subsequent form edits cannot rewrite a submitted task.
        draft.outputSettings.mode = .translated
        let deadline = Date().addingTimeInterval(10)
        while session.hasActiveWork, Date() < deadline { await Task.yield() }
        #expect(!session.hasActiveWork && session.error == nil)
        let material = try #require(session.selectedMaterial)
        let task = try #require(material.tasks.first { $0.id == taskID })
        #expect(task.status == .completed && task.options.output.mode == expectedMode)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("observed.json"))) as? [String: Any])
        let settings = try #require(payload["options"] as? [String: Any])
        #expect(settings["no_mono"] as? Bool == (choice == .bilingual))
        #expect(settings["no_dual"] as? Bool == (choice == .translated))
        let reopened = PDFTranslationSession(store: store, credentials: OutputProtocolCredentials(), engine: engine)
        let result = try #require(reopened.selectedMaterial?.selectedResult)
        #expect(result.options.output.mode == expectedMode)
        let expectedKinds: Set<PDFOutputKind> = choice == .translated ? [.mono] : choice == .bilingual ? [.dual] : [.mono, .dual]
        #expect(Set(result.outputs.map(\.kind)) == expectedKinds)
        let selection = PDFOutputSelection()
        #expect(selection.kind == .dual)
        for kind in expectedKinds {
            selection.kind = kind
            let selected = try #require(selection.pdf(in: reopened))
            #expect(selected.url.lastPathComponent == kind.rawValue + ".pdf")
            #expect(PDFDocument(url: selected.url)?.pageCount == 1)
            let exported = root.appendingPathComponent("export-" + kind.rawValue + ".pdf")
            #expect(reopened.export(selected.url, to: exported))
            #expect(PDFDocument(url: exported)?.pageCount == 1)
            #expect(try Data(contentsOf: exported) == Data(contentsOf: selected.url))
        }
    }

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

@MainActor private final class OutputProtocolCredentials: ProviderCredentials {
    func read(reference: ProviderCredentialReference) throws -> String? { Issue.record("Local output processing read credentials"); return nil }
    func save(_ value: String, reference: ProviderCredentialReference) throws {}
    func delete(reference: ProviderCredentialReference) throws {}
}
