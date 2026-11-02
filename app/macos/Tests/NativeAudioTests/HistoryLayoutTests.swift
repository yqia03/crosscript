import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct HistoryLayoutTests {
    @Test(arguments: [0, 1, 12]) func productionHistoryCardsStayClearOfBothScrollerStylesAndRemainReachable(count: Int) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = HistoryCredentials(), service = HistoryService()
        let store = RecordingStore(root: root)
        let textStore = TextWorkspaceStore(root: root)
        var library = TextWorkspaceLibrary()
        let profile = try ProviderProfile(name: "Controlled provider with a long display name 中文", baseURL: "https://provider.test", model: "controlled-model")
        for i in 0..<count {
            let title = "\(i) A long controlled history title with 中文 and enough words to wrap in a narrow window"
            try store.save(Recording(id: UUID(), startedAt: Date().addingTimeInterval(Double(-i)), defaultName: title, name: title, duration: 123, status: .saved, workflow: i == 11 ? .liveTranslation : .transcription))
            var result = TextTranslationResult(input: title, direction: .englishToChinese, provider: profile.snapshot)
            result.currentText = "受控译文 Controlled translation"; result.status = .completed
            library.history.append(.init(result: result, isMarkdown: false))
        }
        try textStore.save(library)
        let recordings = RecordingSession(store: store, recorder: HistoryRecorder())
        let processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        let text = TextTranslationSession(store: textStore, credentials: credentials, service: service)
        let originalHistory = text.history
        let preferences = UserDefaults(suiteName: "HistoryLayout." + UUID().uuidString)!
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            for surface in ["text", "recording", "global"] {
                var frames: [String: CGRect] = [:]
                let content: AnyView
                switch surface {
                case "text": content = AnyView(TextTranslationHistoryView(session: text))
                case "recording": content = AnyView(RecordingHistoryView(session: recordings, processing: processing, open: { _ in }))
                default: content = AnyView(WorkbenchView(session: recordings, playback: PlaybackController(), processing: processing, providers: providers, translation: text, initialPage: .history))
                }
                let host = NSHostingView(rootView: content.defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 }))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520), styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                for size in (surface == "global" ? [NSSize(width: 680, height: 640), NSSize(width: 1280, height: 800), NSSize(width: 1900, height: 1000)] : [NSSize(width: 460, height: 420), NSSize(width: 700, height: 640), NSSize(width: 1200, height: 800)]) {
                    window.setContentSize(size); host.frame.size = size
                    await settle(host)
                    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                    for style in [NSScroller.Style.legacy, .overlay] {
                        scroll.scrollerStyle = style
                        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
                        scroll.tile(); await settle(host)
                        if count > 1 { frames.removeAll() }
                        scroll.contentView.scroll(to: .zero)
                        scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
                        let document = try #require(scroll.documentView)
                        for _ in 0..<3 {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                            scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
                        }
                        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                        let scroller = try #require(scroll.verticalScroller)
                        let scrollerRect = scroller.convert(scroller.bounds, to: host)
                        let cards = frames.filter { $0.key.hasPrefix(surface == "text" ? "text." : "recording.") || (surface == "global" && $0.key == "history.empty") }.map(\.value).filter { $0.intersects(viewport) }
                        #expect(!cards.isEmpty)
                        for card in cards {
                            #expect(card.maxX <= scrollerRect.minX - 2, "\(surface) \(language) width=\(size.width) style=\(style.rawValue): card \(card) must clear actual scroller \(scrollerRect)")
                        }
                        let lastKey: String
                        if count == 0 { lastKey = surface == "global" ? "history.empty" : surface + ".empty" }
                        else {
                            let lastID = surface == "text" ? text.history.last!.id : (surface == "global" ? recordings.recordings : recordings.recordings(in: .transcription)).last!.id
                            lastKey = (surface == "text" ? "text." : "recording.") + lastID.uuidString
                        }
                        let last = try #require(frames[lastKey])
                        print("HISTORY_LAST count=\(count) \(surface) last=\(last) viewport=\(viewport)")
                        #expect(last.minY >= viewport.minY - 1 && last.maxY <= viewport.maxY + 1, "The last card is fully reachable inside the scroll viewport")
                        #expect(scroll.contentView.bounds.maxY >= document.bounds.maxY - 1, "Last history row remains reachable")
                        print("HISTORY_GEOMETRY \(surface) \(language) \(Int(size.width)) style=\(style.rawValue) cards=\(cards.count) right=\(cards.map(\.maxX).max() ?? 0) scroller=\(scrollerRect.minX) end=\(scroll.contentView.bounds.maxY)/\(document.bounds.maxY)")
                    }
                }
            }
        }
        #expect(credentials.reads == 0)
        #expect(text.history == originalHistory)
        #expect(!recordings.hasActiveRecording && processing.backgroundTasks.isEmpty)
    }
    @Test func productionCopyMenuCentersItsVisibleSymbolAndKeepsCopyAndOpenActions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.general
        let previousClipboard = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(previousClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        let credentials = HistoryCredentials(), service = HistoryService(), store = TextWorkspaceStore(root: root)
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "controlled")
        var library = TextWorkspaceLibrary()
        for translated in [true, false] {
            var result = TextTranslationResult(input: translated ? "Controlled source" : "No translation source", direction: .englishToChinese, provider: profile.snapshot)
            result.currentText = translated ? "受控译文" : ""; result.status = translated ? .completed : .failed
            library.history.append(.init(result: result, isMarkdown: false))
        }
        try store.save(library)
        let session = TextTranslationSession(store: store, credentials: credentials, service: service)
        let original = session.history
        #expect(session.updateInput(text: "Current editable workspace draft"))
        #expect(session.updateTranslation(text: "当前工作区译文草稿"))
        #expect(await session.flushPendingSaves())
        let preferences = UserDefaults(suiteName: "HistoryCopy." + UUID().uuidString)!
        var restored = 0
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            let workspaceBeforeBrowsing = session.workspace
            var frames: [String: CGRect] = [:]
            let host = NSHostingView(rootView: TextTranslationHistoryView(session: session, restored: { restored += 1 }).defaultAppStorage(preferences)
                .environment(\.historyGeometryObserver, { frames[$0] = $1 }).background(Color.white).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            await settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            for entry in session.history {
                let rect = try #require(frames["copy." + entry.id.uuidString])
                #expect(abs(rect.width - 34) <= 1 && abs(rect.height - 34) <= 1)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                var ink: [CGPoint] = []
                for y in Int((rect.minY + 5) * scale)..<Int((rect.maxY - 5) * scale) {
                    for x in Int((rect.minX + 5) * scale)..<Int((rect.maxX - 5) * scale) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.65, color.greenComponent < 0.8, color.blueComponent < 0.85 {
                            ink.append(CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale))
                        }
                    }
                }
                let minX = try #require(ink.map(\.x).min()), maxX = try #require(ink.map(\.x).max())
                let minY = try #require(ink.map(\.y).min()), maxY = try #require(ink.map(\.y).max())
                print("HISTORY_COPY \(language) button=\(rect) ink=\(minX),\(minY)..\(maxX),\(maxY)")
                #expect(abs((minX + maxX) / 2 - rect.midX) <= 1, "Rendered copy symbol must center horizontally in its complete hit area")
                #expect(abs((minY + maxY) / 2 - rect.midY) <= 1, "Rendered copy symbol must center vertically in its complete hit area")
            }
            let menus = descendants(host).compactMap { $0 as? NSPopUpButton }.filter { $0.accessibilityLabel() == (language == "english" ? "Copy history contents" : "复制历史内容") }
            #expect(menus.count == 2)
            for menu in menus {
                let hit = menu.convert(menu.bounds, to: host)
                let wrapper = try #require(frames.values.first { abs($0.midX - hit.midX) < 1 && abs($0.midY - hit.midY) < 1 && abs($0.width - 34) < 1 })
                #expect(hit == wrapper, "The centered symbol's complete 34-point native menu target matches its visible button")
                let source = try #require(menu.item(at: 1)), translation = try #require(menu.item(at: 2))
                #expect(source.isEnabled)
                menu.selectItem(at: 1)
                #expect(menu.sendAction(menu.action, to: menu.target))
                let sourceText = try #require(NSPasteboard.general.string(forType: .string))
                let entry = try #require(session.history.first { $0.input == sourceText })
                #expect(translation.isEnabled == !entry.translation.isEmpty)
                if translation.isEnabled {
                    menu.selectItem(at: 2)
                    #expect(menu.sendAction(menu.action, to: menu.target))
                    #expect(NSPasteboard.general.string(forType: .string) == entry.translation)
                }
            }
            #expect(session.workspace == workspaceBeforeBrowsing, "Browsing and copying history preserve the existing editable workspace")
            let open = try #require(frames["open." + session.history[0].id.uuidString])
            let location = NSPoint(x: open.midX, y: host.bounds.height - open.midY)
            window.sendEvent(try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            window.sendEvent(try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
            await settle(host)
            #expect(restored == (language == "english" ? 1 : 2))
            #expect(session.history.contains { $0.input == session.workspace.inputDraft })
            #expect(session.history == original && !session.isRunning)
            if let output = ProcessInfo.processInfo.environment["WORKBENCH_HISTORY_OUTPUT"] {
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("copy-\(language).png"))
            }
        }
        #expect(await session.flushPendingSaves())
        #expect(credentials.reads == 0)
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(25)) }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class HistoryCredentials: ProviderCredentials, AudioCredentials {
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw ProviderConfigurationError.credential }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; throw AudioProcessingError.credential }
    func save(_ value: String, reference: ProviderCredentialReference) throws {}
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(reference: ProviderCredentialReference) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
private struct HistoryService: TextTranslating, ProviderConnectionChecking, FileTranscribing {
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws { throw TextTranslationError.processing }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { throw ProviderConfigurationError.network }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
}
@MainActor private final class HistoryRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws { throw AudioProcessingError.processing }
    func start(at url: URL, source: AudioSource) async throws { throw AudioProcessingError.processing }
    func pause() async throws {}; func resume() async throws {}; func stop() -> TimeInterval { 0 }
}
