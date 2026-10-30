import SwiftUI
import WorkbenchCore

/// Queue navigation retains the same repair owners used by recording history.
/// Opening a material does not resume work or change its submitted target.
@MainActor struct TranscriptRepairQueueSection: View {
    @ObservedObject var repair: TranscriptRepairSession
    @ObservedObject var recordings: RecordingSession
    let configuration: AudioServiceConfiguration
    let open: (UUID) -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    var body: some View {
        ForEach(recordings.recordings.filter { recording in repair.tasks.contains { $0.recordingID == recording.id } }) { recording in
            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("原文补齐", "Original text repair")).font(.headline)
                Button(recording.name) { open(recording.id) }
                TranscriptRepairView(repair: repair, recordingID: recording.id, result: nil,
                    configuration: configuration, recordingIsActive: recordings.activeID == recording.id)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
        }
    }
}

@MainActor struct BilingualRepairQueueSection: View {
    @ObservedObject var repair: BilingualRepairSession
    @ObservedObject var recordings: RecordingSession
    let open: (UUID) -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private var sources: [BilingualResult] {
        var seen = Set<UUID>()
        return repair.tasks.compactMap { seen.insert($0.source.id).inserted ? $0.source : nil }
    }
    var body: some View {
        ForEach(sources) { source in
            if let task = repair.tasks.first(where: { $0.source.id == source.id }),
               let recording = recordings.recordings.first(where: { $0.id == source.recordingID }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("双语补齐", "Bilingual repair")).font(.headline)
                    Button(recording.name) { open(recording.id) }
                    BilingualRepairView(session: repair, source: source, configuration: task.configuration)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }
        }
    }
}
