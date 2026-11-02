import SwiftUI
import WorkbenchCore
private typealias LayoutViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFLayoutSettingsView: View {
    var access: PDFSettingsAccess<PDFLayoutSettings>
    private var settings: PDFLayoutSettings { get { access.read() } nonmutating set { access.write(newValue) } }
    var content: PDFContentSettings
    @LayoutViewState private var expanded = false
    @AppStorage("interfaceLanguage") private var preference = "system"
    init(settings: Binding<PDFLayoutSettings>, content: PDFContentSettings, initiallyExpanded: Bool = false) {
        self.init(access: PDFSettingsAccess(settings), content: content, initiallyExpanded: initiallyExpanded)
    }
    init(access: PDFSettingsAccess<PDFLayoutSettings>, content: PDFContentSettings, initiallyExpanded: Bool = false) {
        self.access = access; self.content = content; self._expanded = LayoutViewState(initialValue: initiallyExpanded)
    }
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        DisclosureGroup(t("字体、公式与版式（高级）", "Fonts, formulas and layout (advanced)"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if content.operation == .parseOnly {
                    Text(t("仅解析跳过字体映射、公式和排版处理；以下相关选项不生效。表单与曲线绘制仍用于生成 PDF。", "Parse-only mode skips font mapping, formulas and typesetting; those settings have no effect. Form and curve rendering still apply when generating PDF.")).font(.caption).foregroundStyle(.secondary)
                }
                fontAndFormulaControls.disabled(content.operation == .parseOnly)
                layoutControls.disabled(content.operation == .parseOnly)
                Toggle(t("绘制表单对象（默认开启）", "Render form objects (default on)"), isOn: access.binding(\.renderForms))
                Toggle(t("绘制曲线（默认开启）", "Render curves (default on)"), isOn: access.binding(\.renderCurves))
                Text(t("关闭绘制可能移除文档中的图形、表格线或复用对象。对兼容性问题可比较输出，已有结果始终保留。", "Disabling rendering can remove graphics, table rules or reused objects. Compare outputs for compatibility issues; existing results remain.")).font(.caption).foregroundStyle(.secondary)
                if let error = validationError { Text(error.description(language)).foregroundStyle(.red) }
            }.padding(.top, 10)
        }.accessibilityIdentifier("pdf-settings-layout")
    }
    private var fontAndFormulaControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("译文字体族", "Translated font family"))
            CommittedPicker(title: t("译文字体族", "Translated font family"), selection: access.binding(\.fontFamily), options: PDFLayoutSettings.FontFamily.allCases.map { (fontTitle($0), $0) })
            Text(t("默认匹配源字体。衬线、无衬线与手写字体均使用 App 托管资源，无需自行安装；字体许可见组件说明。", "Default matches the source. Serif, sans-serif and script fonts use App-managed resources without manual installation; see component notices for licenses.")).font(.caption).foregroundStyle(.secondary)
            Text(t("公式字体规则（Python 正则，空白为默认）", "Formula font pattern (Python regex; empty uses default)"))
            TextField(t("例如 .*Math.*", "Example: .*Math.*"), text: access.binding(\.formulaFontPattern)).textFieldStyle(.roundedBorder)
            Text(t("公式字符规则（Python 正则，空白为默认）", "Formula character pattern (Python regex; empty uses default)"))
            TextField(t("例如 [α-ω]", "Example: [α-ω]"), text: access.binding(\.formulaCharacterPattern)).textFieldStyle(.roundedBorder)
            Text(t("字体规则替换引擎的宽泛匹配，字符规则补充默认公式识别。过宽规则会让普通文字保持原文；公式识别不保证所有排版都准确。", "The font pattern replaces the broad font match; the character pattern supplements built-in formula detection. Broad patterns may leave ordinary text untranslated. Formula detection cannot guarantee every layout.")).font(.caption).foregroundStyle(.secondary)
            Toggle(t("公式占位提示（实验性，默认关闭）", "Formula placeholder hints (experimental; default off)"), isOn: access.binding(\.formulaPlaceholderHint))
            Toggle(t("计算公式偏移（默认开启）", "Calculate formula offsets (default on)"), isOn: access.binding(\.calculateFormulaOffsets))
        }
    }
    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(t("增强兼容（默认关闭）", "Enhanced compatibility (default off)"), isOn: access.binding(\.enhanceCompatibility))
            Text(t("增强兼容会跳过 PDF 清理、关闭富文本，并将对照输出的处理页放在前面。强制 OCR 兼容也会关闭富文本与非公式线条移除；自动 OCR 启用后可能采用相同限制。", "Enhanced compatibility skips PDF cleaning, disables rich text and puts the processed page first in comparison output. Forced OCR compatibility also disables rich text and non-formula line removal; automatic OCR may apply those restrictions.")).font(.caption).foregroundStyle(.secondary)
            Toggle(t("跳过 PDF 清理（默认关闭）", "Skip PDF cleaning (default off)"), isOn: Binding(get: { settings.skipCleaning || settings.enhanceCompatibility }, set: { settings.skipCleaning = $0 })).disabled(settings.enhanceCompatibility)
            Toggle(t("富文本翻译（默认开启）", "Rich-text translation (default on)"), isOn: Binding(get: { settings.richText && !settings.enhanceCompatibility && content.scanMode != .forceWorkaround }, set: { settings.richText = $0 })).disabled(settings.enhanceCompatibility || content.scanMode == .forceWorkaround)
            Toggle(t("拆分短行（实验性，默认关闭）", "Split short lines (experimental; default off)"), isOn: access.binding(\.splitShortLines))
            number(t("短行宽度系数（默认 0.8）", "Short-line width factor (default 0.8)"), value: access.binding(\.shortLineSplitFactor)).disabled(!settings.splitShortLines)
            Toggle(t("合并交错行号（默认开启）", "Merge alternating line numbers (default on)"), isOn: access.binding(\.mergeAlternatingLineNumbers))
            Toggle(t("移除非公式线条（默认关闭）", "Remove non-formula lines (default off)"), isOn: Binding(get: { settings.removeNonFormulaLines && content.scanMode != .forceWorkaround }, set: { settings.removeNonFormulaLines = $0 })).disabled(content.scanMode == .forceWorkaround)
            number(t("线条重叠阈值（0–1，默认 0.9）", "Line overlap threshold (0–1; default 0.9)"), value: access.binding(\.nonFormulaLineOverlapThreshold)).disabled(!settings.removeNonFormulaLines || content.scanMode == .forceWorkaround)
            number(t("图表保护阈值（0–1，默认 0.9）", "Figure/table protection threshold (0–1; default 0.9)"), value: access.binding(\.figureTableProtectionThreshold)).disabled(!settings.removeNonFormulaLines || content.scanMode == .forceWorkaround)
        }
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title); TextField("", value: value, format: .number).frame(width: 120).accessibilityLabel(title) }
    }
    private func fontTitle(_ family: PDFLayoutSettings.FontFamily) -> String { var value = settings; value.fontFamily = family; return value.fontTitle(language) }
    private var validationError: PDFLayoutSettingsError? { do { try settings.validate(); return nil } catch { return error as? PDFLayoutSettingsError } }
}
