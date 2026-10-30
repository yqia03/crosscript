import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import WorkbenchCore

/// Supported recording, PDF, and text owners remain independent under failure.
@Suite(.serialized) @MainActor struct ContinuousWorkflowIntegrationTests {
    @Test func recordingPDFAndTextStayIndependentAcrossCancellationDefaultsAndLateResults() async throws {
        let f = try CombinedFixture(); defer { f.remove() }
        await f.recordings.start()
        #expect(f.recordings.isRecording)
        let recordingID = try #require(f.recordings.activeID)
        try f.recorder.capture()
        let pdfID = try #require(f.pdf.importPDF(f.externalPDF))
        let oldPDF = try #require(f.pdf.submit(materialID: pdfID, provider: f.first.snapshot, options: .init()))
        try await settle { await f.engine.count == 1 }
        let waitingPDF = try #require(f.pdf.submit(materialID: pdfID, provider: f.first.snapshot, options: .init()))
        #expect(f.text.updateInput(text: "Original text request"))
        let oldTextWork = Task { await f.text.submit(provider: f.first.snapshot, direction: .englishToChinese) }
        try await settle { await f.textService.count == 1 }
        let oldText = try #require(f.text.workspace.currentResult)
        #expect(oldText.currentText == "partial 0")
        #expect(f.pdf.runningTaskID == oldPDF && f.gate.activeID == oldPDF)
        #expect(f.recordings.isRecording)
        f.providers.setDefault(f.second.id, for: .text)
        f.providers.setDefault(f.second.id, for: .pdf)
        f.recordings.selectSource(.system)
        #expect(f.recordings.activeRecording?.source == .microphone)
        #expect(await f.engine.requests[0].provider == f.first.snapshot)
        #expect(await f.textService.requests[0].provider == f.first.snapshot)

        f.pdf.cancel(materialID: pdfID, taskID: waitingPDF)
        f.pdf.cancel(materialID: pdfID, taskID: oldPDF)
        let nextPDF = try #require(f.pdf.submit(materialID: pdfID, provider: f.second.snapshot, options: .init()))
        #expect(f.gate.activeID == oldPDF)
        #expect(await f.engine.count == 1)
        f.text.stop()
        #expect(f.text.updateResult(resultID: oldText.id, text: "User edited stopped text"))
        #expect(f.text.updateInput(text: "New independent request"))
        let nextTextWork = Task { await f.text.submit(provider: f.second.snapshot, direction: .chineseToEnglish) }
        try await settle { await f.textService.count == 2 }
        await f.textService.finish(0)
        await oldTextWork.value
        #expect(f.text.history.first { $0.id == oldText.id }?.translation == "partial 0")
        #expect(f.text.workspace.currentResult?.currentText == "partial 1")
        await f.engine.finish(0)
        try await settle { await f.engine.count == 2 }
        #expect(f.pdf.runningTaskID == nextPDF && f.gate.activeID == nextPDF)
        #expect(f.pdf.selectedMaterial?.results.isEmpty == true)
        #expect(f.pdf.selectedMaterial?.tasks.first(where: { $0.id == waitingPDF })?.status == .cancelled)
        #expect(await f.engine.requests[1].provider == f.second.snapshot)
        try f.recorder.capture()
        await f.textService.finish(1)
        await nextTextWork.value
        await f.engine.finish(1)
        try await settle { f.pdf.runningTaskID == nil }
        f.recordings.stop()
        let textResult = try #require(f.text.workspace.currentResult)
        #expect(textResult.currentText == "partial 1 complete 1")
        #expect(textResult.provider == f.second.snapshot)
        #expect(f.pdf.selectedMaterial?.results.map(\.taskID) == [nextPDF])
        #expect(f.recordings.selectedRecording?.duration == 1)
        #expect(try f.recordingStore.loadTranscription(for: recordingID).results.isEmpty)
        #expect(f.recordings.selectedRecording?.status == .saved)
        let reopenedText = TextTranslationSession(store: f.textStore, credentials: f.credentials, service: f.textService)
        #expect(reopenedText.history.first { $0.id == oldText.id }?.translation == "partial 0")
        #expect(reopenedText.text(resultID: textResult.id) == textResult.currentText)
        let reopenedPDF = PDFTranslationSession(store: f.pdfStore, credentials: f.credentials, engine: f.engine)
        #expect(reopenedPDF.selectedMaterial?.results.count == 1)
        #expect(try Data(contentsOf: #require(f.pdf.originalURL(pdfID))) == Data(contentsOf: f.externalPDF))
        #expect(await f.engine.count == 2)
        #expect(await f.textService.count == 2)
    }

