import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias BilingualRepairState<Value> = SwiftUI.State<Value>

@MainActor struct BilingualRepairView: View {
    @ObservedObject var session: BilingualRepairSession
    let source: BilingualResult
    let configuration: AudioServiceConfiguration
    var refreshHistory: () -> Void = {}
    @AppStorage("interfaceLanguage") private var preference = "system"
    @BilingualRepairState private var exportFailed = false
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("补齐缺失双语", "Repair missing bilingual text")).font(.headline)
            Text(configuration.provider.title(language) + " · " + configuration.model).font(.caption)
            if configuration == GeminiFileRepairConfiguration.configuration {
                Text(t("主动提交会上传所列缺口，可能产生服务费用。", "Explicit submission uploads the listed missing ranges and may incur service charges."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !session.supports(configuration: configuration, direction: source.direction) {
                Text(t("此音频服务尚未验证当前方向的双语补齐能力。已保留原文、译文和各自缺失区间；不会改用文本翻译服务。", "This audio service has not passed bilingual repair verification for this direction. Source, translation and their missing ranges are retained. No text translation service is substituted.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(t("另存补齐结果", "Repair into a new result")) {
                _ = session.submit(recordingID: source.recordingID, sourceResultID: source.id, configuration: configuration)
            }.disabled(!session.supports(configuration: configuration, direction: source.direction) || session.occupiesMaterial(source.recordingID))
            Text(t("只处理明确缺失的通道和区间。补齐片段按范围附在该通道末尾，不猜测句子配对或覆盖用户修改。", "Only missing channels and ranges are processed. Repaired ranges are appended within their channel, without guessing sentence matches or replacing edits.")).font(.caption).foregroundStyle(.secondary)
            ForEach(session.tasks.filter { $0.recordingID == source.recordingID && $0.source.id == source.id }) { task in
                VStack(alignment: .leading, spacing: 6) {
                    Text((session.authorizingID == task.id && task.status == .running ? t("等待钥匙串授权", "Waiting for Keychain authorization") : status(task.status)) + " · \(task.completedCount)/\(task.parts.count)")
                    Text(task.configuration.provider.title(language) + " · " + task.configuration.model).font(.caption)
                    if let failure = task.failure {
                        Text(failureMessage(failure)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(task.remainingParts) { part in
                        Text((part.channel == .source ? t("原文 ", "Source ") : t("译文 ", "Translation ")) + String(format: "%.1f–%.1f s", part.interval.start, part.interval.end)).font(.caption).foregroundStyle(.orange)
                        if let failure = part.failure, failure != task.failure {
                            Text(failureMessage(failure)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if task.status == .awaitingLocalSave {
                        Text(t("待保存草稿可继续编辑、复制或导出。重试保存不会再次调用服务。", "You can edit, copy or export this pending draft. Retry save does not call the service again.")).font(.caption)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top) { pendingEditors(task.id, minimumWidth: 260) }
                            VStack(alignment: .leading) { pendingEditors(task.id, minimumWidth: 0) }
                        }
                        HStack {
                            Button(t("复制待保存双语", "Copy pending bilingual text")) {
                                guard let value = session.tasks.first(where: { $0.id == task.id }) else { return }
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value.result.document.exported(), forType: .string)
                            }
                            Button(t("导出待保存双语", "Export pending bilingual text")) { exportPending(task.id) }
                        }
                    }
                    if [.queued, .running, .awaitingResume].contains(task.status) { Button(t("取消补齐", "Cancel repair")) { session.cancel(task.id) } }
                    if [.failed, .cancelled, .awaitingResume].contains(task.status), !task.remainingParts.isEmpty {
                        Button(t("继续欠缺部分", "Resume missing parts")) { session.resume(task.id) }
                            .disabled(!session.supports(configuration: task.configuration, direction: task.source.direction) || session.runningID == task.id)
                    }
                }
            }
            if session.needsSave || session.tasks.contains(where: { $0.status == .awaitingLocalSave }) {
                Text(t("补齐内容待本地保存，重试不会调用服务。", "Repair content is awaiting local save. Retry makes no service call.")).foregroundStyle(.orange)
                Button(t("重试保存", "Retry save")) { session.retrySaving() }
            }
            if let error = session.error { Text(failureMessage(error)).font(.caption).foregroundStyle(.orange) }
            if exportFailed { Text(t("导出失败，待保存草稿仍保留。", "Export failed. The pending draft is retained.")).foregroundStyle(.orange) }
        }.onChange(of: session.tasks) { _, _ in refreshHistory() }
    }
    func failureMessage(_ failure: AudioProcessingError) -> String {
        switch failure {
        case .interrupted:
            return t("补齐已中断，音频和已完成片段已保留。手动继续只提交尚未完成的通道和区间，可能产生费用。", "Repair was interrupted. Audio and completed ranges are retained. Manual resume submits only unfinished channels and ranges and may incur charges.")
        case .processing:
            return t("补齐失败或返回无效内容。音频和已完成片段已保留，可手动继续欠缺部分。", "Repair failed or returned invalid content. Audio and completed ranges are retained; you can resume missing parts manually.")
        default: return failure.localizedDescription
        }
    }
    @ViewBuilder private func pendingEditors(_ id: UUID, minimumWidth: CGFloat) -> some View {
        ForEach(BilingualChannel.allCases, id: \.self) { channel in
            VStack(alignment: .leading) {
                Text(channel == .source ? t("原文", "Source") : t("译文", "Translation"))
                TextEditor(text: Binding(get: { session.tasks.first(where: { $0.id == id })?.result.document.text(channel) ?? "" },
                    set: { session.editPending(id, text: $0, channel: channel) }))
                    .font(.body).frame(height: 180)
                    .accessibilityLabel(channel == .source ? t("待保存补齐原文", "Pending repaired source") : t("待保存补齐译文", "Pending repaired translation"))
            }.frame(minWidth: minimumWidth, maxWidth: .infinity)
        }
    }
    private func exportPending(_ id: UUID) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = ExportFilename.record(bilingual: true, extension: "txt")
        guard panel.runModal() == .OK, let url = panel.url, let task = session.tasks.first(where: { $0.id == id }) else { return }
        do { try task.result.document.exported().write(to: url, atomically: true, encoding: .utf8); exportFailed = false }
        catch { exportFailed = true }
    }
    private func status(_ status: BilingualRepairTask.Status) -> String {
        switch status {
        case .queued: return t("排队中", "Queued")
        case .running: return t("正在补齐", "Repairing")
        case .awaitingResume: return t("等待手动恢复", "Awaiting manual resume")
        case .awaitingLocalSave: return t("等待本地保存", "Awaiting local save")
        case .completed: return t("双语补齐完成", "Bilingual repair completed")
        case .failed: return t("仍有未完成内容", "Incomplete")
        case .cancelled: return t("已取消，已完成片段保留", "Cancelled; completed ranges retained")
        }
    }
}
