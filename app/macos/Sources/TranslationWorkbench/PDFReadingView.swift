import AppKit
import PDFKit
import SwiftUI
import WorkbenchCore

@MainActor final class PDFReadingCanvas: PDFView {
    override func layout() {
        super.layout()
        reserveScrollTrackSpace()
    }

    func reserveScrollTrackSpace() {
        guard let scroll = documentView?.enclosingScrollView,
              scroll.scrollerStyle != .legacy else { return }
        // A local native reserved-track style keeps paper and text clear even
        // while panning through a zoomed page. Overlay tracks share viewport
        // pixels with the document; page-end margins cannot protect its interior.
        // This does not change the user's system-wide scrollbar preference.
        scroll.scrollerStyle = .legacy
        scroll.tile()
    }
}

@MainActor final class PDFReadingController: ObservableObject {
    let view = PDFReadingCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    @Published private(set) var pageNumber = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failed = false
    private var observations: [NSObjectProtocol] = []
    init() {
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }
    deinit { for token in observations { NotificationCenter.default.removeObserver(token) } }
    func open(_ url: URL) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url); view.reserveScrollTrackSpace(); view.autoScales = true
        failed = view.document == nil || view.document?.isLocked == true
        if let first = view.document?.page(at: 0) { view.go(to: first) }
        refresh()
    }
    func previousPage() { view.goToPreviousPage(nil); refresh() }
    func nextPage() { view.goToNextPage(nil); refresh() }
    func zoomIn() { view.zoomIn(nil) }
    func zoomOut() { view.zoomOut(nil) }
    func fit() { view.reserveScrollTrackSpace(); view.autoScales = true }
    private func refresh() {
        pageCount = view.document?.pageCount ?? 0
        pageNumber = view.currentPage.flatMap { view.document?.index(for: $0) }.map { $0 + 1 } ?? 0
        canGoBack = view.canGoToPreviousPage; canGoForward = view.canGoToNextPage
    }
}
@MainActor struct PDFReadingView: View {
    let url: URL
    @StateObject private var reader = PDFReadingController()
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh,en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reader.failed { Text(t("此 PDF 暂时无法打开，已有文件仍保留。", "This PDF cannot be opened. Existing files are retained.")).foregroundStyle(.red) }
            NativePDFReadingView(reader: reader).frame(minHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .modifier(HistoryGeometryObservation(name: "pdf.reader.canvas"))
            ViewThatFits(in: .horizontal) {
                ZStack {
                    pageControls
                    HStack { Spacer(); zoomControls }
                }.frame(minWidth: 540)
                VStack(spacing: 8) { pageControls; zoomControls }.frame(maxWidth: .infinity)
            }.buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true))
                .modifier(HistoryGeometryObservation(name: "pdf.reader.toolbar"))
        }.onAppear { reader.open(url) }.onChange(of: url) { _, newValue in reader.open(newValue) }
    }
    private var pageControls: some View {
        HStack {
            Button { reader.previousPage() } label: { Image(systemName: "chevron.left") }.disabled(!reader.canGoBack)
                .accessibilityLabel(t("上一页", "Previous page")).help(t("上一页", "Previous page")).accessibilityIdentifier("pdf-reader-previous")
            Text("\(reader.pageNumber) / \(reader.pageCount)").monospacedDigit().font(.caption).frame(minWidth: 52)
            Button { reader.nextPage() } label: { Image(systemName: "chevron.right") }.disabled(!reader.canGoForward)
                .accessibilityLabel(t("下一页", "Next page")).help(t("下一页", "Next page")).accessibilityIdentifier("pdf-reader-next")
        }.modifier(HistoryGeometryObservation(name: "pdf.reader.pages"))
    }
    private var zoomControls: some View {
        HStack {
            Button { reader.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel(t("缩小", "Zoom out")).accessibilityIdentifier("pdf-reader-zoom-out")
            Button { reader.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel(t("放大", "Zoom in")).accessibilityIdentifier("pdf-reader-zoom-in")
            Button(t("适应窗口", "Fit to window")) { reader.fit() }.accessibilityIdentifier("pdf-reader-fit")
        }.modifier(HistoryGeometryObservation(name: "pdf.reader.zoom"))
    }
}
@MainActor private struct NativePDFReadingView: NSViewRepresentable {
    let reader: PDFReadingController
    func makeNSView(context: Context) -> PDFView { reader.view }
    func updateNSView(_ view: PDFView, context: Context) {}
}
