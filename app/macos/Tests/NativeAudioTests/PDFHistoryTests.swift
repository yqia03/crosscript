import AppKit
import SwiftUI
import CoreGraphics
import PDFKit
import Testing
@testable import TranslationWorkbench
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFHistoryTests {
    @Test(arguments: ["done", "escape", "open", "nativeBinding"])
    func hiddenHistoryContentUsesOneDismissalPathAndRetainsDraftFilesAndPendingSaves(path: String) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let fixture = try PDFHistoryFixture(count: 2, pending: true)
        defer { fixture.clean() }
        let presentation = PDFHistoryPresentation()
        presentation.activateWorkspace(); presentation.present()
        if path == "nativeBinding" { fixture.session.newProject() }
        let materials = fixture.session.materials, workspace = fixture.session.workspaceMaterialIDs
        let selected = fixture.session.selectedID, pending = fixture.session.pendingSaveIDs
        let draft = try fixture.draft.snapshot(profiles: [], resources: nil).options
        let preferences = UserDefaults(suiteName: "PDFHistoryDismissal." + UUID().uuidString)!
        preferences.set("english", forKey: "interfaceLanguage")
        // Host the production sheet content without attaching/presenting a sheet
        // window. The OS dismissal-completion callback is exercised below.
        let host = NSHostingView(rootView: PDFHistoryView(session: fixture.session, close: presentation.dismiss)
            .defaultAppStorage(preferences).background(Color.white)
            .foregroundStyle(Color(red: 0.15, green: 0.22, blue: 0.28)).preferredColorScheme(.light))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        #expect(fixture.session.sourceMetadata.count == materials.count)
        for material in materials {
            #expect(element(host, identifier: "pdf-history-results-" + material.id.uuidString) != nil)
            #expect(element(host, identifier: "pdf-history-metadata-" + material.id.uuidString) != nil)
            if pending.contains(material.id) { #expect(element(host, identifier: "pdf-history-pending-" + material.id.uuidString) != nil) }
        }
        switch path {
        case "done":
            let done = try #require(element(host, identifier: "pdf-history-done"))
            #expect((done as AnyObject).accessibilityPerformPress?() == true)
        case "escape":
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(host.performKeyEquivalent(with: escape))
        case "open":
            let target = try #require(materials.last)
            let open = try #require(element(host, identifier: "pdf-history-open-" + target.id.uuidString))
            #expect((open as AnyObject).accessibilityPerformPress?() == true)
            #expect(fixture.session.workspaceMaterialIDs == workspace + [target.id])
            #expect(fixture.session.selectedID == target.id)
            #expect((open as AnyObject).accessibilityPerformPress?() == true)
            #expect(fixture.session.workspaceMaterialIDs == workspace + [target.id])
        default:
            // SwiftUI's sheet binding invokes the same request when the native
            // presentation is dismissed through another available OS path.
            presentation.dismiss()
        }
        #expect(!presentation.isPresented && !presentation.canPerformWorkspaceCommands)
        presentation.didDismiss()
        #expect(presentation.canPerformWorkspaceCommands)
        if path != "open" { #expect(fixture.session.workspaceMaterialIDs == workspace && fixture.session.selectedID == selected) }
        #expect(fixture.session.materials == materials && fixture.session.pendingSaveIDs == pending)
        #expect(try fixture.draft.snapshot(profiles: [], resources: nil).options == draft)
        #expect(await fixture.engine.calls == 0)
        for material in materials {
            #expect(PDFDocument(url: try #require(fixture.session.originalURL(material.id)))?.pageCount == 1)
            for result in material.results {
                for output in result.outputs {
                    let url = try #require(fixture.session.resultURL(materialID: material.id, resultID: result.id, output: output))
                    let exported = fixture.root.appendingPathComponent(material.id.uuidString + "-" + output.filename)
                    #expect(fixture.session.export(url, to: exported))
                    #expect(PDFDocument(url: exported)?.pageCount == 1)
                }
            }
        }
    }

    @Test func dismissalDropsOldSubmitExportAndDeleteCommandsUntilTheWorkspaceIsReady() async throws {
        _ = NSApplication.shared
        let fixture = try PDFHistoryFixture(count: 2)
        defer { fixture.clean() }
        let presentation = PDFHistoryPresentation(), menu = NSMenu()
        presentation.activateWorkspace()
        let commands = presentation.commands
        commands.register(menu); defer { commands.unregister(menu) }
        let id = try #require(fixture.session.selectedID), original = try #require(fixture.session.originalURL(id))
        let workspace = fixture.session.workspaceMaterialIDs, materials = fixture.session.materials
        let submission = try fixture.draft.snapshot(profiles: [], resources: nil)
        let exported = fixture.root.appendingPathComponent("must-not-export.pdf")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        commands.perform { _ = fixture.session.submit(materialID: id, provider: nil, options: submission.options) }
        commands.perform { _ = fixture.session.export(original, to: exported) }
        presentation.present()
        commands.perform { _ = fixture.session.requestDeletion(.material(id)) }
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await nextTurn()
        presentation.dismiss()
        commands.perform { fixture.session.newProject() }
        #expect(!presentation.canPerformWorkspaceCommands)
        presentation.didDismiss(); await nextTurn()
        #expect(fixture.session.materials == materials && fixture.session.workspaceMaterialIDs == workspace)
        #expect(fixture.session.deletionConfirmation == nil && !FileManager.default.fileExists(atPath: exported.path))
        #expect(await fixture.engine.calls == 0)
        commands.perform { _ = fixture.session.submit(materialID: id, provider: nil, options: submission.options) }
        for _ in 0..<100 {
            if await fixture.engine.calls == 1, !fixture.session.hasActiveWork { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.engine.calls == 1)
        #expect(fixture.session.selectedMaterial?.results.count == 2)
        presentation.present(); presentation.deactivateWorkspace(); presentation.didDismiss()
        commands.perform { fixture.session.newProject() }
        #expect(fixture.session.workspaceMaterialIDs == workspace)
    }

    @Test(arguments: [0, 1, 12])
    func productionPDFHistoryCardsClearBothScrollerStylesAndReachTheLastMaterial(count: Int) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let fixture = try PDFHistoryFixture(count: count, pending: count > 0)
        defer { fixture.clean() }
        let materials = fixture.session.materials, pending = fixture.session.pendingSaveIDs
        let preferences = UserDefaults(suiteName: "PDFHistoryLayout." + UUID().uuidString)!
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            var frames: [String: CGRect] = [:]
            let host = NSHostingView(rootView: PDFHistoryView(session: fixture.session, close: {})
                .defaultAppStorage(preferences).environment(\.historyGeometryObserver, { frames[$0] = $1 })
                .background(Color.white).foregroundStyle(Color(red: 0.15, green: 0.22, blue: 0.28)).preferredColorScheme(.light))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 640), styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            for size in [NSSize(width: 460, height: 420), NSSize(width: 700, height: 640), NSSize(width: 1_200, height: 800)] {
                window.setContentSize(size); host.frame.size = size
                await settle(host)
                let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                for style in [NSScroller.Style.legacy, .overlay] {
                    scroll.scrollerStyle = style; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
                    scroll.tile(); await settle(host)
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                    await settle(host)
                    let document = try #require(scroll.documentView)
                    for _ in 0..<3 {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
                    }
                    let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let scroller = try #require(scroll.verticalScroller)
                    let scrollerFrame = scroller.convert(scroller.bounds, to: host)
                    let cards = frames.filter { $0.key.hasPrefix("pdf.") }.map(\.value).filter { $0.intersects(viewport) }
                    #expect(!cards.isEmpty)
                    for card in cards {
                        #expect(card.minX >= viewport.minX - 1)
                        #expect(card.maxX <= scrollerFrame.minX - 2, "PDF history card must clear the actual scroller: \(card), \(scrollerFrame)")
                    }
                    let lastKey = count == 0 ? "pdf.empty" : "pdf." + (try #require(materials.last)).id.uuidString
                    let last = try #require(frames[lastKey])
                    #expect(last.minY >= viewport.minY - 1 && last.maxY <= viewport.maxY + 1)
                    #expect(scroll.contentView.bounds.maxY >= document.bounds.maxY - 1)
                    let done = try #require(element(host, identifier: "pdf-history-done"))
                    let doneFrame = try #require((done as AnyObject).accessibilityFrame?())
                    let screenBounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                    #expect(screenBounds.insetBy(dx: -1, dy: -1).contains(doneFrame))
                    #expect(doneFrame.width >= 40 && doneFrame.height >= 28)
                    if let material = materials.last {
                        let open = try #require(element(host, identifier: "pdf-history-open-" + material.id.uuidString))
                        let hit = try #require((open as AnyObject).accessibilityFrame?())
                        let viewportScreen = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                        #expect(viewportScreen.insetBy(dx: -1, dy: -1).contains(hit))
                        #expect(hit.width >= 40 && hit.height >= 28)
                    }
                    if let output = ProcessInfo.processInfo.environment["WORKBENCH_PDF_HISTORY_OUTPUT"], count != 1, size.width != 1_200 {
                        let folder = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("history-\(count)-\(language)-\(Int(size.width))-\(style.rawValue).png"))
                    }
                    print("PDF_HISTORY_GEOMETRY count=\(count) language=\(language) width=\(Int(size.width)) style=\(style.rawValue) right=\(cards.map(\.maxX).max() ?? 0) scroller=\(scrollerFrame.minX)")
                }
            }
        }
        #expect(fixture.session.materials == materials && fixture.session.pendingSaveIDs == pending)
        #expect(await fixture.engine.calls == 0)
    }

    private func element(_ root: Any, identifier: String) -> NSObject? {
        guard let node = root as? NSObject else { return nil }
        if node.responds(to: NSSelectorFromString("accessibilityIdentifier")), node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
        for child in (node as AnyObject).accessibilityChildren?() ?? [] {
            if let found = element(child, identifier: identifier) { return found }
        }
        return nil
    }
    private func nextTurn() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ host: NSView) async {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
    }
}

