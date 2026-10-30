import Foundation

public struct PDFLayoutSettings: Codable, Equatable, Sendable {
    public enum FontFamily: String, Codable, CaseIterable, Sendable { case automatic, serif, sansSerif = "sans-serif", script }
    public var fontFamily: FontFamily = .automatic
    public var formulaFontPattern = ""
    public var formulaCharacterPattern = ""
    public var splitShortLines = false
    public var shortLineSplitFactor = 0.8
    public var skipCleaning = false
    public var richText = true
    public var enhanceCompatibility = false
    public var formulaPlaceholderHint = false
    public var mergeAlternatingLineNumbers = true
    public var renderForms = true
    public var renderCurves = true
    public var removeNonFormulaLines = false
    public var nonFormulaLineOverlapThreshold = 0.9
    public var figureTableProtectionThreshold = 0.9
    public var calculateFormulaOffsets = true
    public init() {}
    public func validate() throws {
        guard shortLineSplitFactor.isFinite, shortLineSplitFactor > 0 else { throw PDFLayoutSettingsError.invalidShortLineFactor }
        guard nonFormulaLineOverlapThreshold.isFinite, (0...1).contains(nonFormulaLineOverlapThreshold),
              figureTableProtectionThreshold.isFinite, (0...1).contains(figureTableProtectionThreshold) else { throw PDFLayoutSettingsError.invalidThreshold }
        guard formulaFontPattern.utf8.count <= 4096, formulaCharacterPattern.utf8.count <= 4096 else { throw PDFLayoutSettingsError.patternTooLong }
        // Python's regex grammar is validated by the pinned bridge. Foundation's
        // grammar differs and must not reject valid engine expressions here.
    }
    public var engineSettings: [String: Any] {
        var values: [String: Any] = ["split_short_lines": splitShortLines, "short_line_split_factor": shortLineSplitFactor,
            "skip_clean": skipCleaning, "disable_rich_text_translate": !richText, "enhance_compatibility": enhanceCompatibility,
            "add_formula_placehold_hint": formulaPlaceholderHint, "merge_alternating_line_numbers": mergeAlternatingLineNumbers,
            "skip_form_render": !renderForms, "skip_curve_render": !renderCurves, "remove_non_formula_lines": removeNonFormulaLines,
            "non_formula_line_iou_threshold": nonFormulaLineOverlapThreshold, "figure_table_protection_threshold": figureTableProtectionThreshold,
            "skip_formula_offset_calculation": !calculateFormulaOffsets]
        if fontFamily != .automatic { values["primary_font_family"] = fontFamily.rawValue }
        if !formulaFontPattern.isEmpty { values["formular_font_pattern"] = formulaFontPattern }
        if !formulaCharacterPattern.isEmpty { values["formular_char_pattern"] = formulaCharacterPattern }
        return values
    }
    public func fontTitle(_ language: AppLanguage) -> String {
        switch fontFamily {
        case .automatic: return language.text("自动（匹配源字体）", "Automatic (match source)")
        case .serif: return language.text("衬线", "Serif")
        case .sansSerif: return language.text("无衬线", "Sans serif")
        case .script: return language.text("手写", "Script")
        }
    }
    public func snapshotLines(_ language: AppLanguage) -> [String] {
        func flag(_ zh: String, _ en: String, _ value: Bool) -> String {
            language.text(zh, en) + ": " + (value ? language.text("开", "On") : language.text("关", "Off"))
        }
        return [language.text("字体：", "Font: ") + fontTitle(language),
            language.text("公式字体规则：", "Formula font pattern: ") + (formulaFontPattern.isEmpty ? language.text("默认", "Default") : formulaFontPattern),
            language.text("公式字符规则：", "Formula character pattern: ") + (formulaCharacterPattern.isEmpty ? language.text("默认", "Default") : formulaCharacterPattern),
            flag("拆分短行", "Split short lines", splitShortLines) + " (\(shortLineSplitFactor))",
            flag("增强兼容", "Enhanced compatibility", enhanceCompatibility), flag("跳过清理", "Skip cleaning", skipCleaning || enhanceCompatibility),
            flag("富文本翻译", "Rich text", richText && !enhanceCompatibility), flag("公式占位提示", "Formula placeholder hint", formulaPlaceholderHint),
            flag("合并交错行号", "Merge alternating line numbers", mergeAlternatingLineNumbers), flag("绘制表单对象", "Render form objects", renderForms),
            flag("绘制曲线", "Render curves", renderCurves), flag("移除非公式线条", "Remove non-formula lines", removeNonFormulaLines),
            language.text("线条重叠阈值：", "Line overlap threshold: ") + "\(nonFormulaLineOverlapThreshold)",
            language.text("图表保护阈值：", "Figure/table protection threshold: ") + "\(figureTableProtectionThreshold)",
            flag("计算公式偏移", "Calculate formula offsets", calculateFormulaOffsets)]
    }
}
public enum PDFLayoutSettingsError: Error, Equatable, Sendable {
    case invalidShortLineFactor, invalidThreshold, patternTooLong
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .invalidShortLineFactor: return language.text("短行系数必须是大于 0 的有限数。默认 0.8。", "Short-line factor must be a finite number greater than zero. Default: 0.8.")
        case .invalidThreshold: return language.text("重叠与图表保护阈值必须在 0 到 1 之间。", "Overlap and figure/table protection thresholds must be between 0 and 1.")
        case .patternTooLong: return language.text("公式规则过长，请将每条规则限制在 4096 字节以内。", "Formula patterns must each be at most 4096 bytes.")
        }
    }
}
