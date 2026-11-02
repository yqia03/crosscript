import SwiftUI
import WorkbenchCore
private typealias PerformanceViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFPerformanceSettingsView: View {
    var access: PDFSettingsAccess<PDFPerformanceSettings>
    private var settings: PDFPerformanceSettings { get { access.read() } nonmutating set { access.write(newValue) } }
    var requiresService: Bool
    var extractsTerms: Bool
    @PerformanceViewState private var expanded = false
    @AppStorage("interfaceLanguage") private var preference = "system"
    init(settings: Binding<PDFPerformanceSettings>, requiresService: Bool, extractsTerms: Bool, initiallyExpanded: Bool = false) {
        self.init(access: PDFSettingsAccess(settings), requiresService: requiresService, extractsTerms: extractsTerms, initiallyExpanded: initiallyExpanded)
    }
    init(access: PDFSettingsAccess<PDFPerformanceSettings>, requiresService: Bool, extractsTerms: Bool, initiallyExpanded: Bool = false) {
        self.access = access; self.requiresService = requiresService; self.extractsTerms = extractsTerms
        _expanded = PerformanceViewState(initialValue: initiallyExpanded)
    }
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        DisclosureGroup(t("速度、缓存与诊断（高级）", "Speed, cache and diagnostics (advanced)"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("一个 PDF 仍只占一个 App 后台名额。以下并发用于该引擎任务内部；翻译与术语请求共用每秒上限，无法绕过服务限额。", "One PDF still occupies one App background slot. These worker limits apply inside that job. Translation and term requests share the QPS limit and remain subject to service quotas.")).font(.caption).foregroundStyle(.secondary)
                if !requiresService { Text(t("本地生成不调用服务，速度与缓存请求设置不生效。", "Local generation makes no service calls; request and translation-cache settings have no effect.")).font(.caption) }
                serviceControls.disabled(!requiresService)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("进度刷新间隔（秒，默认 0.1；0.05–60）", "Progress interval (seconds; default 0.1; 0.05–60)"))
                    TextField("", value: access.binding(\.progressInterval), format: .number).frame(width: 100).accessibilityLabel(t("进度间隔", "Progress interval"))
                }
                Toggle(t("诊断 PDF（默认关闭）", "Diagnostic PDF (default off)"), isOn: access.binding(\.diagnosticPDF))
                Toggle(t("显示字符框（仅诊断 PDF）", "Show character boxes (diagnostic PDF only)"), isOn: access.binding(\.characterBoxes)).disabled(!settings.diagnosticPDF)
                Text(t("诊断 PDF 会在结果中增加布局标记。工作文件含文档内容，仅保留在本机任务暂存区；诊断摘要只包含设置、版本与计数，不包含密钥、原文或服务响应。", "Diagnostic PDFs add layout marks to the result. Working files contain document content and stay in local task staging. Diagnostic summaries include settings, versions and counts, without keys, source text or service responses.")).font(.caption).foregroundStyle(.secondary)
                if let error = validationError { Text(error.description(language)).foregroundStyle(.red) }
            }.padding(.top, 10)
        }.accessibilityIdentifier("pdf-settings-performance")
    }
    private var serviceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            number(t("每秒请求上限（QPS，默认 4；1–100）", "Requests per second (QPS; default 4; 1–100)"), value: access.binding(\.requestsPerSecond))
            Toggle(t("翻译并发跟随 QPS（默认）", "Translation workers follow QPS (default)"), isOn: automatic(access.binding(\.translationWorkers), fallback: settings.requestsPerSecond))
            if settings.translationWorkers != nil { number(t("翻译工作线程（1–100）", "Translation workers (1–100)"), value: count(access.binding(\.translationWorkers), fallback: settings.requestsPerSecond)) }
            Toggle(t("术语并发跟随翻译并发（默认）", "Term workers follow translation workers (default)"), isOn: automatic(access.binding(\.termWorkers), fallback: settings.effectiveTranslationWorkers)).disabled(!extractsTerms)
            if settings.termWorkers != nil { number(t("术语提取工作线程（1–100）", "Term-extraction workers (1–100)"), value: count(access.binding(\.termWorkers), fallback: settings.effectiveTranslationWorkers)).disabled(!extractsTerms) }
            Text(t("当前有效并发：翻译 \(settings.effectiveTranslationWorkers)，术语 \(settings.effectiveTermWorkers)。术语限制仅在自动提取开启时使用。App 将数值限制为 1–100 以控制资源；上游没有统一的服务能力保证。", "Effective workers: translation \(settings.effectiveTranslationWorkers), terms \(settings.effectiveTermWorkers). Term limits apply only during automatic extraction. App values are bounded to 1–100 for resource control; upstream makes no universal service-capacity guarantee.")).font(.caption).foregroundStyle(.secondary)
            Toggle(t("绕过翻译缓存读写（默认关闭）", "Bypass translation cache reads and writes (default off)"), isOn: access.binding(\.ignoreCache))
            Text(t("默认在本机复用相同服务目标、模型、语言、提示与文本的缓存。绕过时会重新请求，也不会写入本次响应；独立结果和用户修改不会被覆盖。", "By default, local cache reuses matching service target, model, language, prompt and text. Bypassing makes new requests and does not write their responses. Independent results and user edits remain unchanged.")).font(.caption).foregroundStyle(.secondary)
            Toggle(t("相同原文回退重试（默认开启）", "Retry same-text translation fallback (default on)"), isOn: access.binding(\.sameTextFallback))
            Text(t("译文与原文相同时，上游可能用不同方式再请求。关闭可减少请求，但可能保留未翻译文字；限流和服务失败不会无限重试。", "When translation equals the source, the engine may request another method. Disabling fallback can reduce requests but leave text untranslated. Rate limits and service failures do not trigger unlimited retries.")).font(.caption).foregroundStyle(.secondary)
            Toggle(t("引擎请求时启用 JSON 模式（默认关闭）", "Enable JSON mode when requested by engine (default off)"), isOn: access.binding(\.jsonModeWhenRequested))
            Toggle(t("发送温度参数（默认开启，值为 0）", "Send temperature (default on; value 0)"), isOn: access.binding(\.sendTemperature))
            Toggle(t("发送 DashScope 内容检查头（默认关闭）", "Send DashScope data-inspection header (default off)"), isOn: access.binding(\.dashScopeHeader))
            Text(t("仅在所选服务明确支持时启用兼容选项。DashScope 头请求关闭其输入和输出内容检查；本 App 不自动判断或切换服务。", "Enable compatibility options only when the selected service supports them. The DashScope header requests disabled input/output inspection. The App does not detect or switch services automatically.")).font(.caption).foregroundStyle(.secondary)
            Text(t("推理强度（空白为服务默认）", "Reasoning effort (empty uses service default)"))
            TextField(t("例如 low，需服务支持", "Example: low; service dependent"), text: access.binding(\.reasoning)).textFieldStyle(.roundedBorder)
            Text(t("思考模式（需服务支持）", "Thinking mode (service dependent)"))
            CommittedPicker(title: t("思考模式", "Thinking mode"), selection: access.binding(\.thinking), options: [
                (t("服务默认（不发送）", "Service default (omit)"), .automatic), (t("开启", "Enabled"), .enabled), (t("关闭", "Disabled"), .disabled)
            ])
            Text(t("兼容选项同时用于术语提取；独立提取服务可在术语设置中覆盖推理强度。实际费用取决于供应商，缓存命中数不等于供应商折扣。", "Compatibility options also apply to extraction. A separate extraction target can override reasoning effort in term settings. Provider billing varies; local cache counts are not provider discounts.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title); TextField("", value: value, format: .number).frame(width: 100).accessibilityLabel(title) }
    }
    private func automatic(_ value: Binding<Int?>, fallback: Int) -> Binding<Bool> { Binding(get: { value.wrappedValue == nil }, set: { value.wrappedValue = $0 ? nil : fallback }) }
    private func count(_ value: Binding<Int?>, fallback: Int) -> Binding<Int> { Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }) }
    var validationError: PDFPerformanceSettingsError? { do { try settings.validate(requiresService: requiresService, extractsTerms: extractsTerms); return nil } catch { return error as? PDFPerformanceSettingsError } }
}
