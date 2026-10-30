import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias EditorState<Value> = SwiftUI.State<Value>

/// Edits and playback both use the selected result's current text and source anchors.
@MainActor struct TranscriptEditorView: View {
    @ObservedObject var processing: PostRecordingSession
    let recording: Recording
    let result: TranscriptResult
    let playFrom: (TimeInterval) -> Void
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @AppStorage("transcriptShowsParagraphs") private var showsParagraphs = false
    @AppStorage("transcriptExportIncludesTimestamps") private var includeTimestamps = false
    @StateObject private var paragraphEdit = ParagraphEditSession()
    @EditorState private var actionStatus: ActionStatus?
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private enum ActionStatus { case copied, copyFailed, exported, exportFailed }
    private var actionMessage: String? {
        switch actionStatus {
        case .copied: return t("已复制当前全文", "Current text copied")
        case .copyFailed: return t("复制失败，请重试。", "Copy failed. Please retry.")
        case .exported: return t("已导出当前全文", "Current text exported")
        case .exportFailed: return t("导出失败；文字与音频仍保留，可重试。", "Export failed. Text and audio are retained; you can retry.")
        case nil: return nil
        }
    }
    private var text: String { processing.transcriptText(recordingID: recording.id, resultID: result.id) ?? result.text }
    private var currentResult: TranscriptResult {
        processing.materials[recording.id]?.results.first { $0.id == result.id } ?? result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MissingIntervalsView(intervals: currentResult.document?.missingIntervals ?? [])
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { modePicker; outputActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { modePicker; outputActions }
            }
            if processing.hasUnsavedTranscript(recordingID: recording.id) {
                Label(t("本地保存未完成，草稿仍在。请重试保存后再退出。", "Local save is incomplete. Your draft is retained here; retry before quitting."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(t("重试本地保存", "Retry local save")) { processing.retrySaving() }
                    .buttonStyle(.bordered)
            } else {
                Label(t("编辑自动保存到本地", "Edits save locally"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !processing.canEditTranscript(recordingID: recording.id, resultID: result.id) {
                Text(t("请先完成待保存结果的本地保存，再编辑此结果。", "Finish saving the pending result locally before editing this result."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showsParagraphs { paragraphs }
            else {
                TranscriptTextEditor(text: text, label: t("转写全文", "Full transcript"), isEditable: processing.canEditTranscript(recordingID: recording.id, resultID: result.id), replace: { range, replacement in
                    let oldText = text as NSString
                    guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= oldText.length else { return false }
                    let expected = oldText.replacingCharacters(in: range, with: replacement)
                    _ = processing.replaceTranscriptText(recordingID: recording.id, resultID: result.id, range: range, replacement: replacement)
                    actionStatus = nil
                    // Failed disk writes retain the edited draft; reject only an edit the use case refused.
                    return processing.transcriptText(recordingID: recording.id, resultID: result.id) == expected
                }, synchronize: { value in
                    // Without a trustworthy native edit range, do not guess which repeated text retained its timing.
                    _ = processing.replaceTranscriptText(recordingID: recording.id, resultID: result.id,
                        range: NSRange(location: 0, length: text.utf16.count), replacement: value)
                    actionStatus = nil
                    return processing.transcriptText(recordingID: recording.id, resultID: result.id) == value
                })
                .frame(height: 290)
                .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(t("编辑不修改原始音频。拆分出的新段落若没有可靠起点，将无法按段回听；合并段落沿用首段起点。", "Editing keeps the original audio intact. A split paragraph without a reliable start cannot be located; merged paragraphs keep the first start."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionMessage {
                Text(actionMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: result.id) { _, _ in actionStatus = nil; paragraphEdit.finish() }
        .onChange(of: showsParagraphs) { _, _ in paragraphEdit.finish() }
    }

    private var modePicker: some View {
        Picker(t("文字视图", "Transcript view"), selection: $showsParagraphs) {
            Text(t("编辑全文", "Edit text")).tag(false)
            Text(t("段落回听", "Listen by paragraph")).tag(true)
        }.pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel(t("文字视图", "Transcript view"))
            .frame(maxWidth: 300)
    }

    private var outputActions: some View {
        HStack(spacing: 8) {
            Button {
                guard let current = processing.transcriptText(recordingID: recording.id, resultID: result.id) else { return }
                NSPasteboard.general.clearContents()
                actionStatus = NSPasteboard.general.setString(current, forType: .string) ? .copied : .copyFailed
            } label: { Label(t("复制", "Copy"), systemImage: "doc.on.doc") }
            Menu {
                Toggle(t("包含段落时间戳", "Include paragraph timestamps"), isOn: $includeTimestamps)
                Divider()
                Button(t("导出 TXT", "Export TXT")) { export(.text) }
                Button(t("导出 Markdown", "Export Markdown")) { export(.markdown) }
            } label: { Label(t("导出", "Export"), systemImage: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize()
        }.buttonStyle(.bordered).font(.callout)
    }

    private var paragraphs: some View {
        let current = currentResult.paragraphs
        let items = paragraphEdit.original == nil ? current : paragraphEdit.rows
        return VStack(alignment: .leading, spacing: 10) {
            Text(t("点击文字直接编辑，点击播放按钮回听。编辑自动保存；完成后刷新分段。", "Click text to edit, or the play button to listen. Edits save automatically; finish to refresh paragraphs."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(items) { paragraph in
                        let range = paragraphEdit.currentRange(for: paragraph)
                        // A deleted row can share the following paragraph's offset while its editor stays mounted.
                        let start = range.length == 0 ? nil : current.first { $0.range.location == range.location }?.playbackStart
                        paragraphContent(paragraph, start: start, items: current)
                    }
                }.padding(.trailing, 20)
            }.frame(height: 290)
        }
    }

    private func paragraphContent(_ paragraph: TranscriptParagraph, start: TimeInterval?, items: [TranscriptParagraph]) -> some View {
        let editing = paragraphEdit.original?.id == paragraph.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    if let start { playFrom(start) }
                } label: {
                    Label(start.map { recordingClock($0) } ?? t("无可靠起点", "No reliable start"),
                          systemImage: start == nil ? "clock.badge.questionmark" : "play.circle")
                }.buttonStyle(.plain).disabled(start == nil)
                    .accessibilityLabel(start.map { t("从 ", "Listen from ") + recordingClock($0) } ?? t("无可靠起点", "No reliable start"))
                Spacer()
                if editing {
                    Button(t("完成编辑", "Done editing")) { paragraphEdit.finish() }.buttonStyle(.borderless)
                } else {
                    Button { beginParagraphEdit(paragraph, items: items) } label: {
                        Label(t("编辑段落", "Edit paragraph"), systemImage: "pencil")
                    }.buttonStyle(.borderless).accessibilityLabel(t("编辑段落", "Edit paragraph")).disabled(!processing.canEditTranscript(recordingID: recording.id, resultID: result.id))
                }
            }.font(.caption).foregroundStyle(.secondary)
            if editing {
                TranscriptTextEditor(text: paragraphEdit.text, label: t("段落文字", "Paragraph text"),
                    isEditable: processing.canEditTranscript(recordingID: recording.id, resultID: result.id),
                    replace: { range, replacement in
                        actionStatus = nil
                        return paragraphEdit.replace(range, with: replacement, processing: processing, recordingID: recording.id, resultID: result.id)
                    }, synchronize: { value in
                        actionStatus = nil
                        return paragraphEdit.replace(NSRange(location: 0, length: paragraphEdit.text.utf16.count), with: value,
                            processing: processing, recordingID: recording.id, resultID: result.id)
                    }, focusOnMount: true)
                    .frame(height: 140)
            } else {
                Text(paragraph.text).font(.system(size: 15)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    .contentShape(Rectangle()).onTapGesture { beginParagraphEdit(paragraph, items: items) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    private func beginParagraphEdit(_ paragraph: TranscriptParagraph, items: [TranscriptParagraph]) {
        guard processing.canEditTranscript(recordingID: recording.id, resultID: result.id) else { return }
        let range = paragraphEdit.currentRange(for: paragraph)
        guard let current = items.first(where: { $0.range.location == range.location }) else { return }
        paragraphEdit.begin(current, rows: items)
    }

    private func export(_ format: TranscriptExportFormat) {
        let panel = NSSavePanel()
        panel.title = format == .text ? t("导出当前转写为 TXT", "Export current transcript as TXT") : t("导出当前转写为 Markdown", "Export current transcript as Markdown")
        panel.allowedContentTypes = [format == .text ? .plainText : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ExportFilename.transcript(extension: format == .text ? "txt" : "md")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            actionStatus = processing.exportTranscript(recordingID: recording.id, resultID: result.id, format: format, includeTimestamps: includeTimestamps, language: language, to: url) ? .exported : .exportFailed
        }
    }
}

/// Preserve precise edit ranges when available, and reconcile native undo or composition changes.
private struct TranscriptTextEditor: NSViewRepresentable {
    let text: String
    let label: String
    let isEditable: Bool
    let replace: (NSRange, String) -> Bool
    let synchronize: (String) -> Bool
    var focusOnMount = false

    func makeCoordinator() -> Coordinator { Coordinator(text: text, replace: replace, synchronize: synchronize) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // A dedicated track keeps the scroller outside the editable text.
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        let editor = NSTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.isEditable = isEditable
        editor.setAccessibilityLabel(label)
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        context.coordinator.editor = editor
        scroll.documentView = editor
        if focusOnMount { DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }; editor.window?.makeFirstResponder(editor)
        } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.replace = replace
        context.coordinator.synchronize = synchronize
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(label)
        editor.isEditable = isEditable
        guard !context.coordinator.isApplyingEdit else { return }
        context.coordinator.isRestoringText = true
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
        context.coordinator.synchronizedText = text
        context.coordinator.isRestoringText = false
    }
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        weak var editor: NSTextView?
        var isRestoringText = false
        var replace: (NSRange, String) -> Bool
        var synchronize: (String) -> Bool
        var synchronizedText: String
        var isApplyingEdit = false
        init(text: String, replace: @escaping (NSRange, String) -> Bool, synchronize: @escaping (String) -> Bool) {
            synchronizedText = text
            self.replace = replace
            self.synchronize = synchronize
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard textView.isEditable else { return false }
            guard let replacementString else { return true }
            let source = textView.string as NSString
            guard affectedCharRange.location >= 0, affectedCharRange.length >= 0,
                  affectedCharRange.location <= source.length,
                  affectedCharRange.length <= source.length - affectedCharRange.location else { return false }
            let expected = source.replacingCharacters(in: affectedCharRange, with: replacementString)
            isApplyingEdit = true
            let accepted = replace(affectedCharRange, replacementString)
            if accepted { synchronizedText = expected }
            else { isApplyingEdit = false }
            return accepted
        }
        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !isRestoringText else { return }
            isApplyingEdit = true
            defer { isApplyingEdit = false }
            let current = textStorage.string
            guard current != synchronizedText else { return }
            let old = synchronizedText as NSString
            let new = current as NSString
            let oldLength = editedRange.length - delta
            let location = editedRange.location
            let valid = location >= 0 && location <= old.length && location <= new.length && oldLength >= 0 &&
                oldLength <= old.length - location && editedRange.length >= 0 && editedRange.length <= new.length - location
            if valid {
                let priorRange = NSRange(location: location, length: oldLength)
                let replacement = new.substring(with: editedRange)
                if old.replacingCharacters(in: priorRange, with: replacement) == current {
                    if replace(priorRange, replacement) { synchronizedText = current }
                    else { restoreSynchronizedText() }
                    return
                }
            }
            if synchronize(current) { synchronizedText = current }
            else { restoreSynchronizedText() }
        }
        private func restoreSynchronizedText() {
            isRestoringText = true
            editor?.string = synchronizedText
            editor?.undoManager?.removeAllActions()
            isRestoringText = false
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { isApplyingEdit = false; return }
            // Reconcile any native change not reported by the text storage delegate.
            isApplyingEdit = true
            defer { isApplyingEdit = false }
            let current = editor.string
            guard current != synchronizedText else { return }
            if synchronize(current) {
                synchronizedText = current
            } else {
                // A locked result must not display an edit that the application refused.
                restoreSynchronizedText()
            }
        }
    }
}
