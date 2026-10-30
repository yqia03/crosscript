import SwiftUI
import WorkbenchCore

extension MaterialDeletionError {
    func description(_ language: AppLanguage) -> String {
        switch self {
        case .busy: return language.text("此资料有活动操作，请完成后再删除。", "This material has an active operation. Finish it before deleting.")
        case .unsavedChanges: return language.text("此资料有未保存内容，请重试本地保存后再删除。", "This material has unsaved content. Retry its local save before deleting.")
        case .staleConfirmation: return language.text("资料或结果已变化。请取消并重新选择删除范围。", "The material or result changed. Cancel and choose the deletion scope again.")
        case .storage: return language.text("删除未完成，内容仍保留。请重试或取消。", "Deletion did not finish. Content is retained; retry or cancel.")
        case .unavailable: return language.text("无法读取此资料，请重新打开后重试。", "This material cannot be read. Reopen it and try again.")
        }
    }
}

@MainActor struct MaterialDeletionConfirmationView: View {
    @ObservedObject var processing: PostRecordingSession
    let confirmation: MaterialDeletionConfirmation
    var beforeDelete: () -> Void = {}
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var deletesResult: Bool { confirmation.result != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(deletesResult ? t("删除这份转写结果？", "Delete this transcript result?") : t("删除整份资料？", "Delete the entire material?"))
                .font(.title2.weight(.semibold))
            Text(confirmation.recordingName).font(.headline).textSelection(.enabled)
            if let result = confirmation.result {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("结果 \(confirmation.resultNumber ?? 1) · ", "Result \(confirmation.resultNumber ?? 1) · ") + result.createdAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(Locale(identifier: language.isChinese ? "zh_Hans" : "en"))))
                    Text(result.configuration.provider.title(language) + " · " + result.model)
                    Text(result.configuration.baseURL)
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(t("只删除上述结果，包括其文字、用户编辑和时间信息。原始音频与其他 \(max(0, confirmation.resultCount - 1)) 份结果保留，可继续回放或重新转写。", "Deletes only the result above, including its text, edits and timing. Original audio and the other \(max(0, confirmation.resultCount - 1)) results remain available for playback or transcription."))
            } else {
                Text(confirmation.isImported
                     ? t("将 App 保管的导入音频副本及全部 \(confirmation.resultCount) 份关联结果（含用户编辑和时间信息）移到系统废纸篓。", "Moves the imported audio copy managed by this app and all \(confirmation.resultCount) associated results, including edits and timing, to the system Trash.")
                     : t("将 App 保管的原始录音及全部 \(confirmation.resultCount) 份关联结果（含用户编辑和时间信息）移到系统废纸篓。", "Moves the original recording managed by this app and all \(confirmation.resultCount) associated results, including edits and timing, to the system Trash."))
                Text(t("仅删除 App 管理内容；导入前的外部原文件不受影响。", "Only app-managed content is deleted. External files used for import are unchanged."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(deletesResult
                 ? t("此结果删除后不能撤销。取消会保留所有内容。", "Deleting this result cannot be undone. Cancel keeps all content.")
                 : t("可从系统废纸篓恢复这些文件。取消会保留所有内容。", "These files can be recovered from the system Trash. Cancel keeps all content."))
                .font(.callout).foregroundStyle(.secondary)
            if let error = processing.deletionError {
                Text(error.description(language)).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button(t("取消", "Cancel")) { processing.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    beforeDelete()
                    processing.confirmDeletion()
                } label: { Text(deletesResult ? t("删除此结果", "Delete this result") : t("删除整份资料", "Delete entire material")) }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }.fixedSize(horizontal: false, vertical: true).padding(26).frame(width: 460)
    }
}
