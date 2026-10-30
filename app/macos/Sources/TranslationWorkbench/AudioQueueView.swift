import SwiftUI
import WorkbenchCore

private typealias QueueViewState<Value> = SwiftUI.State<Value>

extension AudioBackgroundTask.Status {
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .queued: return language.text("排队中", "Queued")
        case .running: return language.text("正在转写", "Transcribing")
        case .completed: return language.text("结果已保存", "Result saved")
        case .failed: return language.text("失败 · 可手动重试", "Failed · Retry manually")
        case .cancelled: return language.text("已取消", "Cancelled")
        case .interrupted: return language.text("已中断 · 等待明确恢复", "Interrupted · Resume explicitly")
        case .awaitingResume: return language.text("排队任务 · 等待明确恢复", "Queued task · Resume explicitly")
        case .awaitingLocalSave: return language.text("结果等待本地保存", "Result awaiting local save")
        }
    }
}

@MainActor struct AudioQueueView: View {
    @ObservedObject var processing: PostRecordingSession
    var recordingID: UUID? = nil
    var openRecording: (UUID) -> Void = { _ in }
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @QueueViewState private var confirmation: AudioBackgroundTask?
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var tasks: [AudioBackgroundTask] {
        processing.backgroundTasks.filter { recordingID == nil || $0.recordingID == recordingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(t("音频后台任务", "Background audio tasks"), systemImage: "list.bullet.rectangle")
                .font(.headline)
            Text(t("同时处理一项，其余排队。录音和文本翻译独立可用。", "One task runs at a time. Recording and text translation remain independent."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !processing.isAudioQueueReadable {
                Text(t("队列文件无法读取，原文件已保留。请检查资料目录与权限后重新打开 App；其他历史结果仍可查看。", "The queue could not be read; its file is retained. Check the data directory and permissions, then reopen the app. Existing results remain available."))
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if processing.queueNeedsSave || processing.pendingSaveID != nil {
                Text(t("本地保存未完成，新的音频任务暂不开始。重试保存不会重新上传。", "Local saving is incomplete; new audio tasks are paused. Retrying the save does not upload again."))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(t("重试本地保存", "Retry local save")) { processing.retrySaving() }
            }
            if tasks.isEmpty { Text(t("暂无音频任务", "No audio tasks")).foregroundStyle(.secondary) }
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(processing.recordingName(for: task.recordingID) ?? t("资料已删除", "Material deleted"))
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 8)
                        Text(task.status.title(language)).font(.caption).multilineTextAlignment(.trailing)
                    }
                    Text(task.configuration.provider.title(language) + " · " + task.configuration.model)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(task.configuration.baseURL).font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if task.status == .running {
                        ProgressView().controlSize(.small)
                        Text(t("已处理 \(task.completedChunks) 个音频分块", "Processed \(task.completedChunks) audio chunks"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = task.failure {
                        Text(failure.localizedDescription).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions(task) }
                        VStack(alignment: .leading, spacing: 8) { actions(task) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $confirmation) { task in
            VStack(alignment: .leading, spacing: 16) {
                Text(t("确认恢复或重试音频处理", "Resume or retry audio processing")).font(.title2.bold())
                Text(processing.recordingName(for: task.recordingID) ?? t("资料已删除", "Material deleted"))
                Text(task.configuration.provider.title(language) + " · " + task.configuration.model)
                Text(task.configuration.baseURL).font(.caption).textSelection(.enabled)
                Text(t("将使用该任务提交时的服务与模型，重新从头处理整份音频；服务可能已处理此前请求，费用可能重复。旧结果与编辑继续保留。", "Uses this task's original service and model and processes the full audio from the beginning. The service may have processed the previous request, so charges can repeat. Existing results and edits are retained."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(t("取消", "Cancel")) { confirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(t("确认并排队", "Confirm and queue")) {
                        confirmation = nil
                        if task.status == .interrupted || task.status == .awaitingResume {
                            processing.resumeBackgroundTask(task.id)
                        } else { processing.retryBackgroundTask(task.id) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 460)
        }
    }

    @ViewBuilder private func actions(_ task: AudioBackgroundTask) -> some View {
        if recordingID == nil {
            Button(t("打开资料", "Open material")) { openRecording(task.recordingID) }
                .disabled(processing.recordingName(for: task.recordingID) == nil)
        }
        switch task.status {
        case .queued, .running:
            Button(t("取消任务", "Cancel task"), role: .cancel) { processing.cancelBackgroundTask(task.id) }
        case .interrupted, .awaitingResume:
            Button(t("恢复…", "Resume…")) { confirmation = task }.disabled(!processing.canEnqueueTranscription)
            Button(t("取消任务", "Cancel task")) { processing.cancelBackgroundTask(task.id) }
        case .failed, .cancelled:
            Button(t("重试…", "Retry…")) { confirmation = task }
                .disabled(!processing.canEnqueueTranscription || processing.recordingName(for: task.recordingID) == nil)
        case .awaitingLocalSave:
            Button(t("重试本地保存", "Retry local save")) { processing.retrySaving() }
        case .completed: EmptyView()
        }
    }
}