@MainActor private final class PDFHistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-history-\(UUID())")
    let store: PDFMaterialStore
    let engine = PDFHistoryEngine()
    let session: PDFTranslationSession
    let draft = PDFSubmissionDraft()
    init(count: Int, pending: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("controlled.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        for index in 0..<count {
            var material = try store.importPDF(source)
            material.name = "\(index) A long controlled PDF history title 中文 with enough words to wrap in the narrow history window"
            material.updatedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            var options = PDFTranslationOptions(); options.content.operation = .typesetOnly; options.autoExtractGlossary = false
            var task = PDFBackgroundTask(provider: nil, options: options)
            let staging = try store.stagingDirectory(task.id, materialID: material.id)
            let dual = staging.appendingPathComponent("dual.pdf")
            try FileManager.default.copyItem(at: source, to: dual)
            let generated = PDFEngineResult(outputs: [.init(kind: .dual, url: dual)])
            if pending && index == count - 1 {
                task.status = .awaitingLocalSave
                try store.savePendingResult(.init(task: task, generated: generated, resultID: UUID()), materialID: material.id)
            } else {
                let result = try store.install(generated, task: task, material: material, resultID: UUID())
                material.results.append(result); material.selectedResultID = result.id; task.status = .completed
            }
            material.tasks.append(task); try store.save(material)
        }
        session = PDFTranslationSession(store: store, credentials: PDFHistoryCredentials(), engine: engine)
        draft.contentSettings.operation = .typesetOnly
        draft.outputSettings.mode = .translated; draft.outputSettings.layout = .alternatingPages; draft.outputSettings.watermark = .noWatermark
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class PDFHistoryCredentials: ProviderCredentials {
    func read(reference: ProviderCredentialReference) throws -> String? { Issue.record("History must not read credentials"); return nil }
    func save(_ value: String, reference: ProviderCredentialReference) throws { Issue.record("History must not save credentials") }
    func delete(reference: ProviderCredentialReference) throws { Issue.record("History must not delete credentials") }
}
private actor PDFHistoryEngine: PDFTranslating {
    var calls = 0
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        calls += 1
        let output = request.outputDirectory.appendingPathComponent("controlled.pdf")
        try FileManager.default.copyItem(at: request.inputURL, to: output)
        return .init(outputs: [.init(kind: .mono, url: output)])
    }
}
