import SwiftUI
import WorkbenchCore
private typealias OutputViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFOutputSettingsView: View {
    var access: PDFSettingsAccess<PDFOutputSettings>
    private var settings: PDFOutputSettings { get { access.read() } nonmutating set { access.write(newValue) } }
    var pageCount: Int?
    var operation: PDFContentSettings.Operation = .translate
    var translatedFirstRequired = false
    private var localOnly: Bool { operation != .translate }
    @OutputViewState private var expanded = true
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    init(settings: Binding<PDFOutputSettings>, pageCount: Int?, operation: PDFContentSettings.Operation = .translate, translatedFirstRequired: Bool = false) {
        self.init(access: PDFSettingsAccess(settings), pageCount: pageCount, operation: operation, translatedFirstRequired: translatedFirstRequired)
    }
    init(access: PDFSettingsAccess<PDFOutputSettings>, pageCount: Int?, operation: PDFContentSettings.Operation = .translate, translatedFirstRequired: Bool = false) {
        self.access = access; self.pageCount = pageCount; self.operation = operation; self.translatedFirstRequired = translatedFirstRequired
    }
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh,en) }
    var body: some View {
        DisclosureGroup(t("页范围与输出", "Pages and output"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localOnly ? t("处理页范围", "Pages to process") : t("翻译页范围", "Pages to translate")).font(.callout)
                TextField(t("页范围（空白为全部，例如 1-3,5）", "Pages (empty means all, e.g. 1-3,5)"), text: access.binding(\.pages))
                if let pageCount { Text(t("原始 PDF 共 \(pageCount) 页", "Source PDF: \(pageCount) pages")).font(.caption).foregroundStyle(.secondary) }
                Toggle(t("仅输出所选页", "Include only selected pages"), isOn: access.binding(\.onlyIncludeTranslatedPages))
                Toggle(t("按页数分部处理，完成后合并", "Process in parts and merge the result"), isOn: Binding(get: { settings.maximumPagesPerPart != nil }, set: { settings.maximumPagesPerPart = $0 ? 50 : nil }))
                if settings.maximumPagesPerPart != nil {
                    HStack {
                        Text(t("每部分最多页数", "Maximum pages per part"))
                        TextField("", value: Binding(get: { settings.maximumPagesPerPart ?? 50 }, set: { settings.maximumPagesPerPart = $0 }), format: .number)
                            .frame(width: 100).accessibilityLabel(t("每部分最多页数", "Maximum pages per part"))
                    }
                }
                Text(t("输出文件", "Output files"))
                CommittedPicker(title: t("输出文件", "Output files"), selection: access.binding(\.mode), options: [
                    (localOnly ? t("对照 PDF（未翻译）", "Comparison PDF (untranslated)") : t("双语 PDF", "Bilingual PDF"), .bilingual),
                    (localOnly ? t("单栏 PDF（未翻译）", "Single PDF (untranslated)") : t("译文 PDF", "Translated PDF"), .translated),
                    (localOnly ? t("单栏与对照 PDF（未翻译）", "Single and comparison PDFs (untranslated)") : t("译文与双语 PDF（默认）", "Translated and bilingual (default)"), .both)
                ])
                Text(localOnly ? t("对照布局", "Comparison layout") : t("双语布局", "Bilingual layout"))
                CommittedPicker(title: localOnly ? t("对照布局", "Comparison layout") : t("双语布局", "Bilingual layout"), selection: access.binding(\.layout), options: [
                    (t("并排", "Side by side"), .sideBySide), (t("交替页", "Alternating pages"), .alternatingPages)
                ]).disabled(settings.mode == .translated)
                Toggle(localOnly ? t("对照输出中处理页在前", "Processed page first in comparison output") : t("双语输出中译文在前", "Translation first in bilingual output"), isOn: Binding(get: { settings.translatedFirst || translatedFirstRequired }, set: { settings.translatedFirst = $0 })).disabled(settings.mode == .translated || translatedFirstRequired)
                Text(t("引擎水印", "Engine watermark"))
                CommittedPicker(title: t("引擎水印", "Engine watermark"), selection: access.binding(\.watermark), options: [
                    (t("带水印（默认）", "Watermarked (default)"), .watermarked), (t("无水印", "No watermark"), .noWatermark), (t("两种版本", "Both versions"), .both)
                ]).disabled(operation == .parseOnly)
                Text(t("未选中的页面默认保留原文。分部会逐部分处理并合并最终 PDF，不产生额外后台任务名额。", "Unselected pages keep their original content by default. Parts are processed sequentially and merged into the final PDF within one background task."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = validationError { Text(error.description(language)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(.top, 10)
        }
    }
    private var validationError: PDFOutputSettingsError? {
        do { try settings.validate(pageCount: pageCount); return nil } catch { return error as? PDFOutputSettingsError }
    }
}
