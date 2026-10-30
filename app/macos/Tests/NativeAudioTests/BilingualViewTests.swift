import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualViewTests {
    @Test func activeLiveWorkspaceRetainsReadersDuringUpdatesAndWidthChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root), results = BilingualResultStore(recordings: store)
        let recorder = LiveControlsRenderRecorder(), service = LiveControlsRenderService(), credentials = LiveControlsRenderCredentials()
        let recordings = RecordingSession(store: store, recorder: recorder)
        let state = BilingualSessionState { try results.publish($0) }
        let config = AudioServiceConfiguration(provider: .gemini)
        let live = LiveBilingualSession(recordings: recordings, credentials: credentials, service: service,
            presentation: state, responseTimeout: 5, capabilityAllowsStart: { $0 == config })
        let host = NSHostingView(rootView: LiveLayoutHost(state: state, recordings: recordings, live: live, configuration: config))
        host.frame = NSRect(x: 0, y: 0, width: 1_721, height: 1_130)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try #require(await live.start(configuration: config, direction: .englishToChinese))
        let continuation = try #require(service.continuation)
        var durations: [Double] = [], expectedSource = "", expectedTarget = ""
        for index in 0..<20 {
            let source = "Controlled source \(index). ", target = "受控译文 \(index)。"
            expectedSource += source; expectedTarget += target
            let began = ProcessInfo.processInfo.systemUptime
            continuation.yield(.text(channel: .source, eventID: "s-\(index)", delta: source, startOffset: nil, endOffset: nil, finished: nil))
            continuation.yield(.text(channel: .translation, eventID: "t-\(index)", delta: target, startOffset: nil, endOffset: nil, finished: nil))
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            durations.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
        }
        #expect(state.document.source.text == expectedSource)
        #expect(state.document.translation.text == expectedTarget)
        let initial = liveReaders(host)
        #expect(initial.count == 2)
        #expect(initial.contains { Array($0.string.utf8) == Array(expectedSource.utf8) })
        #expect(initial.contains { Array($0.string.utf8) == Array(expectedTarget.utf8) })
        for width in [680.0, 1_721.0] {
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
            let current = liveReaders(host)
            #expect(current.count == 2)
            #expect(initial.allSatisfy { original in current.contains { $0 === original } })
            #expect(current.contains { Array($0.string.utf8) == Array(expectedSource.utf8) })
            #expect(current.contains { Array($0.string.utf8) == Array(expectedTarget.utf8) })
        }
        await live.pause(); #expect(recordings.isPaused)
        await live.resume(); #expect(!recordings.isPaused)
        await live.stop()
        #expect(recorder.starts == 1 && service.connections == 2 && credentials.reads == 2)
        if let output = ProcessInfo.processInfo.environment["WORKBENCH_LIVE_LAYOUT_REPORT"] {
            let values: [String: Any] = ["updateMilliseconds": durations, "maximumMilliseconds": durations.max() ?? 0,
                "updates": durations.count, "readerCount": initial.count, "source": state.document.source.text,
                "translation": state.document.translation.text]
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
    private func liveReaders(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(liveReaders)
    }
    @Test func captionCompletenessStatusSurvivesReconnectHiddenChannelAndStopping() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-caption-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let output = ProcessInfo.processInfo.environment["WORKBENCH_BILINGUAL_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let recorder = BilingualViewRecorder()
        let recordings = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        let configuration = AudioServiceConfiguration(provider: .gemini)
        for language in ["zhHans", "english"] {
            UserDefaults.standard.set(language, forKey: "interfaceLanguage")
            let state = BilingualSessionState { $0 }
            let status = BilingualStatusView(state: state, localStatus: "Controlled local recording")
            #expect(status.completenessTitle == nil)
            let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
            state.receive(.configured, generation: token)
            state.receive(.text(channel: .source, eventID: "s", delta: "Retained source", elapsedMilliseconds: 100), generation: token)
            state.receive(.text(channel: .translation, eventID: "t", delta: "保留译文", elapsedMilliseconds: 200), generation: token)
            #expect(status.completenessTitle == nil)
            state.markMissing([.init(startFrame: 0, endFrame: 24_000)], channel: .source)
            state.markMissing([.init(startFrame: 0, endFrame: 24_000), .init(startFrame: 48_000, endFrame: 72_000)], channel: .translation)
            state.receive(.failed, generation: token)
            let expectedGaps = language == "english" ? "Gaps: source 1 · translation 2" : "待补齐：原文 1 段 · 译文 2 段"
            #expect(status.completenessTitle == expectedGaps)
            state.visibleChannels = [.source]
            let reconnect = UUID()
            state.beginReconnection(generation: reconnect)
            state.receive(.configured, generation: reconnect)
            #expect(state.cloudState == .connected)
            #expect(status.completenessTitle == expectedGaps)
            try render(BilingualCaptionView(state: state, recordings: recordings), width: 420, height: 320,
                       output: output?.appendingPathComponent("caption-reconnected-gap-\(language)-420.png"))
            state.finish(confirmedChannels: Set(BilingualChannel.allCases))
            let incomplete = language == "english" ? "Bilingual result incomplete" : "双语结果不完整"
            #expect(status.completenessTitle == incomplete + " · " + expectedGaps)
            state.visibleChannels = Set(BilingualChannel.allCases)
            try render(BilingualCaptionView(state: state, recordings: recordings), width: 420, height: 400,
                       output: output?.appendingPathComponent("caption-incomplete-gap-\(language)-420.png"))
            try render(BilingualCaptionView(state: state, recordings: recordings), width: 720, height: 320,
                       output: output?.appendingPathComponent("caption-incomplete-gap-\(language)-720.png"))
            try render(BilingualCaptionView(state: state, recordings: recordings), width: 320, height: 440,
                       output: output?.appendingPathComponent("caption-incomplete-gap-\(language)-320.png"))

            let unconfirmed = BilingualSessionState { $0 }
            _ = unconfirmed.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese)
            unconfirmed.finish()
            #expect(BilingualStatusView(state: unconfirmed, localStatus: "").completenessTitle == incomplete)

            var complete = BilingualTranscriptDocument()
            complete.append("Source", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
            complete.append("译文", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
            complete.finish()
            state.reopen(BilingualResult(recordingID: UUID(), configuration: configuration, direction: .englishToChinese, document: complete))
            #expect(status.completenessTitle == nil)
        }
        #expect(recorder.starts == 0)
    }

    @Test func liveControlsAndDisconnectedCaptureRenderBothLanguagesAndWidths() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-live-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let output = ProcessInfo.processInfo.environment["WORKBENCH_GEMINI_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let store = RecordingStore(root: root), results = BilingualResultStore(recordings: store)
        let recorder = LiveControlsRenderRecorder(), service = LiveControlsRenderService(), credentials = LiveControlsRenderCredentials()
        let recordings = RecordingSession(store: store, recorder: recorder)
        let state = BilingualSessionState { try results.publish($0) }
        let config = AudioServiceConfiguration(provider: .gemini)
        let live = LiveBilingualSession(recordings: recordings, credentials: credentials, service: service,
            presentation: state, responseTimeout: 0.02, capabilityAllowsStart: { $0 == config })
        try #require(await live.start(configuration: config, direction: .englishToChinese))
        let continuation = try #require(service.continuation)
        let sourceText = "Controlled active view. Each channel keeps its own text."
        let translatedText = "受控活动界面。原文与译文分别保留。"
        continuation.yield(.text(channel: .source, eventID: "source", delta: sourceText, startOffset: nil, endOffset: nil, finished: nil))
        continuation.yield(.text(channel: .translation, eventID: "translation", delta: translatedText, startOffset: nil, endOffset: nil, finished: nil))
        // Rendering blocks the main actor. Await actual delivery of both queued
        // channels before rendering or cancelling, rather than assuming yields
        // give the stream consumer enough scheduler turns.
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (state.document.source.text != sourceText || state.document.translation.text != translatedText),
              ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(state.document.source.text == sourceText, "Timed out waiting for source text before rendering")
        try #require(state.document.translation.text == translatedText, "Timed out waiting for translated text before rendering")
        for phase in ["connected", "disconnected"] {
            if phase == "disconnected" { live.cancelCloud() }
            for language in ["zhHans", "english"] {
                UserDefaults.standard.set(language, forKey: "interfaceLanguage")
                for width in [1120.0, 580.0] {
                    try render(BilingualTranscriptView(state: state, recordings: recordings, configuration: config,
                        openSettings: {}, openCaptions: {}, live: live, canStartRecording: false),
                        width: width, height: width < 600 ? 1750 : 1200,
                        output: output?.appendingPathComponent("\(phase)-\(language)-\(Int(width)).png"))
                }
                for width in [720.0, 320.0] {
                    try render(BilingualCaptionView(state: state, recordings: recordings, live: live),
                        width: width, height: 440,
                        output: output?.appendingPathComponent("caption-\(phase)-\(language)-\(Int(width)).png"))
                }
            }
        }
        #expect(recordings.isRecording && recorder.starts == 1 && service.connections == 1 && credentials.reads == 1)
        await live.stop()
        #expect(state.document.source.text == sourceText && state.document.translation.text == translatedText)
    }
    @Test func mainAndCaptionViewsShareStateAndRenderInBothLanguagesAndWidths() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = ProcessInfo.processInfo.environment["WORKBENCH_BILINGUAL_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let store = RecordingStore(root: root), id = UUID()
        try store.save(Recording(id: id, startedAt: Date(), defaultName: "Controlled bilingual", name: "Controlled bilingual", duration: 2, status: .saved))
        let bilingualStore = BilingualResultStore(recordings: store)
        let recorder = BilingualViewRecorder()
        let recordings = RecordingSession(store: store, recorder: recorder)
        let state = BilingualSessionState { _ in throw AudioProcessingError.storage }
        let configuration = AudioServiceConfiguration(provider: .openAI, model: "gpt-realtime-translate")
        let token = try #require(state.beginObservation(recordingID: id, configuration: configuration, direction: .englishToChinese))
        state.receive(.configured, generation: token)
        state.receive(.text(channel: .source, eventID: "s", delta: "Controlled rendering sample. Source words and translated words have independent event identities.", elapsedMilliseconds: 200), generation: token)
        state.receive(.text(channel: .translation, eventID: "t", delta: "受控布局样本。原文和译文分别保留事件关联，不按数组位置强行配对。", elapsedMilliseconds: 400), generation: token)
        state.markMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .translation)
        state.receive(.failed, generation: token); state.finish()
        #expect(state.needsSaveRetry && !state.document.isComplete)
        try bilingualStore.publish(#require(state.result))
        for language in ["zhHans", "english"] {
            UserDefaults.standard.set(language, forKey: "interfaceLanguage")
            for width in [1120.0, 580.0] {
                let main = BilingualTranscriptView(state: state, recordings: recordings, configuration: configuration,
                                                   openSettings: {}, openCaptions: {})
                try render(main, width: width, height: 1100, output: output?.appendingPathComponent("main-\(language)-\(Int(width)).png"))
                state.history(recordingID: id, store: bilingualStore).reload()
                let history = BilingualHistoryView(recordingID: id, store: bilingualStore, state: state, openLive: {})
                try render(history, width: width, height: 1000, output: output?.appendingPathComponent("history-\(language)-\(Int(width)).png"))
            }
            state.fontSize = 28; state.reviewEarlierText()
            for width in [700.0, 420.0] {
                let caption = BilingualCaptionView(state: state, recordings: recordings)
                try render(caption, width: width, height: 400, output: output?.appendingPathComponent("caption-\(language)-\(Int(width)).png"))
            }
        }
        #expect(recorder.starts == 0 && state.fontSize == 28 && !state.followsLatest)
        #expect(state.document.translation.text.hasPrefix("受控布局"))
    }
    @Test func blockedRepairViewRendersWithoutReadingCredentialsOrStartingCapture() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-repair-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let store = RecordingStore(root: root), id = UUID(), recorder = BilingualViewRecorder(), credentials = BilingualViewCredentials()
        try store.save(Recording(id: id, startedAt: Date(), defaultName: "Controlled", name: "Controlled", duration: 2, status: .saved))
        let recordingSession = RecordingSession(store: store, recorder: recorder)
        let session = BilingualRepairSession(recordings: recordingSession, results: BilingualResultStore(recordings: store),
            journal: BilingualRepairStore(recordings: store), credentials: credentials, service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
        var document = BilingualTranscriptDocument()
        document.addMissing([.init(startFrame: 0, endFrame: 24_000)], channel: .translation); document.finish()
        let configuration = AudioServiceConfiguration(provider: .aiHubMix, model: "gpt-live-transcribe")
        let source = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        let output = ProcessInfo.processInfo.environment["WORKBENCH_BILINGUAL_REPAIR_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["zhHans", "english"] {
            UserDefaults.standard.set(language, forKey: "interfaceLanguage")
            for width in [1120.0, 580.0] {
                try render(BilingualRepairView(session: session, source: source, configuration: configuration), width: width, height: 500,
                           output: output?.appendingPathComponent("repair-\(language)-\(Int(width)).png"))
            }
        }
        #expect(credentials.reads == 0 && recorder.starts == 0 && session.tasks.isEmpty)
    }
    @Test func restoredRepairFailuresExposeCategoriesAndRangeSpecificInterruptionToTheView() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-failure-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let store = RecordingStore(root: root), id = UUID(), credentials = BilingualViewCredentials()
        try store.save(Recording(id: id, startedAt: Date(), defaultName: "Controlled", name: "Controlled", duration: 2, status: .saved))
        let configuration = AudioServiceConfiguration(provider: .openAI, model: "controlled-only")
        var document = BilingualTranscriptDocument()
        document.addMissing([.init(startFrame: 0, endFrame: 24_000)], channel: .translation); document.finish()
        let source = BilingualResult(recordingID: id, configuration: configuration, direction: .chineseToEnglish, document: document)
        let results = BilingualResultStore(recordings: store), journal = BilingualRepairStore(recordings: store)
        try results.publish(source)
        for language in ["zhHans", "english"] {
            UserDefaults.standard.set(language, forKey: "interfaceLanguage")
            for failure in [AudioProcessingError.credential, .requestLimited, .modelUnavailable, .interrupted] {
                var task = BilingualRepairTask(source: source, configuration: configuration)
                task.status = .failed; task.failure = failure; task.parts[0].failure = .quotaExceeded
                try journal.save([task], recordingID: id)
                let session = BilingualRepairSession(recordings: RecordingSession(store: store, recorder: BilingualViewRecorder()), results: results,
                    journal: journal, credentials: credentials, service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
                let expected = failure == .interrupted ? (language == "english" ? "Manual resume submits only unfinished channels and ranges" : "手动继续只提交尚未完成的通道和区间") : failure.localizedDescription
                let view = BilingualRepairView(session: session, source: source, configuration: configuration)
                #expect(view.failureMessage(failure).contains(expected))
                #expect(view.failureMessage(.quotaExceeded) == AudioProcessingError.quotaExceeded.localizedDescription)
                #expect(!view.failureMessage(.interrupted).contains("resubmits all audio"))
                #expect(!view.failureMessage(.interrupted).contains("重新提交整份音频"))
                try render(view, width: 580, height: 800, output: nil)
            }
        }
        #expect(credentials.reads == 0)
    }
    @Test func pendingRepairEditorsRenderTheirRetainedUserChangesInBothLanguagesAndWidths() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-pending-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "interfaceLanguage") } else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") } }
        let store = RecordingStore(root: root), id = UUID(), credentials = BilingualViewCredentials()
        try store.save(Recording(id: id, startedAt: Date(), defaultName: "Controlled", name: "Controlled", duration: 2, status: .saved))
        let configuration = AudioServiceConfiguration(provider: .openAI, model: "controlled-only")
        var document = BilingualTranscriptDocument()
        document.addMissing([.init(startFrame: 0, endFrame: 24_000)], channel: .translation); document.finish()
        let source = BilingualResult(recordingID: id, configuration: configuration, direction: .chineseToEnglish, document: document)
        let results = BilingualResultStore(recordings: store), journal = BilingualRepairStore(recordings: store)
        try results.publish(source)
        var task = BilingualRepairTask(source: source, configuration: configuration)
        task.status = .awaitingLocalSave; task.parts[0].document = .init(text: "Generated repair")
        try journal.save([task], recordingID: id)
        let session = BilingualRepairSession(recordings: RecordingSession(store: store, recorder: BilingualViewRecorder()), results: results,
            journal: journal, credentials: credentials, service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
        session.editPending(task.id, text: "Pending source user edit", channel: .source)
        session.editPending(task.id, text: "待保存译文手改", channel: .translation)
        let output = ProcessInfo.processInfo.environment["WORKBENCH_BILINGUAL_REPAIR_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["zhHans", "english"] {
            UserDefaults.standard.set(language, forKey: "interfaceLanguage")
            for width in [1120.0, 580.0] {
                try render(BilingualRepairView(session: session, source: source, configuration: configuration), width: width, height: 1050,
                    output: output?.appendingPathComponent("repair-pending-\(language)-\(Int(width)).png"))
            }
        }
        #expect(session.tasks.first?.result.document.exported() == "Pending source user edit\n\n待保存译文手改")
        #expect(credentials.reads == 0)
    }
    private func render<V: View>(_ content: V, width: Double, height: Double, output: URL?) throws {
        let view = NSHostingView(rootView: content.frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        if let output { try data.write(to: output) }
    }
}
@MainActor private struct LiveLayoutHost: View {
    let state: BilingualSessionState
    let recordings: RecordingSession
    let live: LiveBilingualSession
    let configuration: AudioServiceConfiguration
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 22) {
                Color.clear.frame(width: geometry.size.width < 900 ? 64 : 190)
                ScrollView {
                    BilingualTranscriptView(state: state, recordings: recordings, configuration: configuration,
                        openSettings: {}, openCaptions: {}, live: live, canStartRecording: false,
                        readerHeight: geometry.size.width < 900 ? max(260, (geometry.size.height - 340) / 2) : max(300, geometry.size.height - 290))
                        .padding(24)
                }
            }
        }
    }
}
@MainActor private final class LiveControlsRenderRecorder: AudioRecording {
    var currentTime: TimeInterval { 1 }; var power: Float { -30 }; var onFailure: ((Error) -> Void)?
    var starts = 0
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { starts += 1; try Data([0]).write(to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 1 }
}
@MainActor private final class LiveControlsRenderCredentials: AudioCredentials {
    var reads = 0
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; return "controlled-only" }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
@MainActor private final class LiveControlsRenderService: LiveBilingualTranslating {
    var connections = 0
    var continuation: AsyncThrowingStream<LiveBilingualTransportEvent, Error>.Continuation?
    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection, apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> {
        connections += 1
        let pair = AsyncThrowingStream<LiveBilingualTransportEvent, Error>.makeStream()
        continuation = pair.continuation; continuation?.yield(.configured)
        return pair.stream
    }
    func append(_ chunk: LiveAudioChunk) async throws {}
    func finishInput() async throws {}
    func close() { continuation?.finish(); continuation = nil }
}
@MainActor private final class BilingualViewRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    var starts = 0
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { starts += 1 }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}

@MainActor private final class BilingualViewCredentials: AudioCredentials {
    var reads = 0
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; throw AudioProcessingError.credential }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
