import SwiftUI
import WorkbenchCore

/// Reused by the saved-result view; ranges are recording media times, not text
/// indexes, and remain meaningful after the user edits the transcript.
struct MissingIntervalsView: View {
    let intervals: [MissingInterval]
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        if !intervals.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(t("文字待补齐 · 原始音频仍保留", "Missing text · Original audio retained"), systemImage: "text.badge.minus")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                ForEach(intervals) { interval in
                    Text("\(time(interval.start)) – \(time(interval.end))").font(.caption.monospacedDigit()).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func time(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1000).rounded()))
        let seconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d.%03d", seconds / 3600, seconds / 60 % 60, seconds % 60, milliseconds % 1000)
    }
}
