import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct SavedCredentialFieldTests {
    @Test func legacySavedCredentialShowsMaskWhenSettingsAppearWithoutLoadingSecret() async throws {
        _ = NSApplication.shared
        let target = CredentialMetadataTarget(service: "legacy-mask-test-\(UUID())", account: "dummy", scope: "dummy")
        #expect(!SavedCredentialPresence.contains(service: target.service, scope: target.scope))
        var draft = ""
        let host = NSHostingView(rootView: SavedCredentialField(title: "API Key", hasSavedKey: false,
            key: Binding(get: { draft }, set: { draft = $0 }), metadataTarget: target,
            metadataLookup: { _ in true }).frame(width: 320, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap(secureField).first
        }
        let field = try #require(secureField(host))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while field.placeholderString != "****************" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
        }
        #expect(field.placeholderString == "****************")
        #expect(field.stringValue.isEmpty && draft.isEmpty)
        #expect(SavedCredentialPresence.contains(service: target.service, scope: target.scope))
    }

    @Test func savedCredentialRendersOnlyMaskAndAcceptsReplacementWithoutLoadingSecret() throws {
        _ = NSApplication.shared
        var draft = ""
        let host = NSHostingView(rootView: SavedCredentialField(title: "API Key", hasSavedKey: true,
            key: Binding(get: { draft }, set: { draft = $0 })).frame(width: 320, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap(secureField).first
        }
        let field = try #require(secureField(host))
        #expect(field.placeholderString == "****************")
        #expect(field.stringValue.isEmpty && draft.isEmpty)
        field.stringValue = "replacement-test-key"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(draft == "replacement-test-key")
        #expect(field.cell is NSSecureTextFieldCell)
    }
}
