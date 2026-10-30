import AppKit
import SwiftUI

@MainActor struct LiveTranscriptReader: NSViewRepresentable {
    let text: String
    let followsLatest: Bool
    let label: String
    var fontSize: Double = 17
    let onReview: () -> Void
    func makeNSView(context: Context) -> LiveReaderScrollView {
        let scroll = LiveReaderScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false; scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        let scroller = LiveReaderScroller()
        scroller.onReview = { [weak scroll] in scroll?.onReview?() }
        scroll.verticalScroller = scroller
        let view = LiveReaderTextView()
        view.onReview = { [weak scroll] in scroll?.onReview?() }
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.font = .systemFont(ofSize: 17)
        view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: LiveReaderScrollView, context: Context) {
        update(scroll)
    }
    func update(_ scroll: LiveReaderScrollView) {
        scroll.onReview = onReview
        guard let view = scroll.documentView as? NSTextView else { return }
        if scroll.renderedLabel != label { view.setAccessibilityLabel(label); scroll.renderedLabel = label }
        let size = min(48, max(14, fontSize.isFinite ? fontSize : 17))
        let textChanged = scroll.renderedText.map {
            ($0 as NSString).compare(text, options: .literal) != .orderedSame
        } ?? true
        let fontChanged = scroll.renderedFontSize != size
        let viewportChanged = scroll.renderedViewportSize != scroll.contentView.bounds.size
        let followingChanged = scroll.renderedFollowsLatest != followsLatest
        // Recording clocks and cloud status invalidate both readers frequently.
        // Keep TextKit's layout and native selection untouched for those updates.
        guard textChanged || fontChanged || viewportChanged || followingChanged else { return }
        let position = scroll.contentView.bounds.origin
        let selections = view.selectedRanges
        if fontChanged { view.font = .systemFont(ofSize: size) }
        if textChanged {
            let next = text as NSString
            if let rendered = scroll.renderedText, let storage = view.textStorage {
                let previousLength = (rendered as NSString).length
                // Streaming deltas normally append. Preserve the existing TextKit
                // layout instead of replacing the complete transcript each time.
                // Literal UTF-16 comparison also handles a delta that continues a
                // combining character or an emoji sequence across chunk boundaries.
                if next.length >= previousLength,
                   next.compare(rendered, options: .literal,
                                range: NSRange(location: 0, length: previousLength)) == .orderedSame {
                    storage.replaceCharacters(in: NSRange(location: previousLength, length: 0),
                                              with: next.substring(from: previousLength))
                } else {
                    view.string = text
                }
            } else {
                view.string = text
            }
        }
        if followsLatest { view.scrollRangeToVisible(latestBodyRange(in: text)) }
        else {
            let length = text.utf16.count
            let retained = selections.map { selection in
                let range = selection.rangeValue, start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
            // A shorter history result still needs a caret; AppKit rejects an
            // empty selection array when every old range was beyond the end.
            view.selectedRanges = retained.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : retained
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scroll.renderedText = text; scroll.renderedFontSize = size
        scroll.renderedFollowsLatest = followsLatest
        scroll.renderedViewportSize = scroll.contentView.bounds.size
    }
    private func latestBodyRange(in text: String) -> NSRange {
        let utf16Count = text.utf16.count
        // Follow the last body glyph, not a trailing empty paragraph. At small
        // caption heights an end-of-string caret can push that glyph offscreen.
        // Search backward without trimming the saved/displayed text; preserve
        // whole composed characters when converting the target to AppKit UTF-16.
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else {
            return NSRange(location: utf16Count, length: 0)
        }
        return NSRange(location: utf16Count - text[last...].utf16.count,
                       length: text[last..<text.index(after: last)].utf16.count)
    }
}
@MainActor final class LiveReaderScrollView: NSScrollView {
    var onReview: (() -> Void)?
    fileprivate var renderedText: String?
    fileprivate var renderedFontSize: Double?
    fileprivate var renderedLabel: String?
    fileprivate var renderedFollowsLatest: Bool?
    fileprivate var renderedViewportSize: NSSize?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { onReview?() }
        super.scrollWheel(with: event)
    }
}

@MainActor private final class LiveReaderScroller: NSScroller {
    var onReview: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onReview?()
        super.mouseDown(with: event)
    }
}
@MainActor private final class LiveReaderTextView: NSTextView {
    var onReview: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onReview?()
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if [115, 116, 121, 123, 124, 125, 126].contains(event.keyCode) { onReview?() }
        super.keyDown(with: event)
    }
}
