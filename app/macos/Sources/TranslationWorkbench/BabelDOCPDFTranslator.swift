import Darwin
import Foundation
import WorkbenchCore

struct BabelDOCPDFTranslator: PDFTranslating {
    let pythonURL: URL
    let bridgeURL: URL
    let cacheDirectory: URL
    let maximumRequests: Int
    init(pythonURL: URL, bridgeURL: URL, cacheDirectory: URL, maximumRequests: Int = 10_000) {
        self.pythonURL = pythonURL; self.bridgeURL = bridgeURL; self.cacheDirectory = cacheDirectory
        self.maximumRequests = min(10_000, max(1, maximumRequests))
    }
    static func managed(dataRoot: URL) -> Self {
        let layout = PDFRuntimeLayout(dataRoot: dataRoot)
        let environment = ProcessInfo.processInfo.environment
        let python = environment["WORKBENCH_PDF_RUNTIME"].map { URL(fileURLWithPath: $0).appendingPathComponent("bin/python3") } ?? layout.python
        let requestLimit = environment["WORKBENCH_PDF_REQUEST_LIMIT"].flatMap(Int.init).map { min(10_000, max(1, $0)) } ?? 10_000
        return .init(pythonURL: python,
            bridgeURL: Bundle.main.resourceURL!.appendingPathComponent("PDF/babeldoc_bridge.py"),
            cacheDirectory: layout.assets, maximumRequests: requestLimit)
    }

    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path), FileManager.default.fileExists(atPath: bridgeURL.path) else { throw PDFTranslationError.runtimeUnavailable }
        _ = try request.options.validated()
        guard request.options.requiresService == (request.provider != nil) else { throw PDFTranslationError.configuration }
        _ = try request.provider?.validated()
        let control = PDFProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try run(request, apiKey: apiKey, progress: progress, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.cancel() })
    }
    private func run(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void, control: PDFProcessControl) throws -> PDFEngineResult {
        let process = Process(); process.executableURL = pythonURL; process.arguments = ["-u", bridgeURL.path]
        // Avoid inheriting provider keys, PYTHONPATH or proxy routing from the shell.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let provider = request.provider
        let resourceData = try JSONEncoder().encode(request.options.requiresService ? request.options.resources : TranslationResourceSnapshot())
        let resourceObject = try JSONSerialization.jsonObject(with: resourceData)
        var settings = request.options.effectiveOutput.engineSettings.merging(request.options.content.engineSettings) { _, content in content }
        settings.merge(request.options.effectiveLayoutSettings) { _, layout in layout }
        settings.merge(request.options.effectivePerformanceSettings) { _, performance in performance }
        settings["auto_extract_glossary"] = request.options.requiresService && request.options.autoExtractGlossary
        settings["save_auto_extracted_glossary"] = request.options.requiresService && request.options.saveAutoExtractedGlossary
        if request.options.requiresService, let prompt = request.options.resources.prompt { settings["custom_system_prompt"] = prompt.instruction }
        var payload: [String: Any] = ["protocol": 1, "inputFile": request.inputURL.path,
            "outputDirectory": request.outputDirectory.path, "workingDirectory": request.outputDirectory.appendingPathComponent("working").path,
            "cacheDirectory": cacheDirectory.path, "direction": request.options.direction.rawValue,
            "sourceLanguage": request.options.direction.sourceLanguage.babelDOCCode,
            "targetLanguage": request.options.direction.targetLanguage.babelDOCCode,
            "apiKey": apiKey, "options": settings, "resources": resourceObject, "maximumRequests": maximumRequests]
        if let provider { payload["provider"] = ["profileID": provider.profileID.uuidString, "baseURL": provider.baseURL, "model": provider.model] }
        if request.options.requiresService, let term = request.options.termExtractionProvider {
            guard let key = request.termExtractionAPIKey, !key.isEmpty else { throw PDFTranslationError.credential }
            var extraction: [String: Any] = ["provider": ["profileID": term.profileID.uuidString, "baseURL": term.baseURL, "model": term.model], "apiKey": key]
            if let reasoning = request.options.termExtractionReasoning { extraction["reasoning"] = reasoning }
            payload["termExtraction"] = extraction
        }
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([10])
        try control.start(process)
        do { try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close() }
        catch { control.cancel() }
        var buffer = Data(), result: PDFEngineResult?, failure: PDFTranslationError?, totalBytes = 0
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            totalBytes += chunk.count
            guard totalBytes <= 16 * 1024 * 1024 else { failure = .processing; control.cancel(); break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard line.count <= 1024 * 1024, let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else { failure = .processing; continue }
                switch type {
                case "progress":
                    if let stage = event["stage"] as? String, let percent = event["progress"] as? Double, percent.isFinite {
                        progress(.init(stage: String(stage.prefix(200)), percent: min(100, max(0, percent))))
                    }
                case "failed": failure = (event["code"] as? String).flatMap(PDFTranslationError.init(rawValue:)) ?? .processing
                case "finished":
                    guard result == nil, let version = event["engine"] as? String, version == "0.6.4",
                          let integration = event["integration"] as? Int, integration == 1,
                          let outputs = event["outputs"] as? [[String: String]], !outputs.isEmpty else { failure = .invalidOutput; continue }
                    let values = outputs.compactMap { row -> PDFGeneratedOutput? in
                        guard let kind = row["kind"].flatMap(PDFOutputKind.init(rawValue:)), let path = row["path"] else { return nil }
                        return .init(kind: kind, url: URL(fileURLWithPath: path))
                    }
                    if values.count == outputs.count {
                        var report: PDFContentReport?
                        if let content = event["contentReport"] {
                            guard let data = try? JSONSerialization.data(withJSONObject: content), let decoded = try? JSONDecoder().decode(PDFContentReport.self, from: data),
                                  decoded.sourcePageCount > 0, decoded.selectedPageCount > 0, decoded.selectedPageCount <= decoded.sourcePageCount,
                                  (0...decoded.selectedPageCount).contains(decoded.pagesWithoutExtractableText) else { failure = .invalidOutput; continue }
                            report = decoded
                        }
                        var diagnostics: PDFRunDiagnostics?
                        if let value = event["diagnostics"] {
                            guard let data = try? JSONSerialization.data(withJSONObject: value), let decoded = try? JSONDecoder().decode(PDFRunDiagnostics.self, from: data),
                                  (try? decoded.validate()) != nil else { failure = .invalidOutput; continue }
                            diagnostics = decoded
                        }
                        result = .init(outputs: values, engineVersion: version, integrationVersion: integration, contentReport: report, diagnostics: diagnostics)
                    }
                    else { failure = .invalidOutput }
                default: failure = .processing
                }
            }
        }
        process.waitUntilExit()
        if control.wasCancelled { throw PDFTranslationError.cancelled }
        if let failure { throw failure }
        guard process.terminationStatus == 0, let result else { throw PDFTranslationError.processing }
        return result
    }
}

private final class PDFProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw PDFTranslationError.cancelled }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // Process ownership is retained; no queue slot is released until waitUntilExit.
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
}
