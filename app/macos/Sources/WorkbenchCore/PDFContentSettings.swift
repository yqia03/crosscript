import Foundation

public struct PDFContentSettings: Codable, Equatable, Sendable {
    public enum ScanMode: String, Codable, CaseIterable, Sendable { case detect, skipDetection, forceWorkaround, automaticWorkaround }
    public enum Operation: String, Codable, CaseIterable, Sendable { case translate, typesetOnly, parseOnly }
    public var scanMode: ScanMode = .detect
    public var minimumTextLength = 5
    public var processGraphicElements = true
    public var operation: Operation = .translate
    public init() {}
    public var requiresService: Bool { operation == .translate }
    public func validate() throws {
        guard minimumTextLength >= 0 else { throw PDFContentSettingsError.invalidMinimumLength }
    }
    public var engineSettings: [String: Any] {
        ["min_text_length": minimumTextLength, "enable_graphic_element_process": processGraphicElements,
         "skip_scanned_detection": scanMode == .skipDetection || scanMode == .forceWorkaround,
         "ocr_workaround": scanMode == .forceWorkaround, "auto_enable_ocr_workaround": scanMode == .automaticWorkaround,
         "skip_translation": operation == .typesetOnly, "only_parse_generate_pdf": operation == .parseOnly]
    }
    public func summary(_ language: AppLanguage) -> String {
        if operation == .parseOnly { return operationTitle(language) + language.text(" · 无水印", " · No watermark") }
        let scan: String
        switch scanMode {
        case .detect: scan = language.text("检测扫描", "Detect scans")
        case .skipDetection: scan = language.text("跳过扫描检测", "Skip scan detection")
        case .forceWorkaround: scan = language.text("强制 OCR 兼容", "Forced OCR compatibility")
        case .automaticWorkaround: scan = language.text("自动 OCR 兼容", "Automatic OCR compatibility")
        }
        let graphics = processGraphicElements ? language.text("处理图形", "Process graphics") : language.text("不处理图形", "Skip graphic processing")
        return operationTitle(language) + " · " + scan + " · " + graphics + (requiresService ? language.text(" · 最短文本 \(minimumTextLength)", " · Minimum text length \(minimumTextLength)") : "")
    }
    public func operationTitle(_ language: AppLanguage) -> String {
        switch operation {
        case .translate: return language.text("翻译 PDF", "Translate PDF")
        case .typesetOnly: return language.text("仅排版，不翻译", "Typeset only, without translation")
        case .parseOnly: return language.text("仅解析并生成，不翻译", "Parse and generate only, without translation")
        }
    }
}
public enum PDFContentSettingsError: Error, Equatable, Sendable {
    case invalidMinimumLength, parseOnlyRequiresNoWatermark
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .invalidMinimumLength: return language.text("最短翻译文本长度不能小于 0。", "Minimum text length cannot be negative.")
        case .parseOnlyRequiresNoWatermark: return language.text("仅解析生成会跳过水印处理。请将输出设为无水印，或改用仅排版。", "Parse-only generation skips watermark processing. Choose no watermark, or use typeset-only mode.")
        }
    }
}
public struct PDFContentReport: Codable, Equatable, Sendable {
    public let sourcePageCount: Int
    public let selectedPageCount: Int
    public let pagesWithoutExtractableText: Int
    public init(sourcePageCount: Int, selectedPageCount: Int, pagesWithoutExtractableText: Int) {
        self.sourcePageCount = sourcePageCount; self.selectedPageCount = selectedPageCount
        self.pagesWithoutExtractableText = pagesWithoutExtractableText
    }
}
