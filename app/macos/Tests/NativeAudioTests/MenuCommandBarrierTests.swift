import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite @MainActor struct MenuCommandBarrierTests {
    @Test func nativeMenuEndThenActionCommitsBeforeRetainedSubmitAndExport() async throws {
        _ = NSApplication.shared
        let draft = PDFSubmissionDraft(); draft.contentSettings.operation = .typesetOnly
        let output = PDFOutputSelection()
        let commands = MenuCommandBarrier(); commands.activate()
        let picker = CommittedPicker(title: "Scan", selection: draft.access(\.contentSettings).binding(\.scanMode), options: [("Detect", .detect), ("Automatic", .automaticWorkaround)])
        let host = NSHostingView(rootView: picker.environment(\.menuCommandBarrier, commands))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        host.layoutSubtreeIfNeeded()
        let scan = try #require(findPopup(host))
        let menu = try #require(scan.menu)
        defer { withExtendedLifetime(host) {} }
        var submitted: PDFTranslationOptions?
        var exported: PDFOutputKind?
        let retainedSubmit = { commands.perform { submitted = try? draft.snapshot(profiles: [], resources: nil).options } }
        let retainedExport = { commands.perform { exported = output.kind } }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        draft.access(\.contentSettings).binding(\.processGraphicElements).wrappedValue = false
        retainedSubmit(); retainedExport()
        #expect(submitted == nil && exported == nil)
        // The native trace reports didEndTracking before the actual selection
        // action, while AX can already invoke the next button. Do not manually
        // select the control before queuing those consuming commands.
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(submitted == nil && exported == nil)
        menu.performActionForItem(at: 1)
        output.kind = .mono
        await nextMainTurn()
        #expect(submitted?.content.scanMode == .automaticWorkaround)
        #expect(submitted?.content.processGraphicElements == false)
        #expect(exported == .mono)
    }

    @Test func cancelledMenusAndOverlappingTrackingDrainInOrderWithoutLosingNewTracking() async {
        let commands = MenuCommandBarrier(); commands.activate()
        let first = NSMenu(), second = NSMenu()
        commands.register(first); commands.register(second)
        defer { commands.unregister(first); commands.unregister(second) }
        var observed: [Int] = []
        func signal(_ name: Notification.Name, _ menu: NSMenu) { NotificationCenter.default.post(name: name, object: menu) }
        signal(NSMenu.didBeginTrackingNotification, first)
        signal(NSMenu.didBeginTrackingNotification, second)
        commands.perform { observed.append(1) }; commands.perform { observed.append(2) }
        signal(NSMenu.didEndTrackingNotification, first)
        await nextMainTurn(); #expect(observed.isEmpty)
        signal(NSMenu.didEndTrackingNotification, second)
        // A newly opened menu must not be released by the previous end callback.
        signal(NSMenu.didBeginTrackingNotification, second)
        await nextMainTurn(); #expect(observed.isEmpty)
        signal(NSMenu.didEndTrackingNotification, second) // Escape: no choice action.
        await nextMainTurn(); #expect(observed == [1, 2])
        commands.perform { observed.append(3) }; #expect(observed == [1, 2, 3])
    }

    @Test func leavingPageAndReentrantCommandPreventStaleCommands() async {
        let commands = MenuCommandBarrier(); commands.activate()
        let menu = NSMenu(); commands.register(menu)
        var observed: [Int] = []
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        commands.perform { observed.append(1) }
        commands.deactivate()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        commands.perform { observed.append(2) }
        await nextMainTurn(); #expect(observed.isEmpty)
        commands.activate()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        commands.perform { observed.append(3); commands.deactivate() }
        commands.perform { observed.append(4) }
        commands.unregister(menu)
        await nextMainTurn(); #expect(observed == [3])
    }

    @Test func onlyRegisteredMenusDeferCommands() async {
        let commands = MenuCommandBarrier(); commands.activate()
        let local = NSMenu(), unrelated = NSMenu()
        commands.register(local); commands.register(local)
        var count = 0
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: unrelated)
        commands.perform { count += 1 }; #expect(count == 1)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: local)
        commands.perform { count += 1 }; #expect(count == 1)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: unrelated)
        await nextMainTurn(); #expect(count == 1)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: local)
        await nextMainTurn(); #expect(count == 2)
        commands.unregister(local)
    }

    private func findPopup(_ view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for child in view.subviews { if let popup = findPopup(child) { return popup } }
        return nil
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}
