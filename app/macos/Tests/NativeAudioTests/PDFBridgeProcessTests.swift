import Foundation
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) struct PDFBridgeProcessTests {
    @Test func pdfLanguageCatalogMatchesBridgeSupportAndAliases() throws {
        let catalog = TranslationLanguageCatalog.pdf.languages
        let aliases = ["zh-Hans": "zh", "zh_CN": "zh", "zh-Hant": "zh-tw",
                       "fil": "tl", "pt-PT": "pt", "nb": "no", "PT_br": "pt-br"]
        let requestedCodes = Set(catalog.flatMap { [$0.rawValue, $0.babelDOCCode] }).union(aliases.keys).sorted()
        let bridge = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("workbench_bridge", sys.argv[1])
        bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bridge)
        codes = json.load(sys.stdin)
        print(json.dumps({
            "supported": sorted(bridge.SUPPORTED_LANGUAGE_CODES),
            "normalized": {code: bridge.language_code(code) for code in codes},
            "sources": {code: bridge.translation_languages({"sourceLanguage": code, "targetLanguage": "en"})[0] for code in codes},
            "targets": {code: bridge.translation_languages({"sourceLanguage": "en", "targetLanguage": code})[1] for code in codes},
        }))
        """, bridge.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(requestedCodes))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Python bridge contract failed: \(String(decoding: diagnostics, as: UTF8.self))")
        struct Contract: Decodable {
            let supported: [String]
            let normalized: [String: String]
            let sources: [String: String]
            let targets: [String: String]
        }
        let contract = try JSONDecoder().decode(Contract.self, from: data)
        #expect(Set(contract.supported) == Set(catalog.map { $0.babelDOCCode.lowercased() }))
        for language in catalog {
            let expected = language.babelDOCCode.lowercased()
            for code in [language.rawValue, language.babelDOCCode] {
                #expect(contract.normalized[code] == expected)
                #expect(contract.sources[code] == expected)
                #expect(contract.targets[code] == expected)
            }
        }
        for (alias, expected) in aliases {
            #expect(TranslationLanguage(rawValue: alias).babelDOCCode.lowercased() == expected)
            #expect(contract.normalized[alias] == expected)
            #expect(contract.sources[alias] == expected)
            #expect(contract.targets[alias] == expected)
        }
    }

    @Test func selectedJapaneseToFrenchPairReachesPDFWorker() async throws {
        let fixture = try ProcessFixture(script: """
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}]}'
        """)
        defer { fixture.remove() }
        let direction = try #require(TextTranslationDirection(rawValue: "ja>fr"))
        let request = PDFEngineRequest(id: UUID(), inputURL: fixture.request.inputURL, outputDirectory: fixture.request.outputDirectory,
            provider: fixture.request.provider, options: .init(direction: direction))
        _ = try await fixture.engine.translate(request, apiKey: "controlled-key") { _ in }
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("observed.json"))) as? [String: Any])
        #expect(payload["sourceLanguage"] as? String == "ja")
        #expect(payload["targetLanguage"] as? String == "fr")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_PDF_RUNTIME"] != nil,
                   "Requires the managed Python runtime; Apple's system Python can disable bytecode writes by default."))
    func pythonImportsLeaveBridgeResourcesUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-python-resources-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources/PDF", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bridge = resources.appendingPathComponent("bridge.py")
        let module = resources.appendingPathComponent("bundled_helper.py")
        let bridgeBytes = Data("""
        import json, pathlib, sys
        import bundled_helper
        request = json.load(sys.stdin)
        output = pathlib.Path(request["outputDirectory"])
        output.mkdir(parents=True)
        result = output / "controlled.pdf"
        result.write_bytes(bundled_helper.pdf_bytes)
        print(json.dumps({"type": "finished", "engine": "0.6.4", "integration": 1,
                          "outputs": [{"kind": "dual", "path": str(result)}]}))
        """.utf8)
        let moduleBytes = Data("pdf_bytes = b'%PDF-1.4 controlled imported output'\n".utf8)
        try bridgeBytes.write(to: bridge)
        try moduleBytes.write(to: module)
        let pythonRoot = try #require(ProcessInfo.processInfo.environment["WORKBENCH_PDF_RUNTIME"])
        let engine = BabelDOCPDFTranslator(pythonURL: URL(fileURLWithPath: pythonRoot).appendingPathComponent("bin/python3"),
            bridgeURL: bridge, cacheDirectory: root.appendingPathComponent("cache"))
        var options = PDFTranslationOptions()
        options.content.operation = .typesetOnly
        let request = PDFEngineRequest(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"),
            outputDirectory: root.appendingPathComponent("output"), provider: nil, options: options)

        let result = try await engine.translate(request, apiKey: "") { _ in }

        let output = try #require(result.outputs.first)
        #expect(output.kind == .dual)
        #expect(try Data(contentsOf: output.url) == Data("%PDF-1.4 controlled imported output".utf8))
        #expect(try Data(contentsOf: bridge) == bridgeBytes)
        #expect(try Data(contentsOf: module) == moduleBytes)
        let resourceNames = try Set(FileManager.default.contentsOfDirectory(atPath: resources.path))
        #expect(resourceNames == ["bridge.py", "bundled_helper.py"])
    }
    @Test func selectedResourcesReachProcessBoundaryWithIndependentTargetKeys() async throws {
        let fixture = try ProcessFixture(script: """
        cat > "$(dirname "$0")/observed.json"
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"},{"kind":"glossaryCSV","path":"/tmp/controlled.csv"}]}'
        """)
        defer { fixture.remove() }
        var options = PDFTranslationOptions()
        options.resources = .init(glossaries: [.init(name: "Named glossary", entries: [.init(source: "cache", target: "缓存", targetLanguage: "zh")])], prompt: .init(name: "Custom", instruction: "Be precise."))
        options.termExtractionProvider = try ProviderProfile(name: "Terms", baseURL: "https://terms.test/v1", model: "extract").snapshot
        options.termExtractionReasoning = "low"; options.saveAutoExtractedGlossary = true
        let request = PDFEngineRequest(id: UUID(), inputURL: fixture.request.inputURL, outputDirectory: fixture.request.outputDirectory, provider: fixture.request.provider, options: options, termExtractionAPIKey: "term-sentinel")
        let result = try await fixture.engine.translate(request, apiKey: "primary-sentinel") { _ in }
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("observed.json"))) as? [String: Any])
        #expect(payload["apiKey"] as? String == "primary-sentinel")
        let extraction = try #require(payload["termExtraction"] as? [String: Any])
        #expect(extraction["apiKey"] as? String == "term-sentinel")
        #expect(extraction["reasoning"] as? String == "low")
        let settings = try #require(payload["options"] as? [String: Any])
        #expect(settings["custom_system_prompt"] as? String == "Be precise.")
        #expect(settings["save_auto_extracted_glossary"] as? Bool == true)
        let resources = try #require(payload["resources"] as? [String: Any])
        #expect((resources["glossaries"] as? [[String: Any]])?.first?["name"] as? String == "Named glossary")
        #expect(result.outputs.map(\.kind) == [.dual, .glossaryCSV])
    }
    @Test func successWaitsForActualProcessExitAndSecretsNeverEnterArguments() async throws {
        let fixture = try ProcessFixture(script: """
        read payload
        case "$*" in *sensitive-sentinel*) exit 4;; esac
        printf '%s\\n' '{"type":"progress","stage":"Parse PDF","progress":30}'
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}]}'
        exec /bin/sleep 0.2
        """)
        defer { fixture.remove() }
        let start = Date()
        let result = try await fixture.engine.translate(fixture.request, apiKey: "sensitive-sentinel") { _ in }
        #expect(Date().timeIntervalSince(start) >= 0.18)
        #expect(result.outputs.first?.kind == .dual)
    }
    @Test func cancellationEscalatesAndReturnsOnlyAfterUncooperativeProcessExits() async throws {
        let fixture = try ProcessFixture(script: """
        read payload
        trap '' TERM
        printf '%s\\n' '{"type":"progress","stage":"running","progress":1}'
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let started = ProcessSignal()
        let task = Task { try await fixture.engine.translate(fixture.request, apiKey: "sentinel") { _ in Task { await started.signal() } } }
        await started.wait()
        let time = Date(); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled worker unexpectedly completed") }
        catch { #expect(error as? PDFTranslationError == .cancelled) }
        #expect(Date().timeIntervalSince(time) >= 1.8)
        #expect(Date().timeIntervalSince(time) < 5)
    }
    @Test func explicitFailureWinsOverAnEarlierFinishedEvent() async throws {
        let fixture = try ProcessFixture(script: """
        read payload
        printf '%s\\n' '{"type":"finished","engine":"0.6.4","integration":1,"outputs":[{"kind":"dual","path":"/tmp/controlled.pdf"}]}'
        printf '%s\\n' '{"type":"failed","code":"rateLimited"}'
        exit 1
        """)
        defer { fixture.remove() }
        do { _ = try await fixture.engine.translate(fixture.request, apiKey: "sentinel") { _ in }; Issue.record("Failure accepted as success") }
        catch { #expect(error as? PDFTranslationError == .rateLimited) }
    }
}
private struct ProcessFixture {
    let root: URL, engine: BabelDOCPDFTranslator, request: PDFEngineRequest
    init(script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-process-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("controlled.sh"); try Data(script.utf8).write(to: path)
        engine = .init(pythonURL: URL(fileURLWithPath: "/bin/sh"), bridgeURL: path, cacheDirectory: root.appendingPathComponent("cache"))
        request = .init(id: UUID(), inputURL: root.appendingPathComponent("source.pdf"), outputDirectory: root.appendingPathComponent("output"),
            provider: try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test/v1", model: "test").snapshot, options: .init())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private actor ProcessSignal {
    var ready = false
    func signal() { ready = true }
    func wait() async { while !ready { try? await Task.sleep(for: .milliseconds(10)) } }
}