    @Test func textSaveFailureAndPDFNetworkFailureDoNotStopRecordingOrLoseEdits() async throws {
        let f = try CombinedFixture(); defer { f.remove() }
        await f.recordings.start()
        #expect(f.recordings.isRecording)
        let recordingID = try #require(f.recordings.activeID)
        try f.recorder.capture()
        let pdfID = try #require(f.pdf.importPDF(f.externalPDF))
        let failedPDF = try #require(f.pdf.submit(materialID: pdfID, provider: f.first.snapshot, options: .init()))
        try await settle { await f.engine.count == 1 }
        #expect(f.text.updateInput(text: "Preserve input across combined failures"))
        let textWork = Task { await f.text.submit(provider: f.first.snapshot, direction: .englishToChinese) }
        try await settle { await f.textService.count == 1 }
        await f.textService.fail(0, .rateLimited)
        await textWork.value
        let result = try #require(f.text.workspace.currentResult)
        #expect(result.failure == .rateLimited)
        let metadata = f.library.appendingPathComponent("TextWorkspace/workspace.json")
        let backup = f.root.appendingPathComponent("text-before-save-failure.json")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let userCopy = metadata.appendingPathComponent("user-copy.txt")
        try Data("retained copy".utf8).write(to: userCopy)
        #expect(f.text.updateResult(resultID: result.id, text: "Unsaved user edit survives"))
        #expect(!(await f.text.flushPendingSaves()))
        #expect(f.text.hasPendingSave)
        await f.engine.fail(0, .rateLimited)
        try await settle { f.pdf.runningTaskID == nil }
        #expect(f.pdf.selectedMaterial?.tasks.first?.failure == .rateLimited)
        #expect(f.recordings.isRecording)
        let retryPDF = try #require(f.pdf.retry(materialID: pdfID, taskID: failedPDF))
        try await settle { await f.engine.count == 2 }
        await f.engine.finish(1)
        try await settle { f.pdf.runningTaskID == nil }
        #expect(f.pdf.selectedMaterial?.results.map(\.taskID) == [retryPDF])
        #expect(f.text.text(resultID: result.id) == "Unsaved user edit survives")
        #expect(f.recordings.isRecording)
        try FileManager.default.moveItem(at: metadata, to: f.root.appendingPathComponent("preserved-text-copy"))
        // Restore the known material envelope; the store deliberately refuses
        // to adopt an unknown directory whose original metadata went missing.
        try FileManager.default.moveItem(at: backup, to: metadata)
        #expect(f.text.retrySaving())
        #expect(await f.textService.count == 1)
        f.recordings.stop()
        #expect(f.recordings.selectedRecording?.duration == 0.5)
        #expect(f.recordings.selectedRecording?.status == .saved)
        let reopened = TextTranslationSession(store: f.textStore, credentials: f.credentials, service: f.textService)
        #expect(reopened.text(resultID: result.id) == "Unsaved user edit survives")
        #expect(reopened.workspace.inputDraft == "Preserve input across combined failures")
        #expect(try String(contentsOf: f.root.appendingPathComponent("preserved-text-copy/user-copy.txt")) == "retained copy")
        #expect(try f.recordingStore.loadTranscription(for: recordingID).results.isEmpty)
        #expect(try Data(contentsOf: #require(f.pdf.originalURL(pdfID))) == Data(contentsOf: f.externalPDF))
    }
    private func settle(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }
}

