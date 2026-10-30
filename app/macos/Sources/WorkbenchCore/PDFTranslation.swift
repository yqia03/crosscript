import Foundation

public enum PDFTranslationError: String, Error, Codable, Sendable {
    case invalidFormulaPattern, scannedDocument, noExtractableText, textExtraction, configuration, credential, modelUnavailable, rateLimited, network, processing, storage, invalidPDF, invalidOutput, runtimeUnavailable, runtimeIncompatible, cancelled, interrupted, requestLimit
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .invalidFormulaPattern: return language.text("公式字体或字符正则表达式无效，请检查规则。未调用翻译服务，原始资料和旧结果仍保留。", "The formula font or character regex is invalid. Check the pattern. No translation request was sent; source and existing results remain.")
        case .scannedDocument: return language.text("引擎检测到扫描文档。可尝试自动或强制 OCR 兼容；该功能需要已有文字层，不能识别纯图片。原始资料和已有结果仍保留。", "The engine detected a scanned document. Try automatic or forced OCR compatibility with an existing text layer; it cannot recognize image-only text. Source and existing results are retained.")
        case .noExtractableText: return language.text("所选页面没有可提取的文字，未生成翻译结果。此版本不包含图片文字识别；可导入带文字层的 PDF，或选择仅解析生成。", "Selected pages have no extractable text, so no translated result was created. This version does not recognize image-only text. Import a PDF with a text layer, or choose local parse-and-generate.")
        case .textExtraction: return language.text("引擎无法可靠提取此 PDF 的文字。请尝试兼容设置或带有效文字层的 PDF；原始副本和已有结果仍保留。", "The engine could not reliably extract this PDF’s text. Try compatibility settings or a PDF with a valid text layer. The source copy and existing results are retained.")
        case .configuration: return language.text("PDF 设置无效，请检查语言、输出与服务。", "PDF settings are invalid. Check language, output and service.")
        case .credential: return language.text("此 PDF 服务的凭据不可用，请在设置中更新。", "Credentials for this PDF service are unavailable. Update them in Settings.")
        case .modelUnavailable: return language.text("服务报告模型不可用，请核对所选模型。", "The service reports the model is unavailable. Check the selected model.")
        case .rateLimited: return language.text("服务限流或额度不足。资料仍保留，可主动重试。", "The service reports a rate or quota limit. Your material is retained; retry manually.")
        case .network: return language.text("无法连接 PDF 翻译服务。请检查网络后重试。", "Cannot reach the PDF translation service. Check the network and retry.")
        case .processing: return language.text("引擎未能完成此 PDF。原始副本与已有结果仍保留。", "The engine could not process this PDF. The source copy and existing results are retained.")
        case .storage: return language.text("PDF 资料保存失败，现有文件与待保存结果仍保留。请重试保存。", "PDF material could not be saved. Existing files and pending results are retained. Retry saving.")
        case .invalidPDF: return language.text("无法读取此 PDF，文件可能损坏或需要密码。", "This PDF cannot be read. It may be damaged or password protected.")
        case .invalidOutput: return language.text("引擎没有返回可打开的 PDF，未替换已有结果。", "The engine did not return a readable PDF. Existing results were not replaced.")
        case .runtimeUnavailable: return language.text("PDF 组件尚未准备好。原始资料已保留。", "PDF components are not ready. Your source material is retained.")
        case .runtimeIncompatible: return language.text("PDF 组件版本不匹配，需要重新准备组件。", "The PDF component version does not match. Prepare the components again.")
        case .cancelled: return language.text("任务已取消，原始资料与已有结果仍保留。", "The task was cancelled. The source and existing results are retained.")
        case .interrupted: return language.text("任务因退出而中断，未自动重新调用服务。", "The task was interrupted by exit. No service request was repeated automatically.")
        case .requestLimit: return language.text("达到此任务的请求上限，未继续调用服务。", "This task reached its request limit. No further service requests were sent.")
        }
    }
}

