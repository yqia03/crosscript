import SwiftUI
import WorkbenchCore

@MainActor struct TranscriptRepairView: View {
    @ObservedObject var repair: TranscriptRepairSession
    let recordingID: UUID
    let result: TranscriptResult?
    let configuration: AudioServiceConfiguration
    let recordingIsActive: Bool
    var openSettings: () -> Void = {}
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result, !result.currentDocument.missingIntervals.isEmpty {
                Text(t("结束后手动补齐原文", "Repair missing original text after recording")).font(.headline)
                Text(t("仅处理此结果中记录的缺口，保存为同一录音的新结果，原结果和编辑仍保留。没有可靠文本位置时，补齐文字会附在末尾；有服务时间信息的段落可回听。", "Only this result's missing ranges are processed and saved as a new result for the same recording. Existing results and edits remain. Text is appended when its position is uncertain; provider-timed paragraphs support playback."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(configuration.provider.title(language) + " · " + configuration.model).font(.caption).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack { submitButton(result); Button(t("服务设置", "Service settings"), action: openSettings) }
                    VStack(alignment: .leading) { submitButton(result); Button(t("服务设置", "Service settings"), action: openSettings) }
                }
                if !configuration.supportsSegmentTimestamps { Text(t("请在音频服务设置中选择支持文件分段时间的模型。", "Choose a model supporting timed file transcription in Audio service settings.")).font(.caption).foregroundStyle(.orange) }
                if recordingIsActive { Text(t("停止录音后才可提交补齐。", "Stop recording before submitting a repair.")).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(repair.tasks.filter { $0.recordingID == recordingID }) { task in
                VStack(alignment: .leading, spacing: 7) {
                    Text(repair.authorizingID == task.id && task.status == .running ? t("等待钥匙串授权", "Waiting for Keychain authorization") : title(task.status)).font(.callout.weight(.medium))
                    Text(t("已补齐 \(task.completedCount)/\(task.intervals.count) 个区间", "Repaired \(task.completedCount)/\(task.intervals.count) ranges")).font(.caption)
                    Text(task.configuration.provider.title(language) + " · " + task.configuration.model).font(.caption).foregroundStyle(.secondary)
                    if let failure = task.failure { Text(failureText(failure)).font(.caption).foregroundStyle(.orange) }
                    if !task.remainingIntervals.isEmpty { MissingIntervalsView(intervals: task.remainingIntervals) }
                    switch task.status {
                    case .queued, .running: Button(t("取消补齐", "Cancel repair")) { repair.cancel(task.id) }
                    case .failed, .cancelled, .awaitingResume:
                        if !task.remainingIntervals.isEmpty { Button(t("仅补齐剩余区间", "Repair remaining ranges")) { repair.resume(task.id) }.disabled(repair.needsSave || recordingIsActive) }
                    case .awaitingLocalSave: Button(t("重试本地保存", "Retry local save")) { repair.retrySaving() }
                    case .completed: Text(t("已保存独立结果，可在结果选择器中查看、编辑和导出。", "A separate result is saved. Use the result selector to view, edit or export it.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            if repair.needsSave {
                Text(t("补齐记录尚未保存。已停止新增云端请求，原始音频和窗口内结果仍保留。", "Repair progress is not saved. New cloud requests have stopped; original audio and current results remain.")).font(.caption).foregroundStyle(.orange)
                Button(t("重试本地保存", "Retry local save")) { repair.retrySaving() }
            }
            if let error = repair.error { Text(failureText(error)).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func submitButton(_ result: TranscriptResult) -> some View {
        Button(t("补齐缺失原文", "Repair missing original text")) {
            _ = repair.submit(recordingID: recordingID, sourceResultID: result.id, configuration: configuration)
        }.buttonStyle(.borderedProminent).disabled(recordingIsActive || repair.needsSave || repair.occupiesMaterial(recordingID) || !configuration.supportsSegmentTimestamps)
    }
    private func failureText(_ error: AudioProcessingError) -> String {
        if error == .interrupted { return t("补齐中断，已成功的区间仍保留；手动恢复只提交剩余范围。", "Repair interrupted. Successful ranges remain; manual resume submits only remaining ranges.") }
        return error.localizedDescription
    }
    private func title(_ status: TranscriptRepairTask.Status) -> String {
        switch status {
        case .queued: return t("补齐排队中", "Repair queued")
        case .running: return t("正在补齐", "Repair in progress")
        case .awaitingResume: return t("待手动恢复", "Waiting for manual resume")
        case .awaitingLocalSave: return t("待本地保存", "Waiting for local save")
        case .completed: return t("缺口已补齐", "Missing ranges repaired")
        case .failed: return t("补齐未完整完成", "Repair incomplete")
        case .cancelled: return t("补齐已取消", "Repair cancelled")
        }
    }
}
