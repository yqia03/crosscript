import AppKit
import PDFKit
import Testing
@testable import TranslationWorkbench
@Suite(.serialized) @MainActor struct PDFReadingTests {
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
