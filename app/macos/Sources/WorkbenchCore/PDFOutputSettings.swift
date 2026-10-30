import Foundation

public struct PDFOutputSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case bilingual, translated, both }
    public enum Layout: String, Codable, CaseIterable, Sendable { case sideBySide, alternatingPages }
    public enum Watermark: String, Codable, CaseIterable, Sendable { case watermarked, noWatermark, both }
    public var pages = ""
    public var onlyIncludeTranslatedPages = false
    public var maximumPagesPerPart: Int?
    public var mode: Mode = .bilingual
    public var layout: Layout = .sideBySide
    public var translatedFirst = false
    public var watermark: Watermark = .watermarked
    public init() {}

    public func summary(_ language: AppLanguage, localOnly: Bool = false) -> String {
        let range = pages.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [range.isEmpty ? language.text("全部页面", "All pages") : language.text("页码：", "Pages: ") + range]
        if onlyIncludeTranslatedPages { parts.append(language.text("仅所选页", "Selected pages only")) }
        if let maximumPagesPerPart { parts.append(language.text("每部分 \(maximumPagesPerPart) 页", "\(maximumPagesPerPart) pages per part")) }
        switch mode {
        case .bilingual: parts.append(localOnly ? language.text("对照", "Comparison") : language.text("双语", "Bilingual"))
        case .translated: parts.append(localOnly ? language.text("处理结果", "Processed") : language.text("译文", "Translated"))
        case .both: parts.append(localOnly ? language.text("处理与对照", "Processed and comparison") : language.text("译文与双语", "Translated and bilingual"))
        }
        if mode != .translated {
            parts.append(layout == .sideBySide ? language.text("并排", "Side by side") : language.text("交替页", "Alternating pages"))
            parts.append(translatedFirst ? (localOnly ? language.text("处理结果在前", "Processed first") : language.text("译文在前", "Translation first")) : language.text("原文在前", "Original first"))
        }
        switch watermark {
        case .watermarked: parts.append(language.text("带水印", "Watermarked"))
        case .noWatermark: parts.append(language.text("无水印", "No watermark"))
        case .both: parts.append(language.text("两种水印版本", "Both watermark versions"))
        }
        return parts.joined(separator: " · ")
    }

    public func validate(pageCount: Int? = nil) throws {
        if let maximumPagesPerPart, maximumPagesPerPart < 1 { throw PDFOutputSettingsError.invalidPartSize }
        if pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if onlyIncludeTranslatedPages { throw PDFOutputSettingsError.rangeRequired }
            return
        }
        _ = try selectedPages(pageCount: pageCount)
    }
    /// Expands against a real source page count for preflight; parsing alone keeps open ends.
    public func selectedPages(pageCount: Int?) throws -> [ClosedRange<Int>]? {
        let value = pages.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= 4096 else { throw PDFOutputSettingsError.invalidRange }
        let ranges = try value.split(separator: ",", omittingEmptySubsequences: false).map { token -> ClosedRange<Int> in
            let part = token.trimmingCharacters(in: .whitespaces)
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2, !bounds.allSatisfy(\.isEmpty) else { throw PDFOutputSettingsError.invalidRange }
            func number(_ text: Substring) throws -> Int {
                guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let result = Int(text), result > 0 else { throw PDFOutputSettingsError.invalidRange }
                return result
            }
            let start = bounds[0].isEmpty ? 1 : try number(bounds[0])
            let end = bounds.count == 1 ? start : (bounds[1].isEmpty ? (pageCount ?? Int.max) : try number(bounds[1]))
            if let pageCount, start > pageCount || end > pageCount { throw PDFOutputSettingsError.outsideDocument(pageCount) }
            guard start <= end else { throw PDFOutputSettingsError.invalidRange }
            return start...end
        }
        return ranges
    }
    public var engineSettings: [String: Any] {
        var values: [String: Any] = ["no_mono": mode == .bilingual, "no_dual": mode == .translated,
            "use_alternating_pages_dual": layout == .alternatingPages, "dual_translate_first": translatedFirst,
            "watermark_output_mode": watermark == .noWatermark ? "no_watermark" : watermark.rawValue,
            "only_include_translated_page": onlyIncludeTranslatedPages]
        let range = pages.trimmingCharacters(in: .whitespacesAndNewlines)
        if !range.isEmpty { values["pages"] = range }
        if let maximumPagesPerPart { values["max_pages_per_part"] = maximumPagesPerPart }
        return values
    }
}
public enum PDFOutputSettingsError: Error, Equatable, Sendable {
    case invalidRange, outsideDocument(Int), rangeRequired, invalidPartSize
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .invalidRange: return language.text("页范围无效。请使用正页码，例如 1-3,5、-3 或 5-。", "Invalid page range. Use positive page numbers, such as 1-3,5, -3 or 5-.")
        case .outsideDocument(let count): return language.text("页范围超出此 PDF 的 \(count) 页。", "The range exceeds this PDF's \(count) pages.")
        case .rangeRequired: return language.text("仅输出所选页需要先填写页范围。", "Enter a page range before including only selected pages.")
        case .invalidPartSize: return language.text("每部分页数必须大于 0；关闭分部可整体处理。", "Pages per part must be greater than zero. Turn splitting off to process the whole document.")
        }
    }
}
