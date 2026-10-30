import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct LiveWorkspaceLayoutTests {
    @Test func productionLiveHeaderKeepsSourceAdjacentAndActionsAtRightEdge() async throws {
        _ = NSApplication.shared
        let preferences = UserDefaults(suiteName: "LiveHeaderGeometry." + UUID().uuidString)!
        var measurements: [[String: Any]] = []
        for (language, source, variant) in [
            ("zhHans", AudioSource.microphone, "zh-default"),
            ("english", AudioSource.microphoneDevice(.init(uid: "layout-only", name: "Studio Display Microphone — Conference Room External USB Audio Interface")), "en-long")
        ] {
            preferences.set(language, forKey: "interfaceLanguage")
            for saved in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-header-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let credentials = LayoutCredentials(), service = LayoutService()
                let store = RecordingStore(root: root), recordingID = UUID()
                let resultStore = BilingualResultStore(recordings: store)
                if saved {
                    try store.save(Recording(id: recordingID, startedAt: Date(), defaultName: "Controlled saved live recording", name: "Controlled saved live recording", duration: 2, status: .saved, source: source, workflow: .liveTranslation))
                    var document = BilingualTranscriptDocument()
                    document.append("Controlled saved source text.", channel: .source, eventID: "saved-source", elapsedMilliseconds: 0, connectionStartFrame: 0)
                    document.append("受控已保存译文。", channel: .translation, eventID: "saved-translation", elapsedMilliseconds: 0, connectionStartFrame: 0)
                    document.finish()
                    try resultStore.publish(BilingualResult(recordingID: recordingID, configuration: .init(provider: .gemini), direction: .englishToChinese, document: document))
                }
                let recordings = RecordingSession(store: store, recorder: LayoutRecorder())
                recordings.selectSource(source)
                let processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
                let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
                let text = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
                let state = BilingualSessionState { $0 }
                let live = LiveBilingualSession(recordings: recordings, credentials: credentials, service: LayoutBilingual(), presentation: state)
                var frames: [String: CGRect] = [:]
                let host = NSHostingView(rootView: WorkbenchView(session: recordings, playback: PlaybackController(), processing: processing, providers: providers, translation: text, bilingual: state, bilingualStore: resultStore, bilingualLive: live, initialPage: .live).defaultAppStorage(preferences).environment(\.liveToolbarGeometryObserver, { frames[$0] = $1 }))
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil }
                for size in [NSSize(width: 1280, height: 800), NSSize(width: 680, height: 640), NSSize(width: 1900, height: 1270)] {
                    window.setContentSize(size); host.frame.size = size
                    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
                    let sourceRect = try #require(frames["source"]), startRect = try #require(frames["start"]), moreRect = try #require(frames["more"])
                    let readers = descendants(host).compactMap { $0 as? LiveReaderScrollView }
                    if saved {
                        #expect(state.result?.recordingID == recordingID)
                        #expect(readers.contains { ($0.documentView as? NSTextView)?.string == "Controlled saved source text." })
                        #expect(readers.contains { ($0.documentView as? NSTextView)?.string == "受控已保存译文。" })
                    }
                    let cardRight = try #require(readers.map { $0.convert($0.bounds, to: host).maxX }.max()) + 18
                    #expect(abs(try #require(frames["header"]).maxX - cardRight) <= 1)
                    let gap = startRect.minX - sourceRect.maxX, rightInset = cardRight - moreRect.maxX
                    print("LIVE_HEADER \(variant) saved=\(saved) width=\(Int(size.width)) source=\(sourceRect) start=\(startRect) more=\(moreRect) gap=\(gap) rightInset=\(rightInset)")
                    measurements.append(["variant": variant, "saved": saved, "width": size.width, "source": NSStringFromRect(sourceRect), "start": NSStringFromRect(startRect), "more": NSStringFromRect(moreRect), "sourceStartGap": gap, "rightInset": rightInset])
                    #expect(abs(gap - 8) <= 1, "Visible source and start button bounds must keep the toolbar's 8-point spacing")
                    #expect(rightInset >= -2 && rightInset <= 8, "The whole action group must align to the reader card's right edge")
                    #expect(abs(sourceRect.midY - startRect.midY) <= 1)
                    #expect(abs(moreRect.midY - startRect.midY) <= 1)
                    #expect(sourceRect.width <= 221)
                    #expect(moreRect.width <= 26, "More actions shows only the ellipsis, without a menu indicator")
                    let title = try #require(frames["title"])
                    if size.width >= 1280 {
                        #expect(abs(startRect.minY - title.minY) <= 3, "Wide windows keep the actions in the title row")
                    } else {
                        #expect(startRect.minY >= title.maxY, "Narrow windows put the whole action group below the title")
                    }
                    #expect(moreRect.maxX <= host.bounds.maxX)
                    if let output = ProcessInfo.processInfo.environment["WORKBENCH_LIVE_HEADER_OUTPUT"] {
                        let folder = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        for scale in [1, 2] {
                            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                            bitmap.size = size
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("live-\(variant)-\(saved ? "saved" : "empty")-\(Int(size.width))-\(scale)x.png"))
                        }
                        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("geometry.json"))
                    }
                }
                #expect(credentials.reads == 0)
            }
        }
    }

    @Test func liveWorkspaceOnlyScrollsTextAndKeepsReadersInsideWindow() async throws {
        _ = NSApplication.shared
        let originalLanguage = UserDefaults.standard.object(forKey: "interfaceLanguage")
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: "interfaceLanguage")
        defer {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "interfaceLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = LayoutCredentials(), service = LayoutService()
        let store = RecordingStore(root: root)
        let recordings = RecordingSession(store: store, recorder: LayoutRecorder())
        recordings.selectSource(.microphoneDevice(.init(uid: "test-only-long-device", name: "Studio Display Microphone — Conference Room External USB Audio Interface")))
        let processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        let text = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let state = BilingualSessionState { $0 }
        let live = LiveBilingualSession(recordings: recordings, credentials: credentials, service: LayoutBilingual(), presentation: state)
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: .init(provider: .gemini), direction: .englishToChinese))
        state.receive(.configured, generation: token)
        let source = String(repeating: "Source text 中文 👩🏽‍💻 e\u{301}\n", count: 1_000)
        state.receive(.text(channel: .source, eventID: "source", delta: source, elapsedMilliseconds: 0), generation: token)
        state.receive(.text(channel: .translation, eventID: "translation", delta: source, elapsedMilliseconds: 0), generation: token)
        let host = NSHostingView(rootView: WorkbenchView(session: recordings, playback: PlaybackController(),
            processing: processing, providers: providers, translation: text, bilingual: state, bilingualLive: live, initialPage: .live))
        host.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        var originalReaders: [LiveReaderScrollView] = []
        for size in [NSSize(width: 1_280, height: 800), NSSize(width: 680, height: 640), NSSize(width: 1_280, height: 800)] {
            window.setContentSize(size)
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            if let output = ProcessInfo.processInfo.environment["WORKBENCH_LIVE_LAYOUT_OUTPUT"] {
                let folder = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("live-\(Int(size.width))x\(Int(size.height)).png"))
            }
            let allScrolls = descendants(host).compactMap { $0 as? NSScrollView }
            let readers = allScrolls.compactMap { $0 as? LiveReaderScrollView }
            print("LIVE_LAYOUT \(Int(size.width))x\(Int(size.height)): scrolls=\(allScrolls.count), readers=\(readers.count)")
            #expect(allScrolls.count == 2, "Only the two text readers may scroll; the workspace must remain fixed.")
            #expect(readers.count == 2)
            if originalReaders.isEmpty { originalReaders = readers }
            #expect(originalReaders.allSatisfy { original in readers.contains { $0 === original } })
            for reader in readers {
                let rect = reader.convert(reader.bounds, to: host)
                print("LIVE_READER frame=\(rect)")
                #expect(rect.minY >= -1 && rect.maxY <= host.bounds.maxY + 1)
                #expect(rect.height >= 60)
                #expect((reader.documentView as? NSTextView)?.string == source)
                let oldY = reader.contentView.bounds.origin.y
                reader.contentView.scroll(to: .zero)
                reader.reflectScrolledClipView(reader.contentView)
                #expect(oldY > 0 || reader.contentView.bounds.origin.y == 0)
            }
        }
        #expect(credentials.reads == 0)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class LayoutCredentials: ProviderCredentials, AudioCredentials {
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw ProviderConfigurationError.credential }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; throw AudioProcessingError.credential }
    func save(_ value: String, reference: ProviderCredentialReference) throws { throw ProviderConfigurationError.credential }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { throw AudioProcessingError.credential }
    func delete(reference: ProviderCredentialReference) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
private struct LayoutService: TextTranslating, ProviderConnectionChecking, FileTranscribing {
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws { throw TextTranslationError.processing }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { throw ProviderConfigurationError.network }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
}
@MainActor private final class LayoutRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws { throw AudioProcessingError.processing }
    func start(at url: URL, source: AudioSource) async throws { throw AudioProcessingError.processing }
    func pause() async throws {}; func resume() async throws {}; func stop() -> TimeInterval { 0 }
}
@MainActor private final class LayoutBilingual: LiveBilingualTranslating {
    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection, apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> { throw AudioProcessingError.processing }
    func append(_ chunk: LiveAudioChunk) async throws { throw AudioProcessingError.processing }
    func finishInput() async throws { throw AudioProcessingError.processing }
    func close() {}
}