@MainActor private final class CombinedFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("combined-workflow-\(UUID())")
    let library: URL, externalPDF: URL
    let recordingStore: RecordingStore, textStore: TextWorkspaceStore, pdfStore: PDFMaterialStore
    let recordings: RecordingSession, processing: PostRecordingSession
    let pdf: PDFTranslationSession, text: TextTranslationSession, providers: ProviderConfigurationSession
    let first: ProviderProfile, second: ProviderProfile
    let credentials = CombinedCredentials(), recorder = CombinedRecorder()
    let engine = CombinedPDFEngine(), textService = CombinedTextService(), gate = BackgroundProcessingGate()
    init() throws {
        library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        externalPDF = root.appendingPathComponent("controlled-input.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let drawing = try #require(CGContext(externalPDF as CFURL, mediaBox: &box, nil))
        drawing.beginPDFPage(nil); drawing.fill(CGRect(x: 20, y: 20, width: 30, height: 30)); drawing.endPDFPage(); drawing.closePDF()
        providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: library), credentials: credentials, checker: CombinedDirectory())
        first = try #require(providers.saveProfile(name: "Submitted provider", baseURL: "https://first.test/v1", model: "first-model", apiKey: "controlled-first"))
        second = try #require(providers.saveProfile(name: "Later default", baseURL: "https://second.test/v1", model: "second-model", apiKey: "controlled-second"))
        providers.setDefault(first.id, for: .text); providers.setDefault(first.id, for: .pdf)
        recordingStore = RecordingStore(root: library)
        recordings = RecordingSession(store: recordingStore, recorder: recorder)
        processing = PostRecordingSession(recordings: recordings, store: recordingStore, credentials: credentials, service: CombinedUnusedFileService(), gate: gate)
        textStore = TextWorkspaceStore(root: library); pdfStore = PDFMaterialStore(root: library)
        text = TextTranslationSession(store: textStore, credentials: credentials, service: textService)
        pdf = PDFTranslationSession(store: pdfStore, credentials: credentials, engine: engine, gate: gate)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class CombinedCredentials: ProviderCredentials, AudioCredentials {
    private var values: [ProviderCredentialReference: String] = [:]
    func read(reference: ProviderCredentialReference) throws -> String? { values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { configuration.provider == .aiHubMix ? "controlled-audio" : nil }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { throw AudioProcessingError.credential }
    func delete(for configuration: AudioServiceConfiguration) throws { throw AudioProcessingError.credential }
}
private struct CombinedDirectory: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { .directoryAvailable(modelListed: true, modelCount: 1) }
}
private struct CombinedUnusedFileService: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
}
private actor CombinedTextService: TextTranslating {
    var requests: [TextTranslationRequest] = []
    private var pending: [CheckedContinuation<Void, Error>] = []
    var count: Int { pending.count }
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        let index = requests.count; requests.append(request)
        await onEvent(.delta("partial \(index)"))
        try await withCheckedThrowingContinuation { pending.append($0) }
        await onEvent(.delta(" complete \(index)"))
    }
    func finish(_ index: Int) { pending[index].resume() }
    func fail(_ index: Int, _ error: TextTranslationError) { pending[index].resume(throwing: error) }
}
private actor CombinedPDFEngine: PDFTranslating {
    var requests: [PDFEngineRequest] = []
    private var pending: [CheckedContinuation<PDFEngineResult, Error>] = []
    var count: Int { pending.count }
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        requests.append(request); progress(.init(stage: "Controlled only", percent: 10))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int) {
        let request = requests[index], destination = requests[index].outputDirectory.appendingPathComponent("controlled-output.pdf")
        do {
            try FileManager.default.copyItem(at: request.inputURL, to: destination)
            pending[index].resume(returning: .init(outputs: [.init(kind: .dual, url: destination)]))
        } catch { pending[index].resume(throwing: error) }
    }
    func fail(_ index: Int, _ error: PDFTranslationError) { pending[index].resume(throwing: error) }
}
@MainActor private final class CombinedRecorder: AudioRecording {
    var currentTime: TimeInterval { Double(frames) / 24_000 }; var power: Float { -20 }
    var onFailure: ((Error) -> Void)?
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?, onLiveAudioFailure: (@Sendable (Error) -> Void)?
    private var active = false, file: URL?
    private(set) var frames: Int64 = 0
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { try Data("controlled recorder fixture".utf8).write(to: url); file = url; active = true; frames = 0 }
    func pause() async throws { active = false }
    func resume() async throws { active = true }
    func stop() -> TimeInterval { active = false; return currentTime }
    func capture() throws {
        guard active, let file else { return }
        let bytes = Data(repeating: 1, count: 24_000)
        let writer = try FileHandle(forWritingTo: file); defer { try? writer.close() }
        try writer.seekToEnd(); try writer.write(contentsOf: bytes)
        onLiveAudio?(try .init(pcm16: bytes, recordingStartFrame: frames)); frames += 12_000
    }
}
