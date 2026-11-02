import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFWorkspaceLayoutTests {
    @Test func productionPDFWorkspaceSeparatesNestedScrollContentsAndKeepsEndControlsReachable() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let fixture = try LayoutFixture(); defer { fixture.clean() }
        let original = fixture.pdf.materials, workspace = fixture.pdf.workspaceMaterialIDs
        let preferences = UserDefaults(suiteName: "PDFWorkspaceGeometry." + UUID().uuidString)!
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            var frames: [String: CGRect] = [:]
            let host = NSHostingView(rootView: fixture.workbench.defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 }))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            await NativeViewTestSupport.settle(host)
            for id in ["pdf-settings-layout", "pdf-settings-performance", "pdf-settings-terms", "pdf-details-layout", "pdf-details-diagnostics"] {
                let control = try #require(NativeViewTestSupport.element(host, identifier: id))
                #expect((control as AnyObject).accessibilityPerformPress?() == true)
                await NativeViewTestSupport.settle(host)
            }
            let output = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == (language == "english" ? "Output files" : "输出文件") })
            output.selectItem(at: 1); #expect(output.sendAction(output.action, to: output.target))
            for size in [NSSize(width: 680, height: 640), NSSize(width: 1280, height: 640), NSSize(width: 1280, height: 800), NSSize(width: 1900, height: 1000)] {
                window.setContentSize(size); host.frame.size = size; await NativeViewTestSupport.settle(host)
                for style in [NSScroller.Style.legacy, .overlay] {
                    let all = descendants(host).compactMap { $0 as? NSScrollView }
                    for scroll in all { scroll.scrollerStyle = style; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false; scroll.tile() }
                    await NativeViewTestSupport.settle(host)
                    let outer = try #require(all.first)
                    outer.contentView.scroll(to: .zero); outer.reflectScrolledClipView(outer.contentView); await NativeViewTestSupport.settle(host)
                    let outerTrack = try #require(outer.verticalScroller).convert(try #require(outer.verticalScroller).bounds, to: host)
                    let contents = try #require(frames["pdf.workspace.contents"])
                    #expect(contents.maxX <= outerTrack.minX - 2, "The actual PDF workspace clears Workbench's outer scroll track")
                    let imports = try #require(frames["pdf.import.card"]), settings = try #require(frames["pdf.settings.card"]), result = try #require(frames["pdf.result.card"])
                    #expect(!imports.intersects(settings) && !imports.intersects(result) && !settings.intersects(result), "Actual import/settings/result cards do not overlap")
                    let progress = try #require(frames["pdf.progress.viewport"])
                    #expect(progress.minY >= imports.minY && progress.maxY <= imports.maxY - 1, "Progress and its controls stay inside the allocated import card")
                    for (viewportKey, contentKey) in [("pdf.settings.viewport", "pdf.settings.contents"), ("pdf.details.viewport", "pdf.details.contents"), ("pdf.progress.viewport", "pdf.progress.contents")] {
                        let scroll = try nativeScroll(viewportKey, host: host, frames: frames)
                        let track = try #require(scroll.verticalScroller).convert(try #require(scroll.verticalScroller).bounds, to: host)
                        #expect(scroll.scrollerStyle == style)
                        #expect(try #require(frames[contentKey]).maxX <= track.minX - (contentKey == "pdf.settings.contents" ? 0 : 2), "\(contentKey) clears its actual nested scroll track")
                        let document = try #require(scroll.documentView)
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView); await NativeViewTestSupport.settle(host)
                        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                        let end = try #require(frames[contentKey])
                        #expect(end.maxY <= viewport.maxY + 1, "Expanded \(contentKey) remains reachable through the actual scroll view")
                    }
                    let fileScroll = try nativeScroll("pdf.import.viewport", host: host, frames: frames)
                    let fileDocument = try #require(fileScroll.documentView)
                    for _ in 0..<3 {
                        fileScroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, fileDocument.bounds.height - fileScroll.contentView.bounds.height)))
                        fileScroll.reflectScrolledClipView(fileScroll.contentView); await NativeViewTestSupport.settle(host)
                    }
                    let fileViewport = fileScroll.contentView.convert(fileScroll.contentView.bounds, to: host)
                    let fileTrack = try #require(fileScroll.verticalScroller).convert(try #require(fileScroll.verticalScroller).bounds, to: host)
                    let add = try #require(frames["pdf.import.add"])
                    #expect(add.minY >= fileViewport.minY - 1 && add.maxY <= fileViewport.maxY + 1 && add.maxX <= fileTrack.minX - 2, "The final Add PDF tile is fully reachable, outside the import scrollbar")
                    for (name, card) in frames where name.hasPrefix("pdf.import.file.") && card.intersects(fileViewport) {
                        #expect(card.minX >= fileViewport.minX - 1 && card.maxX <= fileTrack.minX - 2, "\(name) is not clipped or covered by the file-list scroller")
                    }
                    let outerDocument = try #require(outer.documentView)
                    outer.contentView.scroll(to: CGPoint(x: 0, y: max(0, outerDocument.bounds.height - outer.contentView.bounds.height)))
                    outer.reflectScrolledClipView(outer.contentView); await NativeViewTestSupport.settle(host)
                    let viewport = outer.contentView.convert(outer.contentView.bounds, to: host)
                    let toolbar = try #require(frames["pdf.reader.toolbar"]), pages = try #require(frames["pdf.reader.pages"]), zoom = try #require(frames["pdf.reader.zoom"])
                    #expect(viewport.contains(toolbar) && !pages.intersects(zoom), "Page/zoom controls remain separate and reachable at the end of the real PDF workspace")
                    #expect(output.indexOfSelectedItem == 1, "Layout, zoom and scrolling retain the explicitly selected output mode")
                    #expect((try #require(NativeViewTestSupport.element(host, identifier: "pdf-save-result")) as AnyObject).isAccessibilityEnabled?() == true)
                    #expect((try #require(NativeViewTestSupport.element(host, identifier: "pdf-new-project")) as AnyObject).isAccessibilityEnabled?() == true)
                    print("PDF_WORKSPACE \(language) \(Int(size.width))x\(Int(size.height)) style=\(style.rawValue) outer=\(contents.maxX)/\(outerTrack.minX) import=\(imports) settings=\(settings) result=\(result) toolbar=\(toolbar)")
                }
            }
            for id in ["pdf-reader-next", "pdf-reader-zoom-in", "pdf-reader-zoom-out", "pdf-reader-fit", "pdf-reader-previous"] {
                #expect((try #require(NativeViewTestSupport.element(host, identifier: id)) as AnyObject).accessibilityPerformPress?() == true)
                await NativeViewTestSupport.settle(host)
            }
            #expect(!window.isVisible && !window.isKeyWindow)
        }
        #expect(fixture.pdf.materials == original && fixture.pdf.workspaceMaterialIDs == workspace && !fixture.pdf.hasActiveWork)
        #expect(fixture.credentials.reads == 0 && fixture.recorder.starts == 0)
        #expect(await fixture.service.calls == 0)
    }
    @Test func importGridUsesActualScrollViewportWhenColumnCountChanges() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let fixture = try LayoutFixture(); defer { fixture.clean() }
        let materials = fixture.pdf.materials
        let preferences = UserDefaults(suiteName: "PDFImportColumns." + UUID().uuidString)!
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            for width: CGFloat in [478, 622] {
                var frames: [String: CGRect] = [:], choices = 0
                let host = NSHostingView(rootView: PDFWorkspaceImportView(session: fixture.pdf, canSubmit: false, localOnly: false, chooseFiles: { choices += 1 }, submit: { Issue.record("Scrolling must not submit") })
                    .defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 }))
                let window = NSWindow(contentRect: CGRect(x:0,y:0,width:width,height:420), styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                await NativeViewTestSupport.settle(host)
                for style in [NSScroller.Style.legacy, .overlay] {
                    let scroll = try nativeScroll("pdf.import.viewport", host: host, frames: frames)
                    scroll.scrollerStyle = style; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false; scroll.tile(); await NativeViewTestSupport.settle(host)
                    let document = try #require(scroll.documentView)
                    for _ in 0..<3 {
                        scroll.contentView.scroll(to: CGPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView); await NativeViewTestSupport.settle(host)
                    }
                    let viewport = scroll.contentView.convert(scroll.contentView.bounds,to:host)
                    let track = try #require(scroll.verticalScroller).convert(try #require(scroll.verticalScroller).bounds,to:host)
                    let add = try #require(frames["pdf.import.add"])
                    #expect(add.minY >= viewport.minY - 1 && add.maxY <= viewport.maxY + 1 && add.minX >= viewport.minX && add.maxX <= track.minX - 2)
                    for (name, card) in frames where name.hasPrefix("pdf.import.file.") && card.intersects(viewport) {
                        #expect(card.minX >= viewport.minX - 1 && card.maxX <= track.minX - 2, "A whole file card fits the real post-scroller viewport at a column threshold: \(name)")
                    }
                    #expect((try #require(NativeViewTestSupport.element(host,identifier:"pdf-workspace-add")) as AnyObject).accessibilityPerformPress?() == true)
                    #expect(choices == (style == .legacy ? 1 : 2))
                    print("PDF_IMPORT_COLUMN \(language) width=\(width) style=\(style.rawValue) add=\(add) viewport=\(viewport) track=\(track)")
                    #expect(!window.isVisible && !window.isKeyWindow)
                }
            }
        }
        #expect(fixture.pdf.materials == materials && !fixture.pdf.hasActiveWork && fixture.credentials.reads == 0)
        #expect(await fixture.service.calls == 0)
    }
    private func nativeScroll(_ key: String, host: NSView, frames: [String: CGRect]) throws -> NSScrollView {
        let target = try #require(frames[key])
        let candidates = descendants(host).compactMap { $0 as? NSScrollView }.map { view in (view, view.convert(view.bounds, to: host)) }
        let best = try #require(candidates.min { a,b in distance(a.1,target) < distance(b.1,target) })
        #expect(distance(best.1,target) <= 4, "The production viewport corresponds to an actual native scroll view")
        return best.0
    }
    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.minX-b.minX)+abs(a.minY-b.minY)+abs(a.width-b.width)+abs(a.height-b.height) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class LayoutFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-workspace-layout-\(UUID())")
    let credentials = LayoutCredentials(), recorder = LayoutRecorder(), service = LayoutService()
    let pdf: PDFTranslationSession
    let recordings: RecordingSession
    let processing: PostRecordingSession
    let providers: ProviderConfigurationSession
    let text: TextTranslationSession
    var workbench: WorkbenchView { .init(session: recordings, playback: PlaybackController(), processing: processing, providers: providers, translation: text, pdf: pdf, initialPage: .pdf) }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        let profile = try ProviderProfile(name: "Controlled multilingual provider with a long name 中文", baseURL: "https://layout.invalid", model: "controlled-layout-model-with-a-long-identifying-suffix")
        var ids: [UUID] = []
        for i in 0..<12 {
            let source = root.appendingPathComponent("\(i) 受控长名称 Controlled lecture document with a descriptive filename.pdf")
            var bounds = CGRect(x: 0,y:0,width:600,height:250)
            let context = try #require(CGContext(source as CFURL, mediaBox: &bounds,nil))
            for _ in 0..<4 { context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(bounds); context.endPDFPage() }
            context.closePDF()
            var material = try store.importPDF(source)
            var task = PDFBackgroundTask(provider: profile.snapshot, options: .init()); task.status = .awaitingResume; task.failure = .interrupted
            material.tasks = [task]
            if i == 0 {
                let staging = try store.stagingDirectory(task.id, materialID: material.id)
                let mono = staging.appendingPathComponent("mono.pdf"), dual = staging.appendingPathComponent("dual.pdf")
                try Data(contentsOf: source).write(to: mono); try Data(contentsOf: source).write(to: dual)
                let result = try store.install(.init(outputs: [.init(kind: .mono,url:mono), .init(kind:.dual,url:dual)], contentReport:.init(sourcePageCount:4,selectedPageCount:4,pagesWithoutExtractableText:2), diagnostics:.init(requestCount:12,translationRequests:10,termRequests:2,elapsedSeconds:123)), task:task,material:material,resultID:UUID())
                material.results = [result]; material.selectedResultID = result.id
            }
            try store.save(material); ids.append(material.id)
        }
        pdf = PDFTranslationSession(store: store, credentials: credentials, engine: service)
        for id in ids { pdf.open(id) }; pdf.open(ids[0])
        let recordingStore = RecordingStore(root: root.appendingPathComponent("recordings"))
        recordings = RecordingSession(store: recordingStore, recorder: recorder)
        processing = PostRecordingSession(recordings: recordings, store: recordingStore, credentials: credentials, service: service)
        providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        let id = try #require(providers.saveProfile(name: profile.name, baseURL: profile.baseURL, model: profile.model, apiKey: ""))
        providers.setDefault(id.id, for: .pdf)
        text = TextTranslationSession(store: TextWorkspaceStore(root:root), credentials:credentials, service:service)
    }
    func clean() { try? FileManager.default.removeItem(at:root) }
}
@MainActor private final class LayoutCredentials: ProviderCredentials, AudioCredentials {
    var reads = 0
    func read(reference:ProviderCredentialReference)throws->String?{ reads += 1; throw ProviderConfigurationError.credential }
    func read(for configuration:AudioServiceConfiguration)throws->String?{ reads += 1; throw AudioProcessingError.credential }
    func save(_ value:String,reference:ProviderCredentialReference)throws{}
    func save(_ value:String,for configuration:AudioServiceConfiguration)throws{}
    func delete(reference:ProviderCredentialReference)throws{}
    func delete(for configuration:AudioServiceConfiguration)throws{}
}
@MainActor private final class LayoutRecorder:AudioRecording {
    var currentTime:TimeInterval{0};var power:Float{-160};var onFailure:((Error)->Void)?;var starts=0
    func requestPermission(for source:AudioSource)async throws{throw AudioProcessingError.processing}
    func start(at url:URL,source:AudioSource)async throws{starts += 1;throw AudioProcessingError.processing}
    func pause()async throws{};func resume()async throws{};func stop()->TimeInterval{0}
}
private actor LayoutService:PDFTranslating,TextTranslating,ProviderConnectionChecking,FileTranscribing {
    var calls=0
    func translate(_ request:PDFEngineRequest,apiKey:String,progress:@escaping @Sendable(PDFEngineProgress)->Void)async throws->PDFEngineResult{calls += 1;throw PDFTranslationError.processing}
    func translate(_ request:TextTranslationRequest,apiKey:String,onEvent:@escaping @Sendable(TextTranslationEvent)async->Void)async throws{calls += 1;throw TextTranslationError.processing}
    func check(snapshot:ProviderSnapshot,apiKey:String)async throws->ProviderConnectionReport{calls += 1;throw ProviderConfigurationError.network}
    func transcribe(audio:URL,configuration:AudioServiceConfiguration,apiKey:String,progress:@escaping @Sendable(Int)async->Void)async throws->String{calls += 1;throw AudioProcessingError.processing}
}
