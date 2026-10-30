import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor
struct TextWorkspaceEditorTests {
    @Test func productionFooterMenusKeepDrawingAndHitBoundsClearOfAdjacentButtons() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-footer-\(UUID())")
        let credentials = WorkspaceForbiddenCredentials(), service = WorkspaceForbiddenService()
        let session = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        let preferences = UserDefaults(suiteName: "TextFooterGeometry." + UUID().uuidString)!
        preferences.set("english", forKey: "interfaceLanguage")
        defer { _ = session.retrySaving(); try? FileManager.default.removeItem(at: root) }
        var measurements: [[String: Any]] = []
        for populated in [false, true] {
            if populated {
                _ = session.updateInput(text: "Controlled original text")
                _ = session.updateTranslation(text: "Controlled translated text")
            }
            for width in [1_120, 470] {
                var layoutFrames: [String: CGRect] = [:]
                let host = NSHostingView(rootView: WorkspaceProductionHost(session: session, providers: providers, width: CGFloat(width))
                    .defaultAppStorage(preferences).environment(\.textFooterGeometryObserver, { layoutFrames[$0] = $1 }))
                host.frame = NSRect(x: 0, y: 0, width: width, height: width == 470 ? 2_000 : 1_100)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                try await settle(host)
                for (name, menuLabel) in [("source", "More source actions"), ("target", "Export translation")] {
                    let menu = try #require(descendants(host).compactMap { $0 as? TextActionPopUpButton }.first { $0.accessibilityLabel() == menuLabel })
                    let menuHost = menu.convert(menu.bounds, to: host)
                    let neighbor = try #require(layoutFrames[name + ".previous"])
                    let menuLayout = try #require(layoutFrames[name + ".menu"])
                    let parent = try #require(menu.superview)
                    let hitInside = [menu.bounds.minX + 0.25, menu.bounds.maxX - 0.25].allSatisfy { x in
                        menu.hitTest(menu.convert(NSPoint(x: x, y: menu.bounds.midY), to: parent)) === menu
                    }
                    let hitOutside = [menu.bounds.minX - 0.25, menu.bounds.maxX + 0.25].contains { x in
                        menu.hitTest(menu.convert(NSPoint(x: x, y: menu.bounds.midY), to: parent)) != nil
                    }
                    let gap = menuHost.minX - neighbor.maxX
                    measurements.append(["width": width, "populated": populated, "menu": menuLabel, "menuBounds": NSStringFromRect(menuHost), "menuLayout": NSStringFromRect(menuLayout), "neighborBounds": NSStringFromRect(neighbor), "gap": gap, "alignmentInsets": String(describing: menu.alignmentRectInsets), "hitsBothNativeEdges": hitInside, "hitsOutsideNativeBounds": hitOutside])
                    print("FOOTER GEOMETRY \(width) populated=\(populated) \(menuLabel): native=\(menuHost) layout=\(menuLayout) neighbor=\(neighbor) gap=\(gap) insets=\(menu.alignmentRectInsets)")
                    #expect(gap >= 2.5, "Native menu drawing/hit bounds must retain the footer's 3-point gap")
                    #expect(!menuHost.intersects(neighbor), "Menu and preceding button must not overlap")
                    #expect(abs(menuHost.minX - menuLayout.minX) < 0.5 && abs(menuHost.width - menuLayout.width) < 0.5,
                        "Native drawing and hit bounds must match SwiftUI's reserved space")
                    #expect(abs(menuHost.midY - neighbor.midY) < 0.5 && menuHost.height == neighbor.height)
                    #expect(menu.isEnabled == (name == "source" || populated))
                    #expect(hitInside && !hitOutside, "AppKit hit testing must use the same bounds as the drawn menu")
                }
                if let output = ProcessInfo.processInfo.environment["WORKBENCH_TEXT_FOOTER_RENDER_OUTPUT"] {
                    let folder = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for scale in [1, 2] {
                        try renderFooter(host, scale: scale, to: folder.appendingPathComponent("text-\(width)-\(populated ? "populated" : "empty")-\(scale)x.png"))
                    }
                    try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("geometry.json"))
                }
                window.orderOut(nil); window.contentView = nil
            }
        }
        #expect(credentials.reads == 0 && session.history.isEmpty)
    }
    private func renderFooter(_ view: NSView, scale: Int, to file: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
    @Test func productionWorkspaceRetainsBothNativeEditorsAndToolbarUndoAcrossNarrowLayouts() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-layout-\(UUID())")
        let credentials = WorkspaceForbiddenCredentials(), service = WorkspaceForbiddenService()
        let session = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        defer { _ = session.retrySaving(); try? FileManager.default.removeItem(at: root) }
        _ = session.updateInput(text: "Original 中文 👩🏽‍💻")
        _ = session.updateTranslation(text: "Translation 译文")
        let host = NSHostingView(rootView: WorkspaceProductionHost(session: session, providers: providers, width: 1_120))
        host.frame = NSRect(x: 0, y: 0, width: 1_120, height: 1_600)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host)
        let initial = natives(host)
        #expect(initial.count == 2)
        let source = try #require(initial.first { $0.string == "Original 中文 👩🏽‍💻" })
        let target = try #require(initial.first { $0.string == "Translation 译文" })
        let sourceActions = try #require((source.delegate as? TextWorkspaceEditor.Coordinator)?.parent.actions)
        let targetActions = try #require((target.delegate as? TextWorkspaceEditor.Coordinator)?.parent.actions)
        #expect(sourceActions.editor === source && targetActions.editor === target)
        source.insertText("A", replacementRange: NSRange(location: 0, length: 0)); source.breakUndoCoalescing()
        target.insertText("B", replacementRange: NSRange(location: 0, length: 0)); target.breakUndoCoalescing()
        try await settle(host)
        host.rootView = WorkspaceProductionHost(session: session, providers: providers, width: 470)
        host.frame.size.width = 470
        try await settle(host)
        let narrow = natives(host)
        #expect(narrow.count == 2)
        #expect(narrow.contains { $0 === source } && narrow.contains { $0 === target })
        #expect(sourceActions.editor === source && targetActions.editor === target)
        sourceActions.undo(); targetActions.undo(); try await settle(host)
        #expect(session.workspace.inputDraft == "Original 中文 👩🏽‍💻")
        #expect(session.workspace.translation == "Translation 译文")
        host.rootView = WorkspaceProductionHost(session: session, providers: providers, width: 1_120)
        host.frame.size.width = 1_120
        try await settle(host)
        #expect(natives(host).contains { $0 === source } && natives(host).contains { $0 === target })
        sourceActions.redo(); targetActions.redo(); try await settle(host)
        #expect(session.workspace.inputDraft == "AOriginal 中文 👩🏽‍💻")
        #expect(session.workspace.translation == "BTranslation 译文")
        #expect(sourceActions.editor === source && targetActions.editor === target)
        #expect(credentials.reads == 0)
    }
    @Test func nativeUndoRedoAndIMECommitKeepCurrentTextAndSeparateUndoContexts() throws {
        _ = NSApplication.shared
        let state = WorkspaceEditorState("Original 中文 👩🏽‍💻")
        let first = try makeEditor(state)
        defer { first.window.contentView = nil }
        let editor = first.editor
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0)); editor.breakUndoCoalescing()
        #expect(state.text == "AOriginal 中文 👩🏽‍💻")
        try #require(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo(); #expect(editor.string == "Original 中文 👩🏽‍💻"); #expect(state.text == "Original 中文 👩🏽‍💻")
        editor.undoManager?.redo(); #expect(editor.string == "AOriginal 中文 👩🏽‍💻"); #expect(state.text == "AOriginal 中文 👩🏽‍💻")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(state.text == "AOriginal 中文 👩🏽‍💻")
        #expect(state.composition.contains(true))
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText() && state.text == "你AOriginal 中文 👩🏽‍💻")
        let other = try makeEditor(WorkspaceEditorState("Other workspace")); defer { other.window.contentView = nil }
        #expect(other.editor.undoManager?.canUndo == false)
        other.editor.undoManager?.undo(); #expect(other.editor.string == "Other workspace")
    }
    @Test func nativeReturnSubmitsWhileShiftReturnPasteUndoAndIMEOnlyEdit() throws {
        _ = NSApplication.shared
        let state = WorkspaceEditorState("# Heading"), fixture = try makeEditor(state)
        defer { fixture.window.contentView = nil }
        let native = fixture.editor
        var submitted: [String] = []
        state.submit = { submitted.append(state.text) }
        fixture.host.rootView = editor(state); fixture.host.layoutSubtreeIfNeeded()
        native.setSelectedRange(NSRange(location: native.string.utf16.count, length: 0))
        native.keyDown(with: try returnEvent(window: fixture.window))
        #expect(submitted == ["# Heading"])
        #expect(native.string == "# Heading")
        native.keyDown(with: try returnEvent(window: fixture.window, modifiers: .shift))
        #expect(native.string == "# Heading\n" && state.text == native.string)
        #expect(submitted.count == 1)
        withClipboard("- First\n- Second\n\n```swift\nlet value = 42\n```\n") { native.paste(nil) }
        native.breakUndoCoalescing()
        #expect(state.text.contains("let value = 42") && submitted.count == 1)
        let pasted = state.text
        state.actions.undo(); #expect(state.text == native.string && state.text != pasted)
        state.actions.redo(); #expect(state.text == pasted && submitted.count == 1)
        native.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let delegate = try #require(native.delegate as? TextWorkspaceEditor.Coordinator)
        #expect(!delegate.textView(native, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submitted.count == 1)
        native.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!native.hasMarkedText() && state.text.hasSuffix("你") && submitted.count == 1)
        native.keyDown(with: try returnEvent(window: fixture.window))
        #expect(submitted.count == 2 && submitted.last == state.text)
    }
    @Test func productionReturnCreatesIndependentHistoryAndRestoreNeverTranslates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-enter-history-\(UUID())")
        let credentials = WorkspaceMemoryCredentials(), service = WorkspaceRecordingService()
        let session = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        _ = session.setDirection(direction: .englishToChinese)
        let profile = try #require(providers.saveProfile(name: "Controlled local service", baseURL: "https://controlled.invalid", model: "local-only", apiKey: "fixture-only"))
        providers.setDefault(profile.id, for: .text)
        defer { _ = session.retrySaving(); try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: "TextEnterHistory." + UUID().uuidString)!
        preferences.set("zhHans", forKey: "interfaceLanguage")
        let host = NSHostingView(rootView: WorkspaceProductionHost(session: session, providers: providers, width: 1_120).defaultAppStorage(preferences))
        host.frame = NSRect(x: 0, y: 0, width: 1_120, height: 1_250)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host)
        let source = try #require(natives(host).first { $0.accessibilityLabel() == "输入原文" })
        let target = try #require(natives(host).first { $0 !== source })
        window.makeFirstResponder(source)
        withClipboard("First line\nSecond line\n\nMarkdown **bold**") { source.paste(nil) }
        source.breakUndoCoalescing()
        try await Task.sleep(for: .milliseconds(700))
        #expect(await service.requests.count == 0)
        #expect(session.history.isEmpty)
        source.keyDown(with: try returnEvent(window: window, modifiers: .shift))
        #expect(session.workspace.inputDraft.hasSuffix("\n") && session.history.isEmpty)
        source.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let sourceDelegate = try #require(source.delegate as? TextWorkspaceEditor.Coordinator)
        #expect(!sourceDelegate.textView(source, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        source.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await service.requests.count == 0)
        source.keyDown(with: try returnEvent(window: window))
        try await waitForHistory(session, count: 1, host: host)
        let first = try #require(session.history.first)
        #expect(first.input == session.workspace.inputDraft && first.translation == "受控译文 · Controlled translation")
        target.setSelectedRange(NSRange(location: target.string.utf16.count, length: 0))
        target.keyDown(with: try returnEvent(window: window))
        #expect(target.string.hasSuffix("\n"))
        #expect(await service.requests.count == 1)
        #expect(session.history == [first])
        #expect(await session.flushPendingSaves())
        #expect(session.openHistory(first.id))
        try await settle(host)
        #expect(await service.requests.count == 1 && session.history == [first])
        let restoredSource = try #require(natives(host).first { $0.accessibilityLabel() == "输入原文" })
        window.makeFirstResponder(restoredSource)
        restoredSource.keyDown(with: try returnEvent(window: window))
        try await waitForHistory(session, count: 2, host: host)
        #expect(session.history[0].id != first.id && session.history[1] == first)
        #expect(await service.requests.count == 2)
        #expect(await session.flushPendingSaves())
        if let output = ProcessInfo.processInfo.environment["WORKBENCH_TEXT_HISTORY_RENDER_OUTPUT"] {
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try render(host, to: folder.appendingPathComponent("text-wide.png"))
            host.rootView = WorkspaceProductionHost(session: session, providers: providers, width: 470).defaultAppStorage(preferences)
            host.frame.size = NSSize(width: 470, height: 2_000); try await settle(host)
            try render(host, to: folder.appendingPathComponent("text-narrow.png"))
            for width in [470, 1_120] {
                let historyHost = NSHostingView(rootView: TextTranslationHistoryView(session: session).defaultAppStorage(preferences).modifier(WorkspaceProductionAppearance()))
                historyHost.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let historyWindow = NSWindow(contentRect: historyHost.frame, styleMask: [], backing: .buffered, defer: false)
                historyWindow.contentView = historyHost; try await settle(historyHost)
                try render(historyHost, to: folder.appendingPathComponent("history-\(width).png"))
                historyWindow.contentView = nil
            }
        }
        #expect(session.clear() && session.history.count == 2)
    }
    @Test func productionAutomaticLanguageControlsRemainUsableWithLongNamesAndHiddenTools() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-auto-layout-\(UUID())")
        let credentials = WorkspaceForbiddenCredentials(), service = WorkspaceForbiddenService()
        let session = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        defer { _ = session.retrySaving(); try? FileManager.default.removeItem(at: root) }
        _ = session.updateInput(text: "This English paragraph describes how to read books and learn another language.")
        _ = session.updateTranslation(text: "A locally edited translation for checking the export menu.")
        _ = session.setTargetLanguage(.init(rawValue: "sr-Latn-BA"))
        let preferences = UserDefaults(suiteName: "TextAutomaticLayout." + UUID().uuidString)!
        preferences.set("english", forKey: "interfaceLanguage")
        let host = NSHostingView(rootView: WorkspaceProductionHost(session: session, providers: providers, width: 470, toolsVisible: false).defaultAppStorage(preferences))
        host.frame = NSRect(x: 0, y: 0, width: 470, height: 1_650)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host)
        for _ in 0..<100 where session.isDetectingSourceLanguage { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        #expect(session.detectedSourceLanguage == .english && session.workspace.automaticallyDetectsSourceLanguage)
        for width in [470, 1_120] {
            host.rootView = WorkspaceProductionHost(session: session, providers: providers, width: CGFloat(width), toolsVisible: false).defaultAppStorage(preferences)
            host.frame.size = NSSize(width: width, height: width == 470 ? 1_650 : 1_000)
            window.setContentSize(host.frame.size)
            try await settle(host)
            let popups = descendants(host).compactMap { $0 as? NSPopUpButton }
            let source = try #require(popups.first { $0.accessibilityLabel() == "Source language" })
            #expect(source.accessibilityValue() as? String == "Detect language · English")
            #expect(natives(host).count == 2)
            for popup in popups {
                let rect = popup.convert(popup.bounds, to: host)
                #expect(rect.minX >= -1 && rect.maxX <= host.bounds.maxX + 1)
            }
            if let output = ProcessInfo.processInfo.environment["WORKBENCH_TEXT_CONTROLS_RENDER_OUTPUT"] {
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try render(host, to: folder.appendingPathComponent("text-auto-long-hidden-\(width).png"))
            }
        }
        #expect(credentials.reads == 0 && session.history.isEmpty)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func waitForHistory(_ session: TextTranslationSession, count: Int, host: NSView) async throws {
        for _ in 0..<100 {
            if session.history.count == count && !session.isRunning { try await settle(host); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Explicit Return did not finish a local controlled translation")
    }
    private func render(_ view: NSView, to file: URL) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
    private func returnEvent(window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
    @Test func groupedNativeUndoRedoPublishesOnlyFinalTextSynchronously() throws {
        _ = NSApplication.shared
        let initial = String(repeating: "Source 中文 👩🏽‍💻 é e\u{301}\n", count: 4_200)
        let state = WorkspaceEditorState(initial), fixture = try makeEditor(state)
        defer { fixture.window.contentView = nil }
        let native = fixture.editor, undo = try #require(native.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        var expected = initial
        for index in 0..<100 {
            let added = "\(index)新"
            native.insertText(added, replacementRange: NSRange(location: native.string.utf16.count, length: 0))
            native.breakUndoCoalescing()
            expected += added
        }
        undo.endUndoGrouping()
        try #require(undo.canUndo)
        #expect(Array(state.text.utf8) == Array(expected.utf8))
        state.committed.removeAll()
        undo.undo()
        #expect(state.committed.count == 1)
        #expect(Array(state.text.utf8) == Array(initial.utf8))
        #expect(Array(native.string.utf8) == Array(initial.utf8))
        try #require(undo.canRedo)
        state.committed.removeAll()
        undo.redo()
        #expect(state.committed.count == 1)
        #expect(Array(state.text.utf8) == Array(expected.utf8))
        #expect(Array(native.string.utf8) == Array(expected.utf8))
    }
    @Test(arguments: ["paste", "cut", "deleteBackward", "deleteForward", "insertNewline"])
    func nativeClipboardAndKeyboardCommandsPublishCommittedText(command: String) throws {
        _ = NSApplication.shared
        let initial = "Start 中文 👩🏽‍💻 e\u{301} End", pasted = "An apple 中文 👩🏽‍💻 é e\u{301}\n"
        let state = WorkspaceEditorState(initial), fixture = try makeEditor(state)
        defer { fixture.window.contentView = nil }
        let native = fixture.editor
        #expect(fixture.window.firstResponder === native)
        let expected: String
        switch command {
        case "paste":
            expected = pasted
            native.selectAll(nil)
            withClipboard(pasted) { native.paste(nil) }
        case "cut":
            expected = "Start  👩🏽‍💻 e\u{301} End"
            native.setSelectedRange((initial as NSString).range(of: "中文"))
            withClipboard("") { native.cut(nil) }
        case "deleteBackward":
            expected = String(initial.dropLast())
            native.setSelectedRange(NSRange(location: initial.utf16.count, length: 0))
            native.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        case "deleteForward":
            expected = String(initial.dropFirst())
            native.setSelectedRange(NSRange(location: 0, length: 0))
            native.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        default:
            expected = initial + "\n"
            native.setSelectedRange(NSRange(location: initial.utf16.count, length: 0))
            native.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        #expect(Array(native.string.utf8) == Array(expected.utf8))
        #expect(Array(state.text.utf8) == Array(expected.utf8))
        #expect(state.committed.count == 1)
        fixture.host.rootView = editor(state); fixture.host.layoutSubtreeIfNeeded()
        #expect(Array(native.string.utf8) == Array(expected.utf8))
        state.selected.removeAll()
        native.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(state.selected.last == (expected as NSString).substring(to: 2))
    }
    @Test func productionPastePersistsBothEditorsAfterLayoutAndReopen() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-paste-\(UUID())")
        let credentials = WorkspaceForbiddenCredentials(), service = WorkspaceForbiddenService()
        let session = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: service)
        defer { _ = session.retrySaving(); try? FileManager.default.removeItem(at: root) }
        _ = session.updateInput(text: "Original source")
        _ = session.updateTranslation(text: "Original target")
        let host = NSHostingView(rootView: WorkspaceProductionHost(session: session, providers: providers, width: 1_120))
        host.frame = NSRect(x: 0, y: 0, width: 1_120, height: 1_600)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host)
        let source = try #require(natives(host).first { $0.string == "Original source" })
        let target = try #require(natives(host).first { $0.string == "Original target" })
        let pastedSource = "An apple 中文 👩🏽‍💻 e\u{301}\n", pastedTarget = "手动译文 é e\u{301}\n"
        #expect(window.makeFirstResponder(source))
        source.selectAll(nil); withClipboard(pastedSource) { source.paste(nil) }
        #expect(Array(session.workspace.inputDraft.utf8) == Array(pastedSource.utf8))
        #expect(window.makeFirstResponder(target))
        target.selectAll(nil); withClipboard(pastedTarget) { target.paste(nil) }
        #expect(Array(session.workspace.translation.utf8) == Array(pastedTarget.utf8))
        host.rootView = WorkspaceProductionHost(session: session, providers: providers, width: 470)
        host.frame.size.width = 470
        try await settle(host)
        #expect(Array(source.string.utf8) == Array(pastedSource.utf8))
        #expect(Array(target.string.utf8) == Array(pastedTarget.utf8))
        #expect(await session.flushPendingSaves())
        let reopened = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: service)
        #expect(Array(reopened.workspace.inputDraft.utf8) == Array(pastedSource.utf8))
        #expect(Array(reopened.workspace.translation.utf8) == Array(pastedTarget.utf8))
        #expect(credentials.reads == 0)
    }
    @Test func streamAppendPreservesSelectionAndMarkedTextIsNotReplaced() throws {
        _ = NSApplication.shared
        let state = WorkspaceEditorState(String(repeating: "Long paragraph 中文\n", count: 200))
        let fixture = try makeEditor(state); defer { fixture.window.contentView = nil }
        let scroll = try #require(fixture.editor.enclosingScrollView)
        fixture.editor.setSelectedRange(NSRange(location: 20, length: 12))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
        let scrollOrigin = scroll.contentView.bounds.origin
        #expect(scrollOrigin.y > 0)
        let prior = fixture.editor.selectedRange(); state.text += "Stream suffix"
        fixture.host.rootView = editor(state); fixture.host.layoutSubtreeIfNeeded()
        #expect(fixture.editor.selectedRange() == prior)
        #expect(abs(scroll.contentView.bounds.origin.y - scrollOrigin.y) < 1)
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
        fixture.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.host.rootView = editor(state); fixture.host.layoutSubtreeIfNeeded()
        #expect(fixture.editor.hasMarkedText())
        fixture.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0)); #expect(state.text.hasPrefix("你"))
    }
    @Test func canonicallyEquivalentUnicodeStillUpdatesExactNativeAndSavedBytes() throws {
        _ = NSApplication.shared
        let state = WorkspaceEditorState("é"), fixture = try makeEditor(state)
        defer { fixture.window.contentView = nil }
        state.text = "e\u{301}"
        fixture.host.rootView = editor(state); fixture.host.layoutSubtreeIfNeeded()
        #expect(Array(fixture.editor.string.utf8) == Array("e\u{301}".utf8))
        fixture.editor.setSelectedRange(NSRange(location: 0, length: (fixture.editor.string as NSString).length))
        fixture.editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Array(state.text.utf8) == Array("é".utf8))
    }
    private func editor(_ state: WorkspaceEditorState) -> TextWorkspaceEditor {
        TextWorkspaceEditor(text: state.text, label: "Test text", actions: state.actions, changed: { state.text = $0; state.committed.append($0); return true }, submit: state.submit, composition: { state.composition.append($0) }, selection: { state.selected.append($0) })
    }
    private func withClipboard(_ text: String, action: () -> Void) {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let restored = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(restored)
        }
        board.clearContents(); board.setString(text, forType: .string)
        action()
    }
    private func makeEditor(_ state: WorkspaceEditorState) throws -> (window: NSWindow, host: NSHostingView<TextWorkspaceEditor>, editor: NSTextView) {
        let host = NSHostingView(rootView: editor(state)); host.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let native = try #require(find(host)); window.makeFirstResponder(native)
        return (window, host, native)
    }
    private func find(_ view: NSView) -> NSTextView? { if let value = view as? NSTextView { return value }; return view.subviews.lazy.compactMap(find).first }
    private func natives(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(natives) }
    private func settle(_ host: NSView) async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        host.layoutSubtreeIfNeeded()
    }
}
@MainActor private struct WorkspaceProductionHost: View {
    let session: TextTranslationSession
    let providers: ProviderConfigurationSession
    let width: CGFloat
    var toolsVisible = true
    var body: some View { TextTranslationView(session: session, providers: providers, initialToolsVisible: toolsVisible).frame(width: width).modifier(WorkspaceProductionAppearance()) }
}
@MainActor private final class WorkspaceForbiddenCredentials: ProviderCredentials {
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; throw ProviderConfigurationError.credential }
    func save(_ value: String, reference: ProviderCredentialReference) throws { Issue.record("Editor layout must not save credentials") }
    func delete(reference: ProviderCredentialReference) throws { Issue.record("Editor layout must not delete credentials") }
}
private struct WorkspaceForbiddenService: TextTranslating, ProviderConnectionChecking {
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws { Issue.record("Editor layout must not request translation"); throw TextTranslationError.processing }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { Issue.record("Editor layout must not check connections"); throw ProviderConfigurationError.network }
}
@MainActor private final class WorkspaceEditorState {
    var text: String
    var composition: [Bool] = []
    var committed: [String] = []
    var selected: [String] = []
    var submit: (() -> Void)?
    let actions = TextEditorActions()
    init(_ text: String) { self.text = text }
}

@MainActor private final class WorkspaceMemoryCredentials: ProviderCredentials {
    private var values: [ProviderCredentialReference: String] = [:]
    func read(reference: ProviderCredentialReference) throws -> String? { values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
}
private actor WorkspaceRecordingService: TextTranslating, ProviderConnectionChecking {
    var requests: [TextTranslationRequest] = []
    func translate(_ request: TextTranslationRequest, apiKey: String, onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        requests.append(request)
        await onEvent(.delta("受控译文 · Controlled translation"))
    }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { .directoryAvailable(modelListed: true, modelCount: 1) }
}

private struct WorkspaceProductionAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(red: 0.15, green: 0.22, blue: 0.28))
            .tint(Color(red: 0.16, green: 0.47, blue: 0.53))
            .background(Color(red: 0.93, green: 0.96, blue: 0.97))
            .preferredColorScheme(.light)
    }
}
