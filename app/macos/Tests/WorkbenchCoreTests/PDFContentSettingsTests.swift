import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFContentSettingsTests {
    @Test func localOperationsNeedNoProviderOrCredentialAndPreserveUntranslatedHistory() async throws {
        let fixture = try ContentFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        let id = try #require(fixture.session.importPDF(fixture.source))
        for operation in [PDFContentSettings.Operation.typesetOnly, .parseOnly] {
            var options = PDFTranslationOptions(); options.content.operation = operation; options.output.watermark = .noWatermark
            options.content.scanMode = .forceWorkaround; options.autoExtractGlossary = false
            #expect(fixture.session.submit(materialID: id, provider: nil, options: options) != nil)
            try await fixture.settle()
            let result = try #require(fixture.session.selectedMaterial?.selectedResult)
            #expect(result.provider == nil && !result.options.requiresService)
            #expect(result.options.content.operation == operation)
            #expect(result.contentReport?.pagesWithoutExtractableText == 1)
            let url = try #require(fixture.session.resultURL(materialID: id, resultID: result.id, output: result.outputs[0]))
            #expect(PDFDocument(url: url)?.pageCount == 1)
            #expect(try Data(contentsOf: url) == original)
        }
        #expect(fixture.credentials.reads == 0)
        #expect(await fixture.engine.keys == ["", ""])
        #expect(await fixture.engine.requests.allSatisfy { $0.provider == nil && $0.termExtractionAPIKey == nil })
        let reopened = PDFTranslationSession(store: fixture.store, credentials: fixture.credentials, engine: fixture.engine)
        #expect(reopened.selectedMaterial?.results.count == 2)
        #expect(reopened.selectedMaterial?.selectedResult?.options.content.operation == .parseOnly)
        #expect(try Data(contentsOf: #require(reopened.originalURL(id))) == original)
    }
    @Test func contentFailureKeepsOriginalAndEarlierResultAndInvalidTargetNeverStarts() async throws {
        let fixture = try ContentFixture(); defer { fixture.remove() }
        let id = try #require(fixture.session.importPDF(fixture.source))
        var options = PDFTranslationOptions(); options.content.operation = .parseOnly; options.output.watermark = .noWatermark; options.autoExtractGlossary = false
        #expect(fixture.session.submit(materialID: id, provider: nil, options: options) != nil)
        try await fixture.settle()
        let earlier = try #require(fixture.session.selectedMaterial?.selectedResult)
        let output = try #require(fixture.session.resultURL(materialID: id, resultID: earlier.id, output: earlier.outputs[0]))
        let bytes = try Data(contentsOf: output)
        for failure in [PDFTranslationError.scannedDocument, .noExtractableText, .textExtraction, .runtimeUnavailable, .invalidFormulaPattern] {
            await fixture.engine.failNext(failure)
            #expect(fixture.session.submit(materialID: id, provider: nil, options: options) != nil)
            try await fixture.settle()
            #expect(fixture.session.selectedMaterial?.tasks.last?.failure == failure)
            #expect(fixture.session.selectedMaterial?.selectedResultID == earlier.id)
            #expect(try Data(contentsOf: output) == bytes)
            #expect(try Data(contentsOf: #require(fixture.session.originalURL(id))) == Data(contentsOf: fixture.source))
        }
        let provider = try ProviderProfile(name: "Wrong target", baseURL: "https://example.test", model: "model").snapshot
        #expect(fixture.session.submit(materialID: id, provider: provider, options: options) == nil)
        options.content.operation = .translate
        #expect(fixture.session.submit(materialID: id, provider: nil, options: options) == nil)
        options.content.operation = .parseOnly; options.content.minimumTextLength = -1
        #expect(fixture.session.submit(materialID: id, provider: nil, options: options) == nil)
        #expect(await fixture.engine.requests.count == 6)
        #expect(fixture.credentials.reads == 0)
    }
    @Test func scanModesHaveExclusiveDependenciesAndOldSnapshotsKeepDefaults() throws {
        var value = PDFContentSettings()
        #expect(value.requiresService && value.minimumTextLength == 5 && value.processGraphicElements)
        for mode in PDFContentSettings.ScanMode.allCases {
            value.scanMode = mode
            let settings = value.engineSettings
            #expect(settings["ocr_workaround"] as? Bool == (mode == .forceWorkaround))
            #expect(settings["auto_enable_ocr_workaround"] as? Bool == (mode == .automaticWorkaround))
            #expect(settings["skip_scanned_detection"] as? Bool == (mode == .skipDetection || mode == .forceWorkaround))
        }
        value.minimumTextLength = 0; try value.validate()
        value.minimumTextLength = -1
        #expect(throws: PDFContentSettingsError.invalidMinimumLength) { try value.validate() }
        var parse = PDFTranslationOptions(); parse.content.operation = .parseOnly
        #expect(throws: PDFContentSettingsError.parseOnlyRequiresNoWatermark) { try parse.validated() }
        parse.output.watermark = .noWatermark; _ = try parse.validated()
        let options = try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{\"direction\":\"englishToChinese\"}".utf8))
        #expect(options.content == PDFContentSettings() && options.requiresService)
    }
}
@MainActor private final class ContentFixture {
    let root: URL, source: URL, store: PDFMaterialStore
    let credentials = NoContentCredentials(), engine = ContentEngine()
    let session: PDFTranslationSession
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-content-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.fill(CGRect(x: 20, y: 20, width: 50, height: 50)); context.endPDFPage(); context.closePDF()
        store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        session = PDFTranslationSession(store: store, credentials: credentials, engine: engine)
    }
    func settle() async throws {
        for _ in 0..<300 { if session.runningTaskID == nil { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(session.runningTaskID == nil)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class NoContentCredentials: ProviderCredentials {
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw PDFTranslationError.credential }
    func save(_ value: String, reference: ProviderCredentialReference) throws { Issue.record("Unexpected credential save") }
    func delete(reference: ProviderCredentialReference) throws { Issue.record("Unexpected credential deletion") }
}
private actor ContentEngine: PDFTranslating {
    var keys: [String] = [], requests: [PDFEngineRequest] = []
    private var failure: PDFTranslationError?
    func failNext(_ error: PDFTranslationError) { failure = error }
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        requests.append(request); keys.append(apiKey)
        if let failure { self.failure = nil; throw failure }
        let output = request.outputDirectory.appendingPathComponent("local.pdf")
        try FileManager.default.copyItem(at: request.inputURL, to: output)
        return .init(outputs: [.init(kind: .dual, url: output)], contentReport: .init(sourcePageCount: 1, selectedPageCount: 1, pagesWithoutExtractableText: 1))
    }
}
