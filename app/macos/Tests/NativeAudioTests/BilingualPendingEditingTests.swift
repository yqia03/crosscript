import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualPendingEditingTests {
    @Test func failedFirstSaveCanBeEditedThroughNativeTextViewAndSharedWithCaptions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingStore = RecordingStore(root: root)
        let recordings = RecordingSession(store: recordingStore, recorder: PendingEditorRecorder())
        var fail = true, attempts = 0, saved: BilingualResult?
        let state = BilingualSessionState { value in
            attempts += 1
            if fail { throw AudioProcessingError.storage }
            saved = value; return value
        }
        let config = AudioServiceConfiguration(provider: .openAI, model: "gpt-realtime-translate")
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: config, direction: .englishToChinese))
        state.receive(.text(channel: .source, eventID: "source", delta: "Original source", elapsedMilliseconds: nil), generation: token)
        state.receive(.text(channel: .translation, eventID: "translation", delta: "原始译文", elapsedMilliseconds: nil), generation: token)
        let resultID = state.result?.id
        state.finish()
        #expect(state.needsSaveRetry && saved == nil && attempts == 1)
        let main = NSHostingView(rootView: BilingualTranscriptView(state: state, recordings: recordings, configuration: config,
            openSettings: {}, openCaptions: {}).frame(width: 580, height: 1150))
        let caption = NSHostingView(rootView: BilingualCaptionView(state: state, recordings: recordings).frame(width: 420, height: 400))
        let mainWindow = host(main, size: NSSize(width: 580, height: 1150))
        let captionWindow = host(caption, size: NSSize(width: 420, height: 400))
        defer { mainWindow.contentView = nil; captionWindow.contentView = nil }
        try await until { textViews(main).filter(\.isEditable).count == 2 }
        let sourceEditor = try #require(textViews(main).first { $0.isEditable && $0.string == "Original source" })
        sourceEditor.insertText("Edited pending source", replacementRange: NSRange(location: 0, length: sourceEditor.string.utf16.count))
        try await until { state.document.source.text == "Edited pending source" }
        try await until { textViews(caption).contains { $0.string == "Edited pending source" && !$0.isEditable } }
        let translatedEditor = try #require(textViews(main).first { $0.isEditable && $0.string == "原始译文" })
        translatedEditor.insertText("保留的用户修改", replacementRange: NSRange(location: 0, length: translatedEditor.string.utf16.count))
        try await until { state.document.translation.text == "保留的用户修改" }
        #expect(state.needsSaveRetry && state.result?.id == resultID && attempts == 1)
        #expect(state.document.exported().contains("Edited pending source") && state.document.exported().contains("保留的用户修改"))
        state.receive(.text(channel: .source, eventID: "late", delta: "must not replace edit", elapsedMilliseconds: nil), generation: token)
        #expect(state.document.source.text == "Edited pending source")
        fail = false; state.retrySave()
        #expect(!state.needsSaveRetry && attempts == 2 && saved?.id == resultID)
        #expect(saved?.document.source.text == "Edited pending source" && saved?.document.translation.text == "保留的用户修改")
        try await until { textViews(main).count == 2 && textViews(main).allSatisfy { !$0.isEditable } }
    }
    private func host<V: View>(_ view: NSHostingView<V>, size: NSSize) -> NSWindow {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded(); return window
    }
    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Native editor binding or shared caption did not update before bounded deadline")
    }
}
@MainActor private final class PendingEditorRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
