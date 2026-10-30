import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias BilingualHistoryState<Value> = SwiftUI.State<Value>

/// The parent keys this view by recordingID so an editor cannot move to another
/// material. Opening it does not start capture, repair or any service request.
@MainActor struct BilingualHistoryView: View {
    @StateObject private var history: BilingualHistorySession
    @ObservedObject var state: BilingualSessionState
    let openLive: () -> Void
    let recordingName: String
    let externalDeletionBlockReason: (UUID) -> MaterialDeletionError?
    var repair: BilingualRepairSession?
    var repairConfiguration: AudioServiceConfiguration?
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @BilingualHistoryState private var exportFailed = false
    init(recordingID: UUID, store: BilingualResultStore, state: BilingualSessionState,
         openLive: @escaping () -> Void, repair: BilingualRepairSession? = nil, repairConfiguration: AudioServiceConfiguration? = nil,
         recordingName: String = "", deletionBlockReason: @escaping (UUID) -> MaterialDeletionError? = { _ in .busy }) {
        _history = StateObject(wrappedValue: state.history(recordingID: recordingID, store: store))
        self.state = state; self.openLive = openLive
        self.repair = repair; self.repairConfiguration = repairConfiguration
        self.recordingName = recordingName; self.externalDeletionBlockReason = deletionBlockReason
    }
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.loadFailed {
                Text(t("无法读取双语历史，已有资料仍保留。", "Bilingual history could not be read. Existing material is retained.")).foregroundStyle(.orange)
                Button(t("重新读取", "Reload")) { history.reload() }
            }
            if !history.results.isEmpty {
                Text(t("双语历史", "Bilingual history")).font(.headline)
                Picker(t("独立结果", "Independent result"), selection: Binding(get: { history.selectedID }, set: { if let id = $0 { history.select(id) } })) {
                    ForEach(Array(history.results.enumerated()), id: \.element.id) { index, result in
                        Text(t("结果 \(index + 1)", "Result \(index + 1)") + " · " + result.createdAt.formatted()).tag(Optional(result.id))
                    }
                }.disabled(history.hasUnsavedChanges)
                if let selected = history.selected {
                    Text(selected.configuration.provider.title(language) + " · " + selected.configuration.model).font(.caption)
                    if !selected.document.isComplete { Text(t("双语未完整完成", "Bilingual result is incomplete")).foregroundStyle(.orange) }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) { editors(minimumWidth: 260) }
                        VStack(alignment: .leading) { editors(minimumWidth: 0) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { actions }
                        VStack(alignment: .leading) { actions }
                    }
                    if let repair, !selected.document.source.missingIntervals.isEmpty || !selected.document.translation.missingIntervals.isEmpty {
                        BilingualRepairView(session: repair, source: selected, configuration: repairConfiguration ?? selected.configuration, refreshHistory: { history.reload() })
                            .disabled(history.hasUnsavedChanges)
                    }
                    if history.saveFailed { Text(t("保存失败，编辑仍在此处，可复制、导出或重试。", "Save failed. Edits remain here for copy, export or retry.")).foregroundStyle(.orange) }
                    if history.hasUnsavedChanges { Text(t("切换结果前，请保存或放弃当前编辑。", "Save or discard edits before switching results.")).font(.caption) }
                    if exportFailed { Text(t("导出失败，文字仍保留。", "Export failed. Text is retained.")).foregroundStyle(.orange) }
                    if let error = history.deletionError, history.pendingDeletion == nil {
                        Text(error.description(language)).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }.onAppear { history.reload() }
            .sheet(item: Binding(get: { history.pendingDeletion }, set: { if $0 == nil { history.cancelDeletion() } })) { confirmation in
                deletionConfirmation(confirmation)
            }
    }
    @ViewBuilder private func editors(minimumWidth: CGFloat) -> some View {
        ForEach(BilingualChannel.allCases, id: \.self) { channel in
            VStack(alignment: .leading) {
                Text(channel == .source ? t("原文", "Source") : t("译文", "Translation"))
                TextEditor(text: channel == .source ? $history.sourceText : $history.translationText)
                    .font(.body).frame(height: 220)
                    .accessibilityLabel(channel == .source ? t("历史原文编辑", "Edit historical source") : t("历史译文编辑", "Edit historical translation"))
                let intervals = channel == .source ? history.selected?.document.source.missingIntervals : history.selected?.document.translation.missingIntervals
                ForEach(intervals ?? []) { interval in
                    Text(t(String(format: "缺失 %.1f–%.1f 秒", interval.start, interval.end), String(format: "Missing %.1f–%.1f s", interval.start, interval.end))).font(.caption).foregroundStyle(.orange)
                }
            }.frame(minWidth: minimumWidth, maxWidth: .infinity)
        }
    }
    @ViewBuilder private var actions: some View {
        Button(t("保存编辑", "Save edits")) {
            if let saved = history.save() {
                if state.result?.id == saved.id { state.reopen(saved) }
                history.reload()
            }
        }.disabled(!history.hasUnsavedChanges)
        Button(t("放弃编辑", "Discard edits")) { history.discardChanges(); history.reload() }.disabled(!history.hasUnsavedChanges)
        Button(t("复制双语", "Copy bilingual text")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(history.exported, forType: .string)
        }
        Button(t("导出双语", "Export bilingual text")) {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = ExportFilename.record(bilingual: true, extension: "txt")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try history.exported.write(to: url, atomically: true, encoding: .utf8); exportFailed = false }
            catch { exportFailed = true }
        }
        Button(t("在同传页阅读", "Open in interpretation")) {
            if let selected = history.selected { state.reopen(selected); openLive() }
        }.disabled(history.hasUnsavedChanges || !state.canReplaceResult)
        Button(t("删除此双语结果", "Delete this bilingual result"), role: .destructive) {
            _ = history.requestDeletion(recordingName: recordingName, blockingReason: deletionBlockReason)
        }.disabled(history.deletionBlockReason(deletionBlockReason) != nil)
    }
    private func deletionBlockReason() -> MaterialDeletionError? {
        if repair?.occupiesMaterial(history.recordingID) == true || state.hasUnsavedHistoryEdits(for: history.recordingID)
            || (state.result?.recordingID == history.recordingID && !state.canReplaceResult) { return .busy }
        return externalDeletionBlockReason(history.recordingID)
    }
    private func deletionConfirmation(_ confirmation: BilingualResultDeletionConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("删除这份双语结果？", "Delete this bilingual result?")).font(.title2.weight(.semibold))
            Text(confirmation.recordingName).font(.headline).textSelection(.enabled)
            Text(t("结果 \(confirmation.resultNumber) · ", "Result \(confirmation.resultNumber) · ") + confirmation.result.createdAt.formatted()).font(.caption)
            Text(confirmation.result.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            Text(confirmation.result.configuration.provider.title(language) + " · " + confirmation.result.configuration.model).font(.caption)
            Text(confirmation.result.configuration.baseURL).font(.caption).textSelection(.enabled)
            Text(t("只删除此结果的原文、译文及用户编辑。原始音频、普通转写和其他 \(confirmation.otherResultCount) 份双语结果继续保留。", "Deletes only this result's source, translation and edits. Original audio, ordinary transcripts and the other \(confirmation.otherResultCount) bilingual results are retained."))
                .fixedSize(horizontal: false, vertical: true)
            Text(t("此结果删除后不能撤销。取消保留所有内容。", "Deleting this result cannot be undone. Cancel keeps all content.")).font(.caption)
            if let error = history.deletionError { Text(error.description(language)).foregroundStyle(.orange) }
            HStack {
                Button(t("取消", "Cancel")) { history.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("删除此结果", "Delete this result"), role: .destructive) {
                    if let id = history.confirmDeletion(blockingReason: deletionBlockReason) {
                        state.resultWasDeleted(recordingID: history.recordingID, resultID: id)
                    }
                }.buttonStyle(.borderedProminent).tint(.red)
            }
        }.padding(24).frame(width: 460)
    }
}
