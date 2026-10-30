import AppKit
import SwiftUI
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct TranscriptEditorTests {
    @Test func nativeUndoRedoAndFollowingInputStayConsistentWithSavedAndExportedText() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let credentials = TestAudioCredentials()
        let session = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: EditorFixtureTranscriber())
        await session.transcribe(id)
        let result = try #require(session.materials[id]?.results.first)
        let recording = try #require(fixture.recordings.selectedRecording)
        try withEditor(session: session, recording: recording, result: result) { editor in
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.breakUndoCoalescing()
            #expect(editor.string == "aOriginal 中文")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "aOriginal 中文")
            try #require(editor.undoManager?.canUndo == true)
            editor.undoManager?.undo()
            #expect(editor.string == "Original 中文")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "Original 中文")
            editor.undoManager?.redo()
            #expect(editor.string == "aOriginal 中文")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "aOriginal 中文")
            editor.undoManager?.undo()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("新", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.string == "新Original 中文")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "新Original 中文")
            for format in TranscriptExportFormat.allCases {
                let destination = fixture.root.appendingPathComponent("edited.\(format.rawValue)")
                #expect(session.exportTranscript(recordingID: id, resultID: result.id, format: format, to: destination))
                #expect(try String(contentsOf: destination, encoding: .utf8) == "新Original 中文")
            }
        }
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: EditorFixtureTranscriber())
        #expect(reopened.transcriptText(recordingID: id, resultID: result.id) == "新Original 中文")
    }

    @Test func undoOfARepeatedParagraphKeepsTheSurvivingSourceAndCompositionSavesCommittedText() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let credentials = TestAudioCredentials()
        let response = TranscribedAudio(text: "Echo\nEcho", anchors: [
            TranscriptAnchor(sourceStart: 0.1, sourceEnd: 0.3, range: TranscriptTextRange(location: 0, length: 4)),
            TranscriptAnchor(sourceStart: 0.6, sourceEnd: 0.9, range: TranscriptTextRange(location: 5, length: 4))
        ])
        let service = EditorFixtureTranscriber(response: response)
        let session = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: service)
        await session.transcribe(id)
        let result = try #require(session.materials[id]?.results.first)
        let recording = try #require(fixture.recordings.selectedRecording)
        try withEditor(session: session, recording: recording, result: result) { editor in
            editor.setSelectedRange(NSRange(location: 0, length: 5))
            editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.breakUndoCoalescing()
            #expect(editor.string == "Echo")
            #expect(session.materials[id]?.results.first?.paragraphs.map(\.playbackStart) == [0.6])
            editor.undoManager?.undo()
            #expect(editor.string == "Echo\nEcho")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "Echo\nEcho")
            // Removed source anchors are not invented by undo. The surviving second source stays second.
            #expect(session.materials[id]?.results.first?.paragraphs.map(\.playbackStart) == [nil, 0.6])
            editor.undoManager?.redo()
            #expect(editor.string == "Echo")
            #expect(session.materials[id]?.results.first?.paragraphs.map(\.playbackStart) == [0.6])
            editor.undoManager?.undo()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!editor.hasMarkedText())
            #expect(editor.string == "你Echo\nEcho")
            #expect(session.transcriptText(recordingID: id, resultID: result.id) == "你Echo\nEcho")
            #expect(session.materials[id]?.results.first?.paragraphs.last?.playbackStart == 0.6)
        }
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: service)
        #expect(reopened.transcriptText(recordingID: id, resultID: result.id) == "你Echo\nEcho")
        #expect(reopened.materials[id]?.results.first?.paragraphs.last?.playbackStart == 0.6)
    }

    @Test func paragraphInlineEditorSavesTypingUndoAndCompositionWithoutStartingPlayback() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let response = TranscribedAudio(text: "Hello world.\n你好。", anchors: [
            TranscriptAnchor(sourceStart: 0.1, sourceEnd: 0.4, range: TranscriptTextRange(location: 0, length: 12)),
            TranscriptAnchor(sourceStart: 0.6, sourceEnd: 0.9, range: TranscriptTextRange(location: 13, length: 3))
        ])
        let session = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: TestAudioCredentials(), service: EditorFixtureTranscriber(response: response))
        await session.transcribe(id)
        let result = try #require(session.materials[id]?.results.first)
        let recording = try #require(fixture.recordings.selectedRecording)
        let domain = "T6.ParagraphTest." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(true, forKey: "transcriptShowsParagraphs")
        preferences.set("english", forKey: "interfaceLanguage")
        _ = NSApplication.shared
        var playbackStarts: [TimeInterval] = []
        let host = NSHostingView(rootView: TranscriptEditorView(processing: session, recording: recording,
            result: result, playFrom: { playbackStarts.append($0) }).defaultAppStorage(preferences).frame(width: 650, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScrollView(host))
        let document = try #require(scroll.documentView)
        // SwiftUI's lazy scroll content is not exposed through AX in the bare
        // SwiftPM runner. Activate its first native paragraph button instead.
        let editButton = try #require(findButton(document))
        editButton.performClick(nil)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findTextView(host))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        editor.insertText("everyone", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        #expect(session.transcriptText(recordingID: id, resultID: result.id) == "Hello everyone.\n你好。")
        editor.undoManager?.undo()
        #expect(session.transcriptText(recordingID: id, resultID: result.id) == response.text)
        editor.undoManager?.redo()
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(session.transcriptText(recordingID: id, resultID: result.id) == "Hello 你everyone.\n你好。")
        #expect(playbackStarts.isEmpty)
        #expect(session.materials[id]?.results.first?.paragraphs.map(\.playbackStart) == [0.1, 0.6])
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: TestAudioCredentials(), service: EditorFixtureTranscriber())
        #expect(reopened.transcriptText(recordingID: id, resultID: result.id) == "Hello 你everyone.\n你好。")
    }

    @Test func clearingAnInlineSegmentKeepsOnlyTheFollowingSegmentsSourceAfterReopen() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let originalAudio = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let response = TranscribedAudio(text: "One.Two.", anchors: [
            TranscriptAnchor(sourceStart: 0.1, sourceEnd: 0.4, range: TranscriptTextRange(location: 0, length: 4)),
            TranscriptAnchor(sourceStart: 0.6, sourceEnd: 0.9, range: TranscriptTextRange(location: 4, length: 4))
        ])
        let session = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: TestAudioCredentials(), service: EditorFixtureTranscriber(response: response))
        await session.transcribe(id)
        let result = try #require(session.materials[id]?.results.first)
        let recording = try #require(fixture.recordings.selectedRecording)
        let domain = "T6.EmptyParagraphTest." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(true, forKey: "transcriptShowsParagraphs")
        _ = NSApplication.shared
        var playbackStarts: [TimeInterval] = []
        let host = NSHostingView(rootView: TranscriptEditorView(processing: session, recording: recording,
            result: result, playFrom: { playbackStarts.append($0) }).defaultAppStorage(preferences).frame(width: 650, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let document = try #require(findScrollView(host)?.documentView)
        let editButton = try #require(findButton(document))
        editButton.performClick(nil)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findTextView(host))
        window.makeFirstResponder(editor)
        #expect(editor.string == "One.")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string.isEmpty)
        #expect(session.transcriptText(recordingID: id, resultID: result.id) == "Two.")
        #expect(session.playbackStart(recordingID: id, resultID: result.id, paragraphRange: NSRange(location: 0, length: 0)) == nil)
        #expect(session.playbackStart(recordingID: id, resultID: result.id, paragraphRange: NSRange(location: 0, length: 4)) == 0.6)
        #expect(playbackStarts.isEmpty)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: TestAudioCredentials(), service: EditorFixtureTranscriber())
        #expect(reopened.transcriptText(recordingID: id, resultID: result.id) == "Two.")
        #expect(reopened.materials[id]?.results.first?.currentDocument.anchors.map(\.id) == [response.anchors[1].id])
        #expect(reopened.materials[id]?.results.first?.paragraphs.map(\.playbackStart) == [0.6])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == originalAudio)
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }

    private func findButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { findButton($0) }.first
    }

    private func withEditor(session: PostRecordingSession, recording: Recording, result: TranscriptResult,
                            body: (NSTextView) throws -> Void) throws {
        let domain = "T6.EditorTest." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(false, forKey: "transcriptShowsParagraphs")
        _ = NSApplication.shared
        let root = TranscriptEditorView(processing: session, recording: recording, result: result, playFrom: { _ in })
            .defaultAppStorage(preferences).frame(width: 650, height: 500)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findTextView(host))
        window.makeFirstResponder(editor)
        try body(editor)
    }

    private func findTextView(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
private struct EditorFixtureTranscriber: FileTranscribing {
    var response = TranscribedAudio(text: "Original 中文")
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String { response.text }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio { response }
}
