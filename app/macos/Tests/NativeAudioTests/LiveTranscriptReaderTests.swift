import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor struct LiveTranscriptReaderTests {
    @Test(arguments: ["\n", "\r\n", "\n\n \t", ""])
    func followingKeepsLatestBodyLineVisibleInSmallCaptionWithoutTrimming(_ suffix: String) throws {
        _ = NSApplication.shared
        for latest in ["Controlled source segment 25: recording is retained.", "本地受控译文第25段，录音持续保存。", "Latest Unicode e\u{301} 👨‍👩‍👧‍👦"] {
            let text = String(repeating: "Earlier retained text.\n", count: 24) + latest + suffix
            let reader = LiveTranscriptReader(text: text, followsLatest: false, label: "Controlled caption", fontSize: 24, onReview: {})
            let host = NSHostingView(rootView: reader.frame(width: 692, height: 60))
            host.frame = NSRect(x: 0, y: 0, width: 692, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let scroll = try #require(findReader(host))
            let native = try #require(scroll.documentView as? NSTextView)
            let manager = try #require(native.layoutManager)
            let container = try #require(native.textContainer)
            manager.ensureLayout(for: container)
            LiveTranscriptReader(text: text, followsLatest: true, label: "Controlled caption", fontSize: 24, onReview: {}).update(scroll)
            let characterRange = (text as NSString).range(of: latest)
            let glyphRange = manager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let glyphRect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
            let visible = scroll.documentVisibleRect
            if suffix == "\n", latest.hasPrefix("Controlled") {
                print("CAPTION_TAIL height=60 font=24 visible=\(visible) latestBody=\(glyphRect) clippedTop=\(max(0, visible.minY - glyphRect.minY))")
            }
            #expect(visible.contains(glyphRect))
            #expect(native.string == text)
        }
    }

    @Test func unchangedLongTextDoesNotRewriteAttributes() throws {
        _ = NSApplication.shared
        let text = String(repeating: "A bilingual transcript keeps every word. 双语文字完整保留。\n", count: 2_000)
        let reader = LiveTranscriptReader(text: text, followsLatest: true, label: "Controlled reader", onReview: {})
        let host = NSHostingView(rootView: reader.frame(width: 600, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findReader(host))
        let native = try #require(scroll.documentView as? NSTextView)
        reader.update(scroll)
        let edits = ReaderStorageObserver()
        native.textStorage?.delegate = edits
        let started = ContinuousClock.now
        for _ in 0..<100 { reader.update(scroll) }
        let elapsed = started.duration(to: .now)
        print("READER_PERFORMANCE characters=\(text.utf16.count) updates=100 elapsed=\(elapsed) attributeEdits=\(edits.count)")
        #expect(native.string == text)
        #expect(edits.count == 0)
    }

    @Test func changedTextFontAndFollowModePreserveReviewSelectionAndCompleteUnicode() throws {
        _ = NSApplication.shared
        let text = String(repeating: "Source 原文 👩🏽‍💻 e\u{301}\n", count: 400)
        let reader = LiveTranscriptReader(text: text, followsLatest: false, label: "Source", onReview: {})
        let host = NSHostingView(rootView: reader.frame(width: 600, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findReader(host))
        let native = try #require(scroll.documentView as? NSTextView)
        reader.update(scroll)
        native.setSelectedRange(NSRange(location: 7, length: 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let position = scroll.contentView.bounds.origin
        let appended = text + "Newest tail 尾段 👨‍👩‍👧‍👦"
        LiveTranscriptReader(text: appended, followsLatest: false, label: "Updated source", fontSize: 28, onReview: {}).update(scroll)
        #expect(native.string == appended)
        #expect(native.selectedRange() == NSRange(location: 7, length: 2))
        #expect(scroll.contentView.bounds.origin == position)
        #expect(native.font?.pointSize == 28)
        #expect(native.accessibilityLabel() == "Updated source")
        LiveTranscriptReader(text: appended, followsLatest: true, label: "Updated source", fontSize: 28, onReview: {}).update(scroll)
        #expect(scroll.contentView.bounds.origin.y > position.y)
        LiveTranscriptReader(text: "Short 新结果", followsLatest: false, label: "Source", fontSize: .nan, onReview: {}).update(scroll)
        #expect(native.string == "Short 新结果")
        #expect(native.font?.pointSize == 17)
        #expect(native.selectedRanges.allSatisfy { NSMaxRange($0.rangeValue) <= native.string.utf16.count })
        for whitespace in ["\n \t\r\n", ""] {
            LiveTranscriptReader(text: whitespace, followsLatest: true, label: "Source", fontSize: 24, onReview: {}).update(scroll)
            #expect(native.string == whitespace)
        }
    }

    @Test func incrementalLiveTextDoesNotReplaceAlreadyLaidOutHistory() throws {
        _ = NSApplication.shared
        var text = String(repeating: "Retained 原文 👩🏽‍💻 e\u{301}\n", count: 2_000)
        let host = NSHostingView(rootView: LiveTranscriptReader(text: text, followsLatest: false,
            label: "Incremental reader", fontSize: 24, onReview: {}).frame(width: 600, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findReader(host))
        let native = try #require(scroll.documentView as? NSTextView)
        native.setSelectedRange(NSRange(location: 9, length: 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let position = scroll.contentView.bounds.origin
        let edits = ReaderStorageObserver()
        native.textStorage?.delegate = edits
        for delta in ["New tail ", "中", "文 e", "\u{301}", " 👩", "🏽", "\u{200d}💻", "\n"] {
            let oldLength = text.utf16.count
            edits.characterRanges = []
            text += delta
            LiveTranscriptReader(text: text, followsLatest: false, label: "Incremental reader", fontSize: 24, onReview: {}).update(scroll)
            #expect(Array(native.string.utf16) == Array(text.utf16))
            #expect(native.selectedRange() == NSRange(location: 9, length: 2))
            #expect(scroll.contentView.bounds.origin == position)
            #expect(!edits.characterRanges.isEmpty)
            #expect(edits.characterRanges.allSatisfy { $0.location >= oldLength })
        }
        // A new history result with a different prefix must still replace all content.
        let replaced = "Different history 原文 👨‍👩‍👧‍👦"
        LiveTranscriptReader(text: replaced, followsLatest: false, label: "Incremental reader", fontSize: 24, onReview: {}).update(scroll)
        #expect(native.string == replaced)
        // Canonically equivalent text can still contain different source code units.
        for spelling in ["Caf\u{e9}", "Cafe\u{301}"] {
            LiveTranscriptReader(text: spelling, followsLatest: false, label: "Incremental reader", fontSize: 24, onReview: {}).update(scroll)
            #expect(Array(native.string.utf16) == Array(spelling.utf16))
        }
        LiveTranscriptReader(text: "", followsLatest: false, label: "Incremental reader", fontSize: 24, onReview: {}).update(scroll)
        #expect(native.string.isEmpty)
        #expect(native.selectedRanges == [NSValue(range: NSRange(location: 0, length: 0))])
    }

    private func findReader(_ view: NSView) -> LiveReaderScrollView? {
        if let reader = view as? LiveReaderScrollView { return reader }
        return view.subviews.lazy.compactMap(findReader).first
    }
}

@MainActor private final class ReaderStorageObserver: NSObject, @preconcurrency NSTextStorageDelegate {
    var count = 0
    var characterRanges: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        count += 1
        if editedMask.contains(.editedCharacters) { characterRanges.append(editedRange) }
    }
}
