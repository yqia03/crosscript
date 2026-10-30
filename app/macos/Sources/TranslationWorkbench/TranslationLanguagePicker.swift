import AppKit
import SwiftUI
import WorkbenchCore

private typealias LanguagePickerState<Value> = SwiftUI.State<Value>

/// Menu labels are immutable for each interface language. Streaming text and
/// recording ticks must not repeat hundreds of Locale lookups on the UI actor.
private enum LanguageMenuLabels {
    static let values: [[[(String, TranslationLanguage)]]] = [TranslationLanguageCatalog.text, .pdf, .live].map { catalog in
        [AppLanguage.english, .zhHans].map { language in
            catalog.languages.map { ($0.title(language), $0) }
        }
    }
    static func options(_ catalog: TranslationLanguageCatalog, _ language: AppLanguage) -> [(String, TranslationLanguage)] {
        let index: Int
        switch catalog { case .text: index = 0; case .pdf: index = 1; case .live: index = 2 }
        return values[index][language.isChinese ? 1 : 0]
    }
}

struct TranslationLanguagePicker: View {
    let title: String
    @Binding var selection: TranslationLanguage
    let catalog: TranslationLanguageCatalog
    let language: AppLanguage
    var compact = false
    var alignsCompactTrailing = false
    var detectsSourceAutomatically = false
    var automaticSourceLabel: String? = nil
    var selectAutomaticSource: (() -> Void)? = nil
    @LanguagePickerState private var customEntry = false
    @LanguagePickerState private var customCode = ""
    private enum Choice: Equatable { case language(TranslationLanguage), automatic, custom }
    private var options: [(String, Choice)] {
        var labels = LanguageMenuLabels.options(catalog, language)
        if !labels.contains(where: { $0.1 == selection }) { labels.append((selection.title(language), selection)) }
        var values = labels.map { ($0.0, Choice.language($0.1)) }
        if selectAutomaticSource != nil { values.insert((automaticSourceLabel ?? language.text("自动检测", "Detect language"), .automatic), at: 0) }
        if catalog == .text { values.append((language.text("其他语言代码…", "Other language code…"), .custom)) }
        return values
    }
    var body: some View {
        GlassLanguageMenu(title: title, selection: Binding(
            get: { detectsSourceAutomatically ? .automatic : Choice.language(selection) },
            set: {
                switch $0 {
                case .language(let value): selection = value
                case .automatic: selectAutomaticSource?()
                case .custom: customCode = ""; customEntry = true
                }
            }), options: options, compact: compact, alignsCompactTrailing: alignsCompactTrailing)
            .popover(isPresented: $customEntry) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("语言代码", "Language code")).font(.headline)
                    TextField(language.text("例如：yue、pt-BR", "For example: yue, pt-BR"), text: $customCode)
                        .textFieldStyle(.roundedBorder)
                    Text(language.text("填写模型支持的 BCP-47 语言代码。DeepSeek 未公布完整语言清单，翻译效果取决于所选模型。", "Enter a BCP-47 code supported by your model. DeepSeek does not publish a complete language list; translation quality depends on the selected model."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(language.text("使用此语言", "Use language")) {
                        selection = TranslationLanguage(rawValue: customCode.trimmingCharacters(in: .whitespacesAndNewlines))
                        customEntry = false
                    }.disabled(!TranslationLanguage(rawValue: customCode.trimmingCharacters(in: .whitespacesAndNewlines)).isValid)
                }.padding(16).frame(width: 300)
            }
    }
}

struct TranslationDirectionPicker: View {
    @Binding var direction: TextTranslationDirection
    let catalog: TranslationLanguageCatalog
    let language: AppLanguage
    var body: some View {
        HStack(spacing: 8) {
            TranslationLanguagePicker(title: language.text("原文语言", "Source language"), selection: Binding(
                get: { direction.sourceLanguage },
                set: { direction = .init(sourceLanguage: $0, targetLanguage: direction.targetLanguage) }),
                catalog: catalog, language: language)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TranslationLanguagePicker(title: language.text("译文语言", "Target language"), selection: Binding(
                get: { direction.targetLanguage },
                set: { direction = .init(sourceLanguage: direction.sourceLanguage, targetLanguage: $0) }),
                catalog: catalog, language: language)
        }
    }
}

