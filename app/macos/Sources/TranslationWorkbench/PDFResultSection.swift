import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFResultSection: View {
    @ObservedObject var session: PDFTranslationSession
    @ObservedObject var outputSelection: PDFOutputSelection
    let commands: MenuCommandBarrier
    let resources: TranslationResourceLibrary?
    @Binding var resourceError: String?
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        if let material = session.selectedMaterial { reading(material) }
    }
    @ViewState private var availableWidth: CGFloat = 900
    private func reading(_ material: PDFMaterial) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let layout = availableWidth >= 760 ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            layout {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        selectors(material).frame(width: 160, alignment: .leading)
                        HStack(spacing: 6) { resultActions }.frame(maxWidth: .infinity, alignment: .trailing)
                    }.frame(minWidth: 324)
                    VStack(alignment: .leading, spacing: 10) {
                        selectors(material).frame(width: 160, alignment: .leading)
                        HStack(spacing: 6) { resultActions }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(HistoryGeometryObservation(name: "pdf.result.actions"))
                if let result = material.selectedResult {
                    ScrollView {
                        resultDetails(result).frame(maxWidth: .infinity, alignment: .leading).modifier(HistoryGeometryObservation(name: "pdf.details.contents")).historyScrollGutter()
                    }.frame(maxWidth: .infinity).frame(height: 165)
                        .modifier(HistoryGeometryObservation(name: "pdf.details.viewport"))
                        .accessibilityLabel(t("PDF 结果详情", "PDF result details"))
                } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1).accessibilityHidden(true)
                }
            }
            if let url = outputSelection.pdf(in: session)?.url { PDFReadingView(url: url) }
            HStack { Spacer(); deleteButtons(material) }.font(.caption)
            if session.deletionError != nil, session.deletionConfirmation == nil {
                Text(t("先完成或取消此资料的任务，并保存所有结果，再删除。", "Finish or cancel this material's tasks and save all results before deleting.")).font(.callout).foregroundStyle(.red)
            }
        }.padding(18).glassCard().modifier(HistoryGeometryObservation(name: "pdf.result.card"))
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in availableWidth = width }
            })
    }
    private func selectors(_ material: PDFMaterial) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("版本", "Version")).font(.caption)
            CommittedPicker(title: t("版本", "Version"), selection: Binding(get: { session.selectedMaterial?.selectedResultID }, set: { if let id = session.selectedID { _ = session.selectResult(materialID: id, resultID: $0) } }),
                options: [(t("原始 PDF", "Original PDF"), UUID?.none)] + Array(material.results.enumerated()).map { index, result in
                    (t("结果 \(index + 1)", "Result \(index + 1)") + " · " + (result.provider?.name ?? t("本地处理", "Local processing")), Optional(result.id))
                })
            if let result = material.selectedResult {
                Text(t("输出", "Output")).font(.caption)
                CommittedPicker(title: t("输出", "Output"), selection: Binding(get: {
                    guard let current = session.selectedMaterial?.selectedResult else { return outputSelection.kind }
                    return current.outputs.contains { $0.kind == outputSelection.kind && $0.kind.isPDF } ? outputSelection.kind : (current.outputs.first(where: { $0.kind.isPDF })?.kind ?? .dual)
                }, set: { outputSelection.kind = $0 }), options: result.outputs.filter { $0.kind.isPDF }.map { (outputTitle($0.kind, localOnly: !result.options.requiresService), $0.kind) })

            }
        }
    }
    private func resultDetails(_ result: PDFTranslationResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
                Text("BabelDOC \(result.engineVersion) · " + (result.provider?.model ?? t("本地处理 · 未翻译", "Local processing · Untranslated"))).font(.caption).foregroundStyle(.secondary)
                Text(result.options.content.summary(language)).font(.caption)
                if result.options.requiresService, let report = result.contentReport, report.pagesWithoutExtractableText > 0 {
                    Text(t("所选页中有 \(report.pagesWithoutExtractableText) 页没有可提取文字，图片中的内容未翻译。", "\(report.pagesWithoutExtractableText) selected pages have no extractable text; text in their images was not translated.")).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(result.options.effectiveOutput.summary(language, localOnly: !result.options.requiresService)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(t("字体与版式快照", "Font and layout snapshot")) {
                    Text(result.options.layout.snapshotLines(language).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    if result.options.content.scanMode == .forceWorkaround || result.options.content.scanMode == .automaticWorkaround {
                        Text(t("OCR 兼容启用时会关闭富文本与非公式线条移除。", "When OCR compatibility is active, rich text and non-formula line removal are disabled.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("pdf-details-layout")
                DisclosureGroup(t("运行诊断与速度快照", "Run diagnostics and speed snapshot")) {
                    Text(result.options.performance.snapshotLines(language).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    if let diagnostics = result.diagnostics {
                        Text(diagnostics.summary(language)).font(.caption).textSelection(.enabled)
                    } else { Text(t("此历史结果没有诊断计数。", "This historical result has no diagnostic counts.")).font(.caption) }
                    Text(t("Token 仅累计供应商实际报告的响应；缺失部分不估算。", "Token sums cover only responses with reported usage; missing values are not estimated.")).font(.caption).foregroundStyle(.secondary)
                    Button(t("复制诊断摘要", "Copy diagnostic summary")) { commands.perform {
                        guard let current = session.selectedMaterial?.selectedResult else { return }
                        let summary = "BabelDOC \(current.engineVersion) · Integration \(current.integrationVersion)\n" + current.options.performance.summary(language) + "\n" + (current.diagnostics?.summary(language) ?? t("计数未知", "Counts unknown"))
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary, forType: .string)
                    } }
                }.accessibilityIdentifier("pdf-details-diagnostics")
                if result.options.requiresService { TranslationResourceSnapshotView(snapshot: result.options.resources)
                Text(result.options.autoExtractGlossary ? t("此结果启用了自动术语提取", "Automatic term extraction was enabled") : t("此结果直接使用选定术语", "Selected terms were used directly")).font(.caption).foregroundStyle(.secondary)
                if let extraction = result.options.termExtractionProvider { Text(t("提取服务：", "Extraction service: ") + extraction.name + " · " + extraction.model).font(.caption) }
                }

        }
    }
    @ViewBuilder private var resultActions: some View {
        action(id: "pdf-export-terms", icon: "square.and.arrow.up", label: t("导出提取术语 CSV", "Export extracted terms CSV"), enabled: outputSelection.glossary(in: session) != nil) { exportGlossary() }
        action(id: "pdf-add-terms", icon: "books.vertical", label: t("加入共用术语库", "Add to shared glossary library"), enabled: resources != nil && outputSelection.glossary(in: session) != nil) { addGlossary() }
        action(id: "pdf-open-preview", icon: "macwindow", label: t("用预览打开", "Open in Preview"), enabled: outputSelection.pdf(in: session) != nil) {
            if let selected = outputSelection.pdf(in: session) { NSWorkspace.shared.open(selected.url) }
        }
        action(id: "pdf-save-result", icon: "arrow.down.document", label: t("另存 PDF", "Save PDF as"), enabled: outputSelection.pdf(in: session) != nil) { savePDF() }
    }
    private func action(id: String, icon: String, label: String, enabled: Bool, run: @escaping @MainActor () -> Void) -> some View {
        Button { commands.perform(run) } label: {
            Image(systemName: icon)
        }.buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true)).disabled(!enabled).help(label).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private func exportGlossary() {
        guard let selected = outputSelection.glossary(in: session) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = selected.suggestedFilename
        // Keep the chosen output stable while a background completion runs.
        if panel.runModal() == .OK, let destination = panel.url { _ = session.export(selected.url, to: destination) }
    }
    private func addGlossary() {
        guard let resources, let selected = outputSelection.glossary(in: session) else { return }
        do {
            let text = try String(contentsOf: selected.url, encoding: .utf8)
            let glossary = try TranslationGlossary.importCSV(text, name: String((selected.materialName + t(" · 提取术语", " · Extracted terms")).prefix(120)))
            guard resources.saveGlossary(glossary) else { throw TranslationResourceError.storage }
            resourceError = nil
        } catch { resourceError = t("未能加入术语库，原始 CSV 与 PDF 结果仍保留。请检查设置页的库状态。", "Could not add terms to the library. The CSV and PDF result are retained. Check the library in Settings.") }
    }
    private func savePDF() {
        guard let selected = outputSelection.pdf(in: session) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = selected.suggestedFilename
        if panel.runModal() == .OK, let destination = panel.url { _ = session.export(selected.url, to: destination) }
    }
    private func deleteButtons(_ material: PDFMaterial) -> some View {
        HStack {
            if material.selectedResult != nil { Button(t("删除此结果", "Delete this result"), role: .destructive) { commands.perform { if let current = session.selectedMaterial, let result = current.selectedResult { _ = session.requestDeletion(.result(current.id, result.id)) } } } }
            Button(t("删除整份资料", "Delete material"), role: .destructive) { commands.perform { if let current = session.selectedMaterial { _ = session.requestDeletion(.material(current.id)) } } }
        }
    }
    private func outputTitle(_ kind: PDFOutputKind, localOnly: Bool = false) -> String {
        if localOnly { return (kind == .mono || kind == .monoNoWatermark ? t("单栏 PDF（未翻译）", "Single PDF (untranslated)") : t("对照 PDF（未翻译）", "Comparison PDF (untranslated)")) + ((kind == .monoNoWatermark || kind == .dualNoWatermark) ? t(" · 无水印", " · No watermark") : "") }
        switch kind {
        case .glossaryCSV: return t("提取术语 CSV", "Extracted terms CSV")
        case .mono: return t("译文 PDF", "Translated PDF")
        case .dual: return t("双语 PDF", "Bilingual PDF")
        case .monoNoWatermark: return t("译文 PDF（无水印）", "Translated PDF (no watermark)")
        case .dualNoWatermark: return t("双语 PDF（无水印）", "Bilingual PDF (no watermark)")
        }
    }

}