public struct PDFTranslationOptions: Codable, Equatable, Sendable {
    public var direction: TextTranslationDirection = .englishToChinese
    public var output = PDFOutputSettings()
    public var content = PDFContentSettings()
    public var layout = PDFLayoutSettings()
    public var performance = PDFPerformanceSettings()
    public var effectiveOutput: PDFOutputSettings {
        var value = output; if content.operation != .parseOnly && layout.enhanceCompatibility { value.translatedFirst = true }; return value
    }
    public var effectiveLayoutSettings: [String: Any] {
        if content.operation == .parseOnly { return ["skip_form_render": !layout.renderForms, "skip_curve_render": !layout.renderCurves] }
        return layout.engineSettings
    }
    public var effectivePerformanceSettings: [String: Any] {
        if !requiresService { return ["report_interval": performance.progressInterval, "debug": performance.diagnosticPDF, "show_char_box": performance.diagnosticPDF && performance.characterBoxes] }
        var settings = performance.engineSettings
        if !autoExtractGlossary { settings.removeValue(forKey: "term_pool_max_workers") }
        return settings
    }
    public var requiresService: Bool { content.requiresService }
    public var resources = TranslationResourceSnapshot()
    public var autoExtractGlossary = true
    public var saveAutoExtractedGlossary = false
    public var termExtractionProvider: ProviderSnapshot?
    public var termExtractionReasoning: String?
    public init(direction: TextTranslationDirection = .englishToChinese) { self.direction = direction }
    private enum CodingKeys: String, CodingKey { case direction, output, content, layout, performance, resources, autoExtractGlossary, saveAutoExtractedGlossary, termExtractionProvider, termExtractionReasoning }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        direction = try values.decodeIfPresent(TextTranslationDirection.self, forKey: .direction) ?? .englishToChinese
        output = try values.decodeIfPresent(PDFOutputSettings.self, forKey: .output) ?? .init()
        content = try values.decodeIfPresent(PDFContentSettings.self, forKey: .content) ?? .init()
        layout = try values.decodeIfPresent(PDFLayoutSettings.self, forKey: .layout) ?? .init()
        performance = try values.decodeIfPresent(PDFPerformanceSettings.self, forKey: .performance) ?? .init()
        resources = try values.decodeIfPresent(TranslationResourceSnapshot.self, forKey: .resources) ?? .init()
        autoExtractGlossary = try values.decodeIfPresent(Bool.self, forKey: .autoExtractGlossary) ?? true
        saveAutoExtractedGlossary = try values.decodeIfPresent(Bool.self, forKey: .saveAutoExtractedGlossary) ?? false
        termExtractionProvider = try values.decodeIfPresent(ProviderSnapshot.self, forKey: .termExtractionProvider)
        termExtractionReasoning = try values.decodeIfPresent(String.self, forKey: .termExtractionReasoning)
    }
    public func validated(pageCount: Int? = nil) throws -> Self {
        if requiresService && !TranslationLanguageCatalog.pdf.supports(direction) { throw PDFTranslationError.configuration }
        try output.validate(pageCount: pageCount)
        try content.validate()
        if content.operation != .parseOnly { try layout.validate() }
        try performance.validate(requiresService: requiresService, extractsTerms: autoExtractGlossary)
        if content.operation == .parseOnly && output.watermark != .noWatermark { throw PDFContentSettingsError.parseOnlyRequiresNoWatermark }
        _ = try resources.validated()
        if let termExtractionProvider { _ = try termExtractionProvider.validated() }
        if let termExtractionReasoning {
            guard !termExtractionReasoning.isEmpty, termExtractionReasoning.count <= 200,
                  !termExtractionReasoning.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  termExtractionProvider != nil else { throw PDFTranslationError.configuration }
        }
        guard autoExtractGlossary || (!saveAutoExtractedGlossary && termExtractionProvider == nil && termExtractionReasoning == nil) else { throw PDFTranslationError.configuration }
        return self
    }
}

