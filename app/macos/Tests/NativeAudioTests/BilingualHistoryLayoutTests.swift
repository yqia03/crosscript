import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualHistoryLayoutTests {
    @Test func currentRecordingHistoryKeepsContentsClearOfBothScrollerStyles() async throws {
        _ = NSApplication.shared
        let preferences = UserDefaults(suiteName: "BilingualHistoryLayout." + UUID().uuidString)!
        for variant in ["empty", "no-text", "multi-gap", "read-error", "legacy"] {
            let fixture = try HistoryFixture(variant: variant)
            defer { fixture.clean() }
            let audioBefore = try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id))
            for language in ["english", "zhHans"] {
                preferences.set(language, forKey: "interfaceLanguage")
                var frames: [String: CGRect] = [:]
                let host = NSHostingView(rootView: fixture.view(done: {}).defaultAppStorage(preferences)
                    .environment(\.historyGeometryObserver, { frames[$0] = $1 }).background(Color(nsColor: .windowBackgroundColor)).tint(Color(red: 0.16, green: 0.47, blue: 0.53)).preferredColorScheme(.light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                for size in [NSSize(width: 560, height: 480), NSSize(width: 760, height: 640), NSSize(width: 1200, height: 800)] {
                    window.setContentSize(size); host.frame.size = size
                    await settle(host)
                    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                    for style in [NSScroller.Style.legacy, .overlay] {
                        scroll.scrollerStyle = style; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
                        scroll.tile()
                        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                        await settle(host)
                        let contents = try #require(frames["live.contents"])
                        let scroller = try #require(scroll.verticalScroller)
                        let track = scroller.convert(scroller.bounds, to: host)
                        #expect(scroll.scrollerStyle == style)
                        #expect(contents.maxX <= track.minX - 2, "\(variant) \(language) width=\(size.width) style=\(style.rawValue): contents \(contents) clear actual scroller \(track)")
                        for (name, control) in frames where name.hasPrefix("live.action.") || name == "live.result.picker" || name == "live.playback" {
                            #expect(control.minX >= contents.minX - 1 && control.maxX <= contents.maxX + 1, "\(name) remains inside the real card content bounds")
                        }
                        let document = try #require(scroll.documentView)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
                        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                        let last = try #require(frames["live.contents"])
                        #expect(last.maxY <= viewport.maxY + 1, "The bottom of all history operations remains reachable")
                        print("LIVE_HISTORY \(variant) \(language) \(Int(size.width)) style=\(style.rawValue) right=\(contents.maxX) track=\(track.minX) bottom=\(last.maxY)/\(viewport.maxY)")
                        if let output = ProcessInfo.processInfo.environment["WORKBENCH_LIVE_HISTORY_OUTPUT"], size.width == 560 {
                            let folder = URL(fileURLWithPath: output)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(variant)-\(language)-\(style.rawValue).png"))
                        }
                    }
                }
            }
            #expect(fixture.recorder.starts == 0 && fixture.recorder.permissions == 0 && fixture.credentials.reads == 0)
            #expect(fixture.playback.loadedURL == nil && fixture.repair.tasks.isEmpty)
            #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == audioBefore)
        }
    }
    @Test func emptyAndUnreadableResultsExplainWhatRemainsWithoutAutomaticRequests() async throws {
        _ = NSApplication.shared
        enableHostAccessibility()
        let preferences = UserDefaults(suiteName: "LiveHistoryStates." + UUID().uuidString)!
        for variant in ["empty", "no-text", "read-error", "legacy"] {
            let fixture = try HistoryFixture(variant: variant)
            defer { fixture.clean() }
            for language in ["english", "zhHans"] {
                preferences.set(language, forKey: "interfaceLanguage")
                var frames: [String: CGRect] = [:]
                let host = NSHostingView(rootView: fixture.view(done: {}).defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 })
                    .background(Color(nsColor: .windowBackgroundColor)).tint(Color(red: 0.16, green: 0.47, blue: 0.53)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                await settle(host)
                let key = variant == "read-error" ? "live.readError" : variant == "no-text" ? "live.noText" : "live.empty"
                let message = try #require(frames[key], "The actual production history must visibly explain \(variant)")
                #expect(message.width >= 200 && message.height >= 14)
                let result = try #require(frames["live.result"])
                #expect(message.minX >= result.minX && message.maxX <= result.maxX)
                let history = fixture.state.history(recordingID: fixture.id, store: fixture.results)
                #expect(history.loadFailed == (variant == "read-error"))
                #expect(history.results.isEmpty == (variant != "no-text"))
                if variant == "legacy" {
                    try await press("live-history-legacy", host: host)
                    #expect(descendants(host).compactMap { $0 as? NSTextView }.contains { $0.string == "Preserved legacy transcript 用户修改" })
                    #expect(fixture.processing.materials[fixture.id]?.results.first?.text == "Preserved legacy transcript 用户修改")
                }
                if variant == "read-error" && language == "zhHans" {
                    try FileManager.default.removeItem(at: fixture.store.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json"))
                    try await press("live-history-reload", host: host)
                    #expect(!history.loadFailed && frames["live.empty"] != nil)
                }
            }
            #expect(fixture.recorder.starts == 0 && fixture.recorder.permissions == 0 && fixture.credentials.reads == 0 && fixture.repair.tasks.isEmpty)
        }
    }
    @Test func nativeHistoryEditsSurviveFailedSaveAndReopeningAndKeepResultActions() async throws {
        _ = NSApplication.shared
        enableHostAccessibility()
        let fixture = try HistoryFixture(variant: "multi-gap")
        defer { fixture.clean() }
        let board = NSPasteboard.general
        let clipboard = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            board.clearContents()
            board.writeObjects(clipboard.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item })
        }
        let preferences = UserDefaults(suiteName: "LiveHistoryActions." + UUID().uuidString)!
        preferences.set("english", forKey: "interfaceLanguage")
        var frames: [String: CGRect] = [:], closed = 0
        let host = NSHostingView(rootView: fixture.view(done: { closed += 1 }).defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let history = fixture.state.history(recordingID: fixture.id, store: fixture.results)
        let original = try fixture.results.load(fixture.id)
        #expect(history.results.count == 3)
        let selected = try #require(history.selected)
        let source = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.string == selected.document.source.text })
        source.insertText("A draft to discard", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
        await settle(host)
        #expect(history.hasUnsavedChanges)
        try await press("live-history-discard", host: host)
        #expect(!history.hasUnsavedChanges && history.sourceText == selected.document.source.text)
        let restoredSource = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.string == selected.document.source.text })
        restoredSource.insertText("Retained native history edit 中文", replacementRange: NSRange(location: 0, length: restoredSource.string.utf16.count))
        await settle(host)
        #expect(history.hasUnsavedChanges && fixture.state.hasUnsavedHistoryEdits(for: fixture.id))
        #expect(!history.select(original[0].id))
        let path = fixture.store.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json")
        let bytes = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try await press("live-history-save", host: host)
        #expect(history.saveFailed && history.sourceText == "Retained native history edit 中文")
        try await press("live-history-copy", host: host)
        #expect(board.string(forType: .string) == history.exported)
        try await press("live-history-done", host: host)
        #expect(closed == 1)
        let reopened = NSHostingView(rootView: fixture.view(done: { closed += 1 }).defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 }))
        window.contentView = reopened; await settle(reopened)
        #expect(descendants(reopened).compactMap { $0 as? NSTextView }.contains { $0.isEditable && $0.string == "Retained native history edit 中文" })
        #expect(history.hasUnsavedChanges && history.saveFailed)
        #expect((try #require(element(reopened, identifier: "live-history-open")) as AnyObject).isAccessibilityEnabled?() == false)
        #expect((try #require(element(reopened, identifier: "live-history-result-picker")) as AnyObject).isAccessibilityEnabled?() == false)
        #expect((try #require(element(reopened, identifier: "live-history-export")) as AnyObject).isAccessibilityEnabled?() == true)
        #expect(closed == 1 && fixture.state.result == nil)
        try FileManager.default.removeItem(at: path); try bytes.write(to: path)
        try await press("live-history-save", host: reopened)
        #expect(!history.hasUnsavedChanges && !history.saveFailed)
        let saved = try fixture.results.load(fixture.id)
        #expect(saved.dropLast().elementsEqual(original.dropLast()))
        #expect(saved.last?.document.source.text == "Retained native history edit 中文")
        #expect(saved.last?.document.translation == selected.document.translation)
        #expect(saved.last?.document.translation.missingIntervals == selected.document.translation.missingIntervals)
        #expect(history.select(original[0].id))
        await settle(reopened)
        #expect(history.sourceText == original[0].document.source.text)
        try await press("live-history-open", host: reopened)
        #expect(closed == 2 && fixture.state.result?.id == original[0].id)
        #expect(fixture.recorder.starts == 0 && fixture.recorder.permissions == 0 && fixture.credentials.reads == 0 && fixture.repair.tasks.isEmpty)
    }
    @Test func liveHistoryEntryOnlyAppearsForLiveMaterialWithoutOpeningOrStartingCapture() async throws {
        _ = NSApplication.shared
        enableHostAccessibility()
        let fixture = try HistoryFixture(variant: "empty")
        defer { fixture.clean() }
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: fixture.root), credentials: fixture.credentials, checker: LiveHistoryService())
        let text = TextTranslationSession(store: TextWorkspaceStore(root: fixture.root), credentials: fixture.credentials, service: LiveHistoryService())
        let config = AudioServiceConfiguration(provider: .gemini)
        let live = LiveBilingualSession(recordings: fixture.recordings, credentials: fixture.credentials, service: LiveHistoryTransport(), presentation: fixture.state, capabilityAllowsStart: { $0 == config })
        let otherID = UUID()
        try fixture.store.save(Recording(id: otherID, startedAt: Date(), defaultName: "Ordinary transcription", name: "Ordinary transcription", duration: 1, status: .saved))
        fixture.recordings.refresh()
        for phase in ["no-selection", "transcription", "saved-live", "starting-live"] {
            if phase == "no-selection" { fixture.recordings.newProject() }
            else { fixture.recordings.select(phase == "transcription" ? otherID : fixture.id) }
            var starting: Task<Bool, Never>?
            defer {
                fixture.recorder.permissionReply?.resume(throwing: AudioProcessingError.processing)
                fixture.recorder.permissionReply = nil
            }
            if phase == "starting-live" {
                fixture.recorder.holdPermission = true
                starting = Task { await live.start(configuration: config, direction: .englishToChinese) }
                let deadline = Date().addingTimeInterval(2)
                while fixture.recorder.permissionReply == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
                try #require(fixture.recorder.permissionReply != nil && live.isActive)
            }
            var frames: [String: CGRect] = [:]
            let host = NSHostingView(rootView: WorkbenchView(session: fixture.recordings, playback: fixture.playback, processing: fixture.processing, providers: providers, translation: text, bilingual: fixture.state, bilingualStore: fixture.results, bilingualLive: live, initialPage: .live)
                .environment(\.historyGeometryObserver, { frames[$0] = $1 }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            await settle(host)
            let available = phase == "saved-live" || phase == "starting-live"
            #expect((frames["live.history.entry"] != nil) == available)
            if available {
                let entry = try #require(frames["live.history.entry"])
                #expect(entry.width <= 34 && entry.height == 34, "The live entry uses the same compact icon target as recording history")
                let entryButton = try #require(element(host, identifier: "live-history-entry"))
                #expect((entryButton as AnyObject).isAccessibilityEnabled?() == (phase == "saved-live"))
                #expect(live.isActive == (phase == "starting-live"))
                #expect(window.attachedSheet == nil && !window.isVisible, "Availability checks never present a history window")
            }
            window.contentView = nil
            if let starting {
                fixture.recorder.permissionReply?.resume(throwing: AudioProcessingError.processing)
                fixture.recorder.permissionReply = nil
                #expect(!(await starting.value) && !live.isActive)
            }
        }
        #expect(fixture.recorder.starts == 0 && fixture.credentials.reads == 0)
    }
    private func enableHostAccessibility() {
        // SwiftUI virtual accessibility is activated only in this test process.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
    }
    private func element(_ root: Any, identifier: String) -> NSObject? {
        guard let node = root as? NSObject else { return nil }
        if node.responds(to: NSSelectorFromString("accessibilityIdentifier")), node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
        for child in (node as AnyObject).accessibilityChildren?() ?? [] {
            if let found = element(child, identifier: identifier) { return found }
        }
        return nil
    }
    private func press(_ identifier: String, host: NSView) async throws {
        #expect(host.window?.isVisible == false && host.window?.isKeyWindow == false)
        let button = try #require(element(host, identifier: identifier))
        #expect((button as AnyObject).accessibilityPerformPress?() == true)
        await settle(host)
        #expect(host.window?.isVisible == false && host.window?.isKeyWindow == false)
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class HistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-history-\(UUID())")
    let id = UUID(), recorder = LiveHistoryRecorder(), credentials = LiveHistoryCredentials(), playback = PlaybackController()
    let store: RecordingStore
    let results: BilingualResultStore
    let recordings: RecordingSession
    let state: BilingualSessionState
    let processing: PostRecordingSession
    let repair: BilingualRepairSession
    init(variant: String) throws {
        store = RecordingStore(root: root); results = BilingualResultStore(recordings: store)
        let name = "受控同传 — Controlled saved interpretation with a long recording name that wraps in the smallest supported window"
        try store.save(Recording(id: id, startedAt: Date(), defaultName: name, name: name, duration: 123, status: .saved, source: .microphoneDevice(.init(uid: "synthetic-history", name: "Controlled long microphone source name 中文")), workflow: .liveTranslation))
        try Data("Disposable controlled audio bytes".utf8).write(to: store.audioURL(for: id))
        recordings = RecordingSession(store: store, recorder: recorder); recordings.select(id)
        state = BilingualSessionState { [results] in try results.publish($0) }
        if variant == "legacy" {
            let legacy = try JSONSerialization.data(withJSONObject: ["results": [["id": UUID().uuidString, "createdAt": 0, "model": "legacy-controlled", "text": "Preserved legacy transcript 用户修改"]]])
            try store.saveTranscription(JSONDecoder().decode(TranscriptionMaterial.self, from: legacy), for: id)
        }
        processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: LiveHistoryService())
        if ["no-text", "multi-gap"].contains(variant) {
            for _ in 0..<(variant == "multi-gap" ? 3 : 1) {
                var document = BilingualTranscriptDocument()
                if variant == "multi-gap" {
                    document.append(String(repeating: "Controlled long source text 中文.\n", count: 30), channel: .source, eventID: "source", elapsedMilliseconds: 0, connectionStartFrame: 0)
                    document.append(String(repeating: "受控长译文 Controlled translation.\n", count: 30), channel: .translation, eventID: "translation", elapsedMilliseconds: 0, connectionStartFrame: 0)
                    document.addMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .translation)
                }
                document.finish()
                try results.publish(BilingualResult(recordingID: id, configuration: .init(provider: .gemini), direction: .englishToChinese, document: document))
            }
        }
        if variant == "read-error" {
            try Data("not valid history JSON".utf8).write(to: store.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json"))
        }
        repair = BilingualRepairSession(recordings: recordings, results: results, journal: BilingualRepairStore(recordings: store), credentials: credentials, service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
    }
    func view(done: @escaping () -> Void) -> BilingualRecordingHistoryView {
        .init(session: recordings, processing: processing, bilingual: state, playback: playback, bilingualStore: results, bilingualRepair: repair, done: done)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class LiveHistoryRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    var starts = 0, permissions = 0, holdPermission = false
    var permissionReply: CheckedContinuation<Void, Error>?
    func requestPermission(for source: AudioSource) async throws {
        permissions += 1
        if holdPermission { try await withCheckedThrowingContinuation { permissionReply = $0 } }
        else { throw AudioProcessingError.processing }
    }
    func start(at url: URL, source: AudioSource) async throws { starts += 1; throw AudioProcessingError.processing }
    func pause() async throws {}; func resume() async throws {}; func stop() -> TimeInterval { 0 }
}
@MainActor private final class LiveHistoryCredentials: ProviderCredentials, AudioCredentials {
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw ProviderConfigurationError.credential }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; throw AudioProcessingError.credential }
    func save(_ value: String, reference: ProviderCredentialReference) throws {}
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(reference: ProviderCredentialReference) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
private struct LiveHistoryService: FileTranscribing, TextTranslating, ProviderConnectionChecking {
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws { throw TextTranslationError.processing }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { throw ProviderConfigurationError.network }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
}

@MainActor private final class LiveHistoryTransport: LiveBilingualTranslating {
    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection, apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> { throw AudioProcessingError.processing }
    func append(_ chunk: LiveAudioChunk) async throws { throw AudioProcessingError.processing }
    func finishInput() async throws { throw AudioProcessingError.processing }
    func close() {}
}
