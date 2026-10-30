import SwiftUI
import WorkbenchCore

@MainActor final class BilingualDraftRecoveryController: ObservableObject {
    @Published private(set) var failedIDs: Set<UUID> = []
    private let drafts: BilingualDraftStore
    private let recordings: RecordingSession
    private let results: BilingualResultStore
    init(drafts: BilingualDraftStore, recordings: RecordingSession, results: BilingualResultStore) {
        self.drafts = drafts; self.recordings = recordings; self.results = results
        failedIDs = drafts.recover(recordings: recordings, results: results)
    }
    // Only retry the startup recovery set. A newer live draft may have stopped
    // capture while still receiving its tail or retaining unsaved user edits.
    func retry() { failedIDs = drafts.recover(recordings: recordings, results: results, including: failedIDs) }
}

@MainActor struct BilingualDraftRecoveryBanner: View {
    @ObservedObject var recovery: BilingualDraftRecoveryController
    @AppStorage("interfaceLanguage") private var language = "system"
    var body: some View {
        if !recovery.failedIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLanguage(preference: language).text("部分双语草稿尚未恢复到历史。原始录音和恢复副本保留，请检查磁盘与权限后重试。", "Some bilingual drafts could not be restored to History. Original audio and recovery copies are retained. Check storage and permissions, then retry."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppLanguage(preference: language).text("重试双语本地恢复", "Retry bilingual recovery")) { recovery.retry() }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
        }
    }
}
