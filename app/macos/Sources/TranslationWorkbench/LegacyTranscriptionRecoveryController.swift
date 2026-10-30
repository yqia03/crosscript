import SwiftUI
import WorkbenchCore

@MainActor final class LegacyTranscriptionRecoveryController: ObservableObject {
    @Published private(set) var needsRetry = false
    private let drafts: LegacyTranscriptionRecovery
    private let recordings: RecordingSession
    private let processing: PostRecordingSession
    init(drafts: LegacyTranscriptionRecovery, recordings: RecordingSession, processing: PostRecordingSession) {
        self.drafts = drafts; self.recordings = recordings; self.processing = processing
        retry()
    }
    func retry() { needsRetry = !drafts.recover(recordings: recordings, processing: processing) }
}

@MainActor struct LegacyTranscriptionRecoveryBanner: View {
    @ObservedObject var recovery: LegacyTranscriptionRecoveryController
    @AppStorage("interfaceLanguage") private var preference = "system"
    var body: some View {
        if recovery.needsRetry {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLanguage(preference: preference).text("部分旧转写草稿尚未完成本地恢复。音频和原草稿保留，请检查磁盘和权限后重试。", "Some legacy transcription drafts still need local recovery. Audio and draft copies are retained. Check storage and permissions, then retry."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppLanguage(preference: preference).text("重试本地恢复", "Retry local recovery")) { recovery.retry() }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
        }
    }
}
