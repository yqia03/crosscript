import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct RecordingHistoryTests {
    @Test func historyContainsRecordedAndImportedTranscriptionsAndLeavesActiveCaptureUntouched() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        await fixture.recordings.importAudio(from: fixture.source, using: Importer())
        let imported = try #require(fixture.recordings.selectedRecording)
        let importedBytes = try Data(contentsOf: fixture.recordings.audioURL(for: imported.id))
        fixture.recordings.selectSource(.system)
        await fixture.recordings.start(workflow: .transcription)
        let activeID = try #require(fixture.recordings.activeID)
        let list = RecordingHistoryList(session: fixture.recordings, processing: fixture.processing, open: { _ in })
        #expect(Set(list.recordings.map(\.id)) == [imported.id, activeID])
        #expect(list.recordings.allSatisfy { $0.workflow == .transcription })
        #expect(fixture.recordings.recordings.count == 3)
        fixture.workbench.openAudioMaterial(imported.id)
        #expect(fixture.recordings.selectedID == imported.id)
        #expect(fixture.recordings.activeID == activeID && fixture.recordings.isRecording)
        #expect(fixture.recordings.activeRecording?.source == .system)
        #expect(!fixture.recordings.canCreateProject)
        fixture.recordings.newProject()
        #expect(fixture.recordings.selectedID == imported.id)
        #expect(fixture.recorder.starts == 1 && fixture.recorder.stops == 0)
        #expect(fixture.credentials.reads == 0 && fixture.service.calls == 0)
        #expect(fixture.processing.backgroundTasks.isEmpty)
        #expect(try Data(contentsOf: fixture.source) == fixture.sourceBytes)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: imported.id)) == importedBytes)
        fixture.recordings.stop()
    }

    @Test func openingHistoryRetainsPendingEditsAndResultSelectionWithoutUploading() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        await fixture.recordings.importAudio(from: fixture.source, using: Importer())
        let id = try #require(fixture.recordings.selectedID), old = UUID(), latest = UUID()
        #expect(fixture.processing.saveTranscriptResult(recordingID: id, resultID: old, createdAt: Date(),
            configuration: .init(), document: .init(text: "Original user version")))
        #expect(fixture.processing.saveTranscriptResult(recordingID: id, resultID: latest, createdAt: Date(),
            configuration: .init(), document: .init(text: "Latest result")))
        #expect(fixture.processing.selectResult(recordingID: id, resultID: old))
        let resultFile = fixture.recordings.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: resultFile)
        try FileManager.default.createDirectory(at: resultFile, withIntermediateDirectories: false)
        #expect(!fixture.processing.saveTranscriptText(recordingID: id, resultID: old, text: "User edit awaiting local save"))
        fixture.workbench.openAudioMaterial(fixture.liveID)
        fixture.workbench.openAudioMaterial(id)
        #expect(fixture.processing.hasUnsavedTranscript(recordingID: id))
        #expect(fixture.processing.selectedResult(recordingID: id)?.id == old)
        #expect(fixture.processing.selectedResult(recordingID: id)?.text == "User edit awaiting local save")
        #expect(!fixture.processing.selectResult(recordingID: id, resultID: latest))
        #expect(fixture.processing.materials[id]?.results.count == 2)
        try FileManager.default.removeItem(at: resultFile)
        fixture.processing.retrySaving()
        #expect(!fixture.processing.hasUnsavedTranscript(recordingID: id))
        #expect(try fixture.store.loadTranscription(for: id).results.first { $0.id == old }?.text == "User edit awaiting local save")
        #expect(fixture.credentials.reads == 0 && fixture.service.calls == 0)
        #expect(fixture.processing.backgroundTasks.isEmpty)
        #expect(try Data(contentsOf: fixture.source) == fixture.sourceBytes)
    }

    @Test func productionHistoryRendersEmptyAndPopulatedInBothLanguages() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.clean() }
        let originalLanguage = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "interfaceLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") }
        }
        #expect(RecordingHistoryList(session: fixture.recordings, processing: fixture.processing, open: { _ in }).recordings.isEmpty)
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language == "en" ? AppLanguage.english.rawValue : AppLanguage.zhHans.rawValue, forKey: "interfaceLanguage")
            try await render(fixture, name: "history-empty-\(language)", size: NSSize(width: 520, height: 440))
        }
        await fixture.recordings.importAudio(from: fixture.source, using: Importer())
        let id = try #require(fixture.recordings.selectedID)
        #expect(fixture.processing.saveTranscriptResult(recordingID: id, resultID: UUID(), createdAt: Date(),
            configuration: .init(), document: .init(text: "An editable saved transcription.")))
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language == "en" ? AppLanguage.english.rawValue : AppLanguage.zhHans.rawValue, forKey: "interfaceLanguage")
            try await render(fixture, name: "history-\(language)", size: NSSize(width: 700, height: 520))
            try await render(fixture, name: "history-narrow-\(language)", size: NSSize(width: 520, height: 520))
            try await render(fixture, name: "recording-workspace-narrow-\(language)", size: NSSize(width: 680, height: 640), workspace: true)
            try await render(fixture, name: "recording-workspace-wide-\(language)", size: NSSize(width: 1_280, height: 800), workspace: true)
        }
        #expect(fixture.credentials.reads == 0 && fixture.service.calls == 0)
    }

    private func render(_ fixture: Fixture, name: String, size: NSSize, workspace: Bool = false) async throws {
        let content = workspace ? AnyView(fixture.workbench) : AnyView(RecordingHistoryView(session: fixture.recordings, processing: fixture.processing, open: { _ in }))
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor))
            .tint(Color(red: 0.16, green: 0.47, blue: 0.53)).preferredColorScheme(.light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["WORKBENCH_RECORDING_HISTORY_OUTPUT"] {
            let folder = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-history-\(UUID())")
        let liveID = UUID()
        let sourceBytes = Data("Disposable imported audio test bytes".utf8)
        let recorder = Recorder(), credentials = Credentials(), service = Service()
        let store: RecordingStore
        let recordings: RecordingSession
        let source: URL
        lazy var processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
        lazy var providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        lazy var text = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        var workbench: WorkbenchView { .init(session: recordings, playback: PlaybackController(), processing: processing,
            providers: providers, translation: text, initialPage: .recording) }
        init() throws {
            store = RecordingStore(root: root)
            try store.save(.init(id: liveID, startedAt: Date(), defaultName: "Live only", name: "Live only", duration: 120, status: .saved, workflow: .liveTranslation))
            recordings = RecordingSession(store: store, recorder: recorder)
            source = root.appendingPathComponent("Imported interview with a longer descriptive filename.wav")
            try sourceBytes.write(to: source)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private struct Importer: AudioImporting {
        func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval {
            try Data(contentsOf: source).write(to: destination); return 123.5
        }
    }
    @MainActor private final class Recorder: AudioRecording {
        var currentTime: TimeInterval { 5 }; var power: Float { -40 }; var onFailure: ((Error) -> Void)?
        var starts = 0, stops = 0
        func requestPermission(for source: AudioSource) async throws {}
        func start(at url: URL, source: AudioSource) async throws { starts += 1; try Data([0]).write(to: url) }
        func pause() async throws {}; func resume() async throws {}; func stop() -> TimeInterval { stops += 1; return 5 }
    }
    @MainActor private final class Credentials: ProviderCredentials, AudioCredentials {
        var reads = 0
        func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw ProviderConfigurationError.credential }
        func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; throw AudioProcessingError.credential }
        func save(_ value: String, reference: ProviderCredentialReference) throws { throw ProviderConfigurationError.credential }
        func save(_ value: String, for configuration: AudioServiceConfiguration) throws { throw AudioProcessingError.credential }
        func delete(reference: ProviderCredentialReference) throws {}; func delete(for configuration: AudioServiceConfiguration) throws {}
    }
    private final class Service: TextTranslating, ProviderConnectionChecking, FileTranscribing, @unchecked Sendable {
        var calls = 0
        func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws { calls += 1; throw TextTranslationError.processing }
        func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { calls += 1; throw ProviderConfigurationError.network }
        func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { calls += 1; throw AudioProcessingError.processing }
    }
}
