import SwiftUI
import WorkbenchCore

/// Shared by the recording sheet and the global history page. Selection only
/// navigates; capture and transcript result selection remain with their owners.
@MainActor struct RecordingHistoryList: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var processing: PostRecordingSession
    var workflow: RecordingWorkflow? = .transcription
    let open: (UUID) -> Void
    var rename: ((Recording) -> Void)? = nil
    var delete: ((UUID) -> Void)? = nil
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: WorkbenchLanguage { WorkbenchLanguage(choice: AppLanguage(preference: preference)) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var recordings: [Recording] { workflow.map { session.recordings(in: $0) } ?? session.recordings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if recordings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(t("还没有录音历史", "No recording history yet")).font(.headline)
                    Text(t("录制或导入的音频及其转写结果会保存在这里。", "Recorded or imported audio and its transcription results will appear here."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(36).glassCard()
                    .modifier(HistoryGeometryObservation(name: "recording.empty"))
            }
            ForEach(recordings) { recording in
                HStack(spacing: 12) {
                    Button { open(recording.id) } label: { row(recording) }
                        .buttonStyle(.plain)
                        .accessibilityLabel((recording.workflow == .liveTranslation ? t("打开同传：", "Open live translation: ") : t("打开转写：", "Open transcription: ")) + recording.name)
                        .help(t("打开录音与已有结果；不会上传音频", "Open audio and existing results without uploading"))
                    if let rename {
                        Button { rename(recording) } label: { Image(systemName: "pencil").padding(8) }
                            .buttonStyle(.borderless).help(t("修改名称", "Rename"))
                            .accessibilityLabel(t("修改名称：", "Rename: ") + recording.name)
                    }
                    if let delete {
                        Button(role: .destructive) { delete(recording.id) } label: { Image(systemName: "trash").padding(8) }
                            .buttonStyle(.borderless).help(t("删除整份资料…", "Delete entire material…"))
                            .accessibilityLabel(t("删除整份资料：", "Delete entire material: ") + recording.name)
                            .disabled(processing.deletionBlockReason(for: .material(recordingID: recording.id)) != nil)
                    }
                }.padding(18).glassCard()
                    .modifier(HistoryGeometryObservation(name: "recording." + recording.id.uuidString))
            }
        }.historyScrollGutter()
    }

    private func row(_ recording: Recording) -> some View {
        HStack(spacing: 15) {
            Image(systemName: recording.id == session.activeID ? "mic.fill" : recording.sourceSymbol)
                .font(.system(size: 20)).foregroundStyle(.tint)
                .frame(width: 43, height: 48).background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 6) {
                Text(recording.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                Text(language.date(recording.startedAt))
                Text(recording.sourceTitle(using: language)).lineLimit(2)
                Text(recording.workflow == .liveTranslation ? t("同声传译 · 双语记录", "Live translation · Bilingual record") :
                     t("录音转写 · \(processing.materials[recording.id]?.results.count ?? 0) 份结果", "Transcription · \(processing.materials[recording.id]?.results.count ?? 0) results"))
                RecordingClockView(telemetry: session.telemetry, fixedDuration: recording.id == session.activeID ? nil : recording.duration,
                    prefix: (recording.id == session.activeID && session.needsSaveRetry ? t("已停止，待保存", "Stopped · Save pending") : recording.statusTitle(using: language.choice)) + " · ")
                if let status = processing.statusTitle(for: recording.id, language: language.choice) { Text(status) }
                if processing.hasUnsavedTranscript(recordingID: recording.id) {
                    Text(t("结果待本地保存", "Result needs local save")).foregroundStyle(.orange)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

@MainActor struct RecordingHistoryView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var processing: PostRecordingSession
    let open: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("interfaceLanguage") private var preference = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: preference).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("录音历史记录", "Recording history")).font(.title2)
                Spacer(minLength: 12)
                Button(t("完成", "Done")) { dismiss() }.buttonStyle(WorkbenchCompactButtonStyle()).keyboardShortcut(.cancelAction)
            }
            ScrollView { RecordingHistoryList(session: session, processing: processing, open: open).padding(2) }
        }.padding(24).frame(minWidth: 460, idealWidth: 700, minHeight: 420, idealHeight: 640)
    }
}