public enum PDFOutputKind: String, Codable, Sendable, CaseIterable {
    case mono, dual, monoNoWatermark, dualNoWatermark, glossaryCSV
    public var isPDF: Bool { self != .glossaryCSV }
    public var fileExtension: String { isPDF ? "pdf" : "csv" }
}
public struct PDFOutput: Identifiable, Codable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: PDFOutputKind
    public let filename: String
    public init(kind: PDFOutputKind, filename: String) { self.kind = kind; self.filename = filename }
}
public struct PDFGeneratedOutput: Codable, Sendable {
    public let kind: PDFOutputKind
    public let url: URL
    public init(kind: PDFOutputKind, url: URL) { self.kind = kind; self.url = url }
}
public struct PDFEngineResult: Codable, Sendable {
    public let outputs: [PDFGeneratedOutput]
    public let engineVersion: String
    public let integrationVersion: Int
    public let contentReport: PDFContentReport?
    public let diagnostics: PDFRunDiagnostics?
    public init(outputs: [PDFGeneratedOutput], engineVersion: String = "0.6.4", integrationVersion: Int = 1, contentReport: PDFContentReport? = nil, diagnostics: PDFRunDiagnostics? = nil) {
        self.contentReport = contentReport; self.diagnostics = diagnostics
        self.outputs = outputs; self.engineVersion = engineVersion; self.integrationVersion = integrationVersion
    }
}
public struct PDFEngineProgress: Sendable {
    public let stage: String
    public let percent: Double
    public init(stage: String, percent: Double) { self.stage = stage; self.percent = percent }
}
public struct PDFEngineRequest: Sendable {
    public let id: UUID
    public let inputURL: URL
    public let outputDirectory: URL
    public let provider: ProviderSnapshot?
    public let options: PDFTranslationOptions
    /// Ephemeral target-scoped secret; never encoded in task/result snapshots.
    public let termExtractionAPIKey: String?
    public init(id: UUID, inputURL: URL, outputDirectory: URL, provider: ProviderSnapshot?, options: PDFTranslationOptions, termExtractionAPIKey: String? = nil) {
        self.termExtractionAPIKey = termExtractionAPIKey
        self.id = id; self.inputURL = inputURL; self.outputDirectory = outputDirectory; self.provider = provider; self.options = options
    }
}
public protocol PDFTranslating: Sendable {
    /// Must return only after the actual worker has exited, including cancellation.
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult
}

public struct PDFTranslationResult: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let createdAt: Date
    public let provider: ProviderSnapshot?
    public let options: PDFTranslationOptions
    public let engineVersion: String
    public let integrationVersion: Int
    public let outputs: [PDFOutput]
    public let contentReport: PDFContentReport?
    public let diagnostics: PDFRunDiagnostics?
}
public struct PDFBackgroundTask: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, completed, failed, cancelled, interrupted, awaitingResume, awaitingLocalSave
        public var occupiesMaterial: Bool { [.queued, .running, .awaitingResume, .awaitingLocalSave, .interrupted].contains(self) }
    }
    public let id: UUID
    public let createdAt: Date
    public let provider: ProviderSnapshot?
    public let options: PDFTranslationOptions
    public var status: Status
    public var failure: PDFTranslationError?
    public init(provider: ProviderSnapshot?, options: PDFTranslationOptions) {
        id = UUID(); createdAt = Date(); self.provider = provider; self.options = options; status = .queued
    }
    public func statusDescription(_ language: AppLanguage) -> String {
        if !options.requiresService {
            if status == .running { return language.text("本地处理中", "Processing locally") }
            if status == .completed { return language.text("本地生成完成 · 未翻译", "Local generation completed · Untranslated") }
        }
        return status.description(language)
    }
}
public struct PDFMaterial: Identifiable, Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var name: String
    public var selectedResultID: UUID?
    public var results: [PDFTranslationResult] = []
    public var tasks: [PDFBackgroundTask] = []
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name; createdAt = Date(); updatedAt = createdAt }
    public var selectedResult: PDFTranslationResult? { results.first { $0.id == selectedResultID } }
    public var isBusy: Bool { tasks.contains { $0.status.occupiesMaterial } }
}
public enum PDFDeletionTarget: Equatable {
    case material(UUID), result(UUID, UUID)
    public var materialID: UUID { switch self { case .material(let id), .result(let id, _): return id } }
}
public struct PDFDeletionConfirmation: Identifiable, Equatable {
    public let id = UUID()
    public let target: PDFDeletionTarget
    public let material: PDFMaterial
}

struct PDFPendingResultReceipt: Codable {
    let task: PDFBackgroundTask
    let generated: PDFEngineResult
    let resultID: UUID
}

public extension PDFBackgroundTask.Status {
    func description(_ language: AppLanguage) -> String {
        switch self {
        case .queued: return language.text("排队中", "Queued")
        case .running: return language.text("正在翻译", "Translating")
        case .completed: return language.text("已完成", "Completed")
        case .failed: return language.text("失败", "Failed")
        case .cancelled: return language.text("已取消", "Cancelled")
        case .interrupted: return language.text("已中断", "Interrupted")
        case .awaitingResume: return language.text("等待主动恢复", "Awaiting resume")
        case .awaitingLocalSave: return language.text("等待本地保存", "Awaiting local save")
        }
    }
}