/// Retains native menu commitment and accessibility with the workbench glass style.
private struct GlassLanguageMenu<Value: Equatable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var compact = false
    var alignsCompactTrailing = false
    @Environment(\.menuCommandBarrier) private var commands
    func makeCoordinator() -> CommittedPicker<Value>.Coordinator { .init(selection: $selection, options: options) }
    func makeNSView(context: Context) -> GlassLanguagePopUpButton {
        let button = GlassLanguagePopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(CommittedPicker<Value>.Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: GlassLanguagePopUpButton, context: Context) {
        context.coordinator.selection = $selection; context.coordinator.options = options
        if button.itemTitles != options.map(\.0) { button.removeAllItems(); button.addItems(withTitles: options.map(\.0)) }
        if let index = options.firstIndex(where: { $0.1 == selection }), button.indexOfSelectedItem != index { button.selectItem(at: index) }
        context.coordinator.track(button.menu, commands: commands)
        button.compact = compact; button.alignsCompactTrailing = alignsCompactTrailing
        button.invalidateIntrinsicContentSize()
        button.contextTitle = title; button.setAccessibilityLabel(title)
        button.setAccessibilityValue(button.titleOfSelectedItem)
        button.isEnabled = context.environment.isEnabled; button.needsDisplay = true
    }
    static func dismantleNSView(_ button: GlassLanguagePopUpButton, coordinator: CommittedPicker<Value>.Coordinator) { coordinator.track(nil, commands: nil) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GlassLanguagePopUpButton, context: Context) -> CGSize? { CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: compact ? 34 : 44) }
}

private final class GlassLanguagePopUpButton: NSPopUpButton {
    var contextTitle = ""
    var compact = false
    var alignsCompactTrailing = false
    override var intrinsicContentSize: NSSize {
        guard compact else { return NSSize(width: 180, height: 44) }
        let width = ((selectedItem?.title ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return NSSize(width: min(240, max(70, ceil(width) + 29)), height: 34)
    }
    override func draw(_ dirtyRect: NSRect) {
        if compact { drawCompact(); return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.98 : 0.74).setFill(); shape.fill()
        let tint = NSColor(red: 0.04, green: 0.49, blue: 0.61, alpha: isEnabled ? 1 : 0.45)
        tint.withAlphaComponent(0.22).setStroke(); shape.lineWidth = 1; shape.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (contextTitle as NSString).draw(in: NSRect(x: 12, y: isFlipped ? 6 : 24, width: max(0, bounds.width - 42), height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        ((selectedItem?.title ?? "") as NSString).draw(in: NSRect(x: 12, y: isFlipped ? 20 : 7, width: max(0, bounds.width - 42), height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: tint, .paragraphStyle: paragraph])
        let arrow = NSBezierPath(), x = bounds.maxX - 19, y = bounds.midY
        let axis: CGFloat = isFlipped ? -1 : 1
        arrow.move(to: NSPoint(x: x - 3.5, y: y + 1.5 * axis)); arrow.line(to: NSPoint(x: x, y: y - 2 * axis)); arrow.line(to: NSPoint(x: x + 3.5, y: y + 1.5 * axis))
        arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; tint.setStroke(); arrow.stroke()
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); shape.fill() }
    }
    private func drawCompact() {
        let tint = NSColor(red: 0.04, green: 0.49, blue: 0.61, alpha: isEnabled ? 1 : 0.45)
        let contentWidth = min(bounds.width, intrinsicContentSize.width)
        let origin = alignsCompactTrailing ? bounds.width - contentWidth : 0
        let shape = NSBezierPath(roundedRect: NSRect(x: origin, y: 0, width: contentWidth, height: bounds.height).insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isHighlighted { tint.withAlphaComponent(0.08).setFill(); shape.fill() }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let height = font.ascender - font.descender + font.leading
        ((selectedItem?.title ?? "") as NSString).draw(in: NSRect(x: origin + 7, y: (bounds.height - height) / 2, width: max(0, contentWidth - 28), height: height), withAttributes: [.font: font, .foregroundColor: tint, .paragraphStyle: paragraph])
        let arrow = NSBezierPath(), x = origin + contentWidth - 11, y = bounds.midY
        let axis: CGFloat = isFlipped ? -1 : 1
        arrow.move(to: NSPoint(x: x - 3, y: y + 1.5 * axis)); arrow.line(to: NSPoint(x: x, y: y - 1.5 * axis)); arrow.line(to: NSPoint(x: x + 3, y: y + 1.5 * axis))
        arrow.lineWidth = 1.3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; tint.setStroke(); arrow.stroke()
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); shape.fill() }
    }

}
