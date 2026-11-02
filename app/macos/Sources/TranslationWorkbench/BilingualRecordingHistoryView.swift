import SwiftUI
import WorkbenchCore

/// Current-recording detail; the global history remains the cross-recording index.
@MainActor struct BilingualRecordingHistoryView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var processing: PostRecordingSession
    @ObservedObject var bilingual: BilingualSessionState
    let playback: PlaybackController
    let bilingualStore: BilingualResultStore
    var bilingualRepair: BilingualRepairSession?
    let done: () -> Void
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: WorkbenchLanguage { WorkbenchLanguage(choice: AppLanguage(preference: languageChoice)) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("同声传译历史", "Live translation history")).font(.title2)
                Spacer()
                Button(t("完成", "Done")) { done() }.buttonStyle(WorkbenchCompactButtonStyle()).keyboardShortcut(.cancelAction)
                    .modifier(HistoryGeometryObservation(name: "live.done"))
            }
            ScrollView {
                if let recording = session.selectedRecording {
                    VStack(alignment: .leading, spacing: 14) {
                        recordingCard(recording)
                        BilingualHistoryView(recordingID: recording.id, store: bilingualStore, state: bilingual,
                            openLive: { done() }, repair: bilingualRepair,
                            repairConfiguration: GeminiFileRepairConfiguration.configuration, recordingName: recording.name,
                            deletionBlockReason: { id in processing.deletionBlockReason(for: .material(recordingID: id)) })
                            .id(recording.id)
                        if let legacy = processing.materials[recording.id], !legacy.results.isEmpty {
                            DisclosureGroup {
                                ForEach(legacy.results) { result in
                                    TranscriptEditorView(processing: processing, recording: recording, result: result, playFrom: { time in
                                        do { try playback.play(at: time, from: session.audioURL(for: recording.id)) }
                                        catch { /* PlaybackController publishes the error. */ }
                                    }).id(result.id)
                                }
                            } label: {
                                Text(t("旧版附带的转写结果", "Transcripts retained from earlier versions"))
                                    .modifier(HistoryGeometryObservation(name: "live.legacy.toggle"))
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                                .modifier(HistoryGeometryObservation(name: "live.legacy"))
                        }
                    }.modifier(HistoryGeometryObservation(name: "live.contents")).historyScrollGutter().padding(2)
                }
            }
        }.padding(24).frame(minWidth: 560, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }
    private func recordingCard(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: recording.sourceSymbol).font(.system(size: 20)).foregroundStyle(.tint)
                    .frame(width: 43, height: 48).background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(language.date(recording.startedAt)).font(.caption).foregroundStyle(.secondary)
                    Text(recording.sourceTitle(using: language)).font(.caption).foregroundStyle(.secondary)
                    Text(recording.statusTitle(using: language.choice)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            RecordingPlaybackControls(playback: playback, url: session.audioURL(for: recording.id),
                duration: recording.duration, language: language)
                .frame(maxWidth: .infinity)
                .modifier(HistoryGeometryObservation(name: "live.playback"))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            .modifier(HistoryGeometryObservation(name: "live.recording"))
    }
}
