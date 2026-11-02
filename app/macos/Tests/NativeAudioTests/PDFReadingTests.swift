import AppKit
import PDFKit
import CoreText
import Testing
@testable import TranslationWorkbench
@Suite(.serialized) @MainActor struct PDFReadingTests {
    @Test func nativeReaderKeepsIntermediatePaperAndTextOutsideScrollTracks() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-interior-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        var bounds = CGRect(x: 0, y: 0, width: 1800, height: 1800)
        let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(repeating: "INTERIOR TEXT ", count: 14),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))
        for y in stride(from: 30, through: 1770, by: 30) {
            context.textPosition = CGPoint(x: 20, y: y); CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        let original = try Data(contentsOf: file)
        let reader = PDFReadingController(); reader.open(file)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = reader.view
        defer { window.contentView = nil }
        for requestedStyle in [NSScroller.Style.legacy, .overlay] {
            let scroll = try #require(reader.view.documentView?.enclosingScrollView)
            // Model either native preference locally, without changing macOS settings.
            scroll.scrollerStyle = requestedStyle
            reader.fit()
            reader.view.autoScales = false; reader.view.scaleFactor = 1
            for size in [NSSize(width: 460, height: 400), NSSize(width: 700, height: 500)] {
                window.setContentSize(size); reader.view.frame.size = size
                await settle(reader.view)
                let document = try #require(scroll.documentView)
                let clipView = scroll.contentView
                let midpoint = CGPoint(x: (document.bounds.width - clipView.bounds.width) / 2,
                                       y: (document.bounds.height - clipView.bounds.height) / 2)
                clipView.scroll(to: midpoint); scroll.reflectScrolledClipView(clipView)
                await settle(reader.view)
                #expect(clipView.bounds.minX > 0 && clipView.bounds.maxX < document.bounds.maxX)
                #expect(clipView.bounds.minY > 0 && clipView.bounds.maxY < document.bounds.maxY)
                let clip = clipView.convert(clipView.bounds, to: reader.view)
                let page = try #require(reader.view.document?.page(at: 0))
                let paper = reader.view.convert(page.bounds(for: .cropBox), from: page).intersection(clip)
                let selection = try #require(page.selection(for: page.bounds(for: .cropBox)))
                let text = reader.view.convert(selection.bounds(for: page), from: page).intersection(clip)
                #expect(!paper.isEmpty && !text.isEmpty)
                for scroller in [scroll.verticalScroller, scroll.horizontalScroller] {
                    let scroller = try #require(scroller)
                    #expect(!scroller.isHidden, "Zoomed content keeps both native scroll controls available")
                    let track = scroller.convert(scroller.bounds, to: reader.view)
                    #expect(!paper.intersects(track), "Visible interior paper must not be under a native track")
                    #expect(!text.intersects(track), "Visible searchable interior text must not be under a native track")
                    print("PDF_INTERIOR requested=\(requestedStyle.rawValue) effective=\(scroll.scrollerStyle.rawValue) size=\(size) paper=\(paper) text=\(text) track=\(track)")
                }
                #expect(abs(reader.view.scaleFactor - 1) < 0.001 && !reader.view.autoScales)
                #expect(!window.isVisible && !window.isKeyWindow)
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }
    @Test(arguments: [600.0, 1800.0]) func nativePageTextStaysReachableBeyondBothScrollTracksWhileZooming(pageWidth: Double) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reading-gutter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("controlled-edge-text.pdf")
        var pageBounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth == 600 ? 250 : 900)
        let context = try #require(CGContext(file as CFURL, mediaBox: &pageBounds, nil))
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(pageBounds)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "RIGHT EDGE \(index)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.black]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: pageWidth - 2 - width, y: 125); CTLineDraw(line, context)
            let footer = CTLineCreateWithAttributedString(NSAttributedString(string: "BOTTOM EDGE \(index)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 40, y: 4); CTLineDraw(footer, context)
            context.endPDFPage()
        }
        context.closePDF()
        let original = try Data(contentsOf: file)
        let reader = PDFReadingController(); reader.open(file)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = reader.view
        defer { window.contentView = nil }
        for size in [NSSize(width: 360, height: 400), NSSize(width: 460, height: 400), NSSize(width: 900, height: 600)] {
            window.setContentSize(size); reader.view.frame.size = size
            await settle(reader.view)
            let scroll = try #require(reader.view.documentView?.enclosingScrollView)
            for style in [NSScroller.Style.legacy, .overlay] {
                scroll.scrollerStyle = style; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
                scroll.tile(); reader.fit(); await settle(reader.view)
                let fitScale = reader.view.scaleFactor
                for factor in [1.0, 1.5, 0.5] {
                    let chosenScale = min(reader.view.maxScaleFactor, max(reader.view.minScaleFactor, fitScale * factor))
                    reader.view.autoScales = false; reader.view.scaleFactor = fitScale * factor; await settle(reader.view)
                    let page = try #require(reader.view.document?.page(at: 0))
                    reader.view.go(to: page); await settle(reader.view)
                    let selection = try #require(reader.view.document?.findString("RIGHT EDGE 0", withOptions: []).first)
                    // A zoomed page can be taller than the reader; navigate to
                    // the edge text before checking its right-end reachability.
                    reader.view.go(to: selection); await settle(reader.view)
                    let document = try #require(scroll.documentView)
                    scroll.contentView.scroll(to: CGPoint(x: max(0, document.bounds.width - scroll.contentView.bounds.width), y: scroll.contentView.bounds.minY))
                    scroll.reflectScrolledClipView(scroll.contentView); await settle(reader.view)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: reader.view)
                    let vertical = try #require(scroll.verticalScroller)
                    let track = vertical.convert(vertical.bounds, to: reader.view)
                    let rightLimit = vertical.isHidden ? clip.maxX : min(clip.maxX, track.minX)
                    let text = reader.view.convert(selection.bounds(for: page), from: page)
                    let visibleText = text.intersection(clip)
                    print("PDF_NATIVE pageWidth=\(pageWidth) width=\(size.width) requested=\(style.rawValue) effective=\(scroll.scrollerStyle.rawValue) factor=\(factor) clip=\(clip) track=\(track) text=\(text)")
                    #expect(scroll.scrollerStyle == .legacy, "The reader reserves native tracks locally for either requested style")
                    let paper = reader.view.convert(page.bounds(for: .cropBox), from: page)
                    #expect(paper.maxX <= rightLimit, "The page edge clears the real native scroll track at fit and the rightmost scroll position")
                    #expect(!visibleText.isNull && clip.insetBy(dx: -1, dy: -1).contains(text) && text.maxX <= rightLimit, "The complete searchable edge text remains readable after fit/zoom/right-edge scrolling")
                    let last = try #require(reader.view.document?.page(at: 3))
                    reader.view.go(to: last); await settle(reader.view)
                    let bottomY = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
                    scroll.contentView.scroll(to: CGPoint(x: document.bounds.minX, y: bottomY))
                    scroll.reflectScrolledClipView(scroll.contentView); await settle(reader.view)
                    let bottomClip = scroll.contentView.convert(scroll.contentView.bounds, to: reader.view)
                    let footerSelection = try #require(reader.view.document?.findString("BOTTOM EDGE 3", withOptions: []).first)
                    let footer = reader.view.convert(footerSelection.bounds(for: last), from: last)
                    #expect(bottomClip.insetBy(dx: -1, dy: -1).contains(footer), "The complete searchable footer can be scrolled into view")
                    if let horizontal = scroll.horizontalScroller, !horizontal.isHidden {
                        let bottomTrack = horizontal.convert(horizontal.bounds, to: reader.view)
                        print("PDF_FOOTER pageWidth=\(pageWidth) width=\(size.width) requested=\(style.rawValue) effective=\(scroll.scrollerStyle.rawValue) factor=\(factor) text=\(footer) clip=\(bottomClip) track=\(bottomTrack)")
                        let bottomPaper = reader.view.convert(last.bounds(for: .cropBox), from: last)
                        #expect(bottomPaper.minY >= bottomTrack.maxY && footer.minY >= bottomTrack.maxY, "The final page and footer clear the real horizontal scroll track")
                    }
                    #expect(abs(reader.view.scaleFactor - chosenScale) < 0.001 && !reader.view.autoScales, "Reading edge content retains the user's chosen zoom within PDFKit's supported range")
                }
            }
            #expect(!window.isVisible && !window.isKeyWindow)
        }
        reader.nextPage(); #expect(reader.pageNumber >= 2)
        reader.previousPage(); reader.fit()
        #expect(reader.pageCount == 4 && reader.view.autoScales)
        #expect(try Data(contentsOf: file) == original)
    }
    private func settle(_ view: NSView) async {
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(25)) }
    }
    @Test func nativeReaderLoadsPagesNavigatesAndSwitchesWithoutChangingFile() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reading-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.pdf"), second = root.appendingPathComponent("second.pdf")
        let document = PDFDocument()
        for index in 0..<3 {
            let image = NSImage(size: NSSize(width: 100, height: 150), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            document.insert(try #require(PDFPage(image: image)), at: index)
        }
        try #require(document.write(to: first)); document.removePage(at: 2); try #require(document.write(to: second))
        let original = try Data(contentsOf: first), reader = PDFReadingController()
        reader.open(first); #expect(!reader.failed && reader.pageCount == 3 && reader.pageNumber == 1)
        reader.nextPage(); #expect(reader.pageNumber == 2 && reader.canGoBack)
        reader.nextPage(); #expect(reader.pageNumber == 3 && !reader.canGoForward)
        reader.previousPage(); #expect(reader.pageNumber == 2)
        let scale = reader.view.scaleFactor; reader.zoomIn(); #expect(reader.view.scaleFactor > scale)
        reader.zoomOut(); reader.fit(); #expect(reader.view.autoScales)
        reader.open(second); #expect(reader.pageCount == 2 && reader.pageNumber == 1)
        #expect(try Data(contentsOf: first) == original)
        reader.open(root.appendingPathComponent("missing.pdf")); #expect(reader.failed && reader.pageCount == 0)
    }
}
