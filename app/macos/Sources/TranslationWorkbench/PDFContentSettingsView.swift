import SwiftUI
import WorkbenchCore
private typealias ContentViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFContentSettingsView: View {
    var access: PDFSettingsAccess<PDFContentSettings>
    private var settings: PDFContentSettings { get { access.read() } nonmutating set { access.write(newValue) } }
    @ContentViewState private var expanded = true
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    init(settings: Binding<PDFContentSettings>) { access = PDFSettingsAccess(settings) }
    init(access: PDFSettingsAccess<PDFContentSettings>) { self.access = access }
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh,en) }
    var body: some View {
        DisclosureGroup(t("扫描、表格与内容处理", "Scans, tables and content"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("处理方式", "Operation"))
                CommittedPicker(title: t("处理方式", "Operation"), selection: access.binding(\.operation), options: PDFContentSettings.Operation.allCases.map { (title($0), $0) })
                if !settings.requiresService {
                    Text(t("只在本机生成 PDF，不读取服务密钥、不翻译或提取术语。结果会标明未翻译。", "Generates PDF locally without reading a service key, translating or extracting terms. The result is marked as untranslated."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.operation == .parseOnly {
                    Text(t("仅解析会跳过扫描检测、布局、图形处理和水印生成；输出采用无水印。", "Parse-only mode skips scan detection, layout, graphic processing and watermark generation. Output has no watermark.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(t("扫描检测与 OCR 兼容", "Scan detection and OCR compatibility"))
                CommittedPicker(title: t("扫描检测与 OCR 兼容", "Scan detection and OCR compatibility"), selection: access.binding(\.scanMode), options: [
                    (t("检测扫描页面（默认）", "Detect scanned pages (default)"), .detect),
                    (t("跳过扫描检测", "Skip scan detection"), .skipDetection),
                    (t("强制 OCR 兼容（实验性）", "Force OCR compatibility (experimental)"), .forceWorkaround),
                    (t("自动启用 OCR 兼容（实验性）", "Automatic OCR compatibility (experimental)"), .automaticWorkaround)
                ]).disabled(settings.operation == .parseOnly)
                Text(t("OCR 兼容处理已有文字层与扫描背景，不是图片文字识别。强制模式跳过扫描检测并关闭富文本；自动模式保留检测，发现重度扫描后采用兼容处理。纯图片仍需先取得文字层。", "OCR compatibility handles existing text layers over scanned backgrounds; it does not recognize text in images. Forced mode skips scan detection and disables rich text. Automatic mode detects heavily scanned documents before applying compatibility handling. Image-only pages still need a text layer."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(t("最短翻译文本长度", "Minimum text length"))
                    TextField("", value: access.binding(\.minimumTextLength), format: .number).frame(width: 100)
                        .accessibilityLabel(t("最短翻译文本长度", "Minimum text length"))
                }.disabled(!settings.requiresService)
                Text(t("短于此长度的文本保留原文；阈值过高可能使整个文档保持原文。", "Text below this length is kept in its original language. A high threshold may leave the entire document untranslated.")).font(.caption).foregroundStyle(.secondary)
                Toggle(t("处理图形元素（默认开启）", "Process graphic elements (default on)"), isOn: access.binding(\.processGraphicElements)).disabled(settings.operation == .parseOnly)
                Text(t("锁定版使用托管布局模型处理可提取的表格文字。锁定引擎未提供有效的独立表格识别模块；复杂表格结构可能改变。", "The pinned version uses its managed layout model for extractable table text. The pinned engine has no working dedicated table-recognition module. Complex table structure may change."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if settings.minimumTextLength < 0 { Text(PDFContentSettingsError.invalidMinimumLength.description(language)).foregroundStyle(.red) }
            }.padding(.top, 10)
        }
    }
    private func title(_ operation: PDFContentSettings.Operation) -> String {
        var value = settings; value.operation = operation; return value.operationTitle(language)
    }
}
