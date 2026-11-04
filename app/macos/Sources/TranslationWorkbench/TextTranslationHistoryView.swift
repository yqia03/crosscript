import AppKit
import SwiftUI
import WorkbenchCore

/// Both history entry points show the same immutable submission snapshots.
@MainActor struct TextTranslationHistoryList: View {
    @ObservedObject var session: TextTranslationSession
    var restored: () -> Void = {}
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("还没有文本翻译历史", "No text translations yet")).font(.headline)
                    Text(t("每次按回车或点击翻译后，都会独立保留原文与译文。", "Each translation submitted with Enter or Translate is kept with its source and result."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                    .modifier(HistoryGeometryObservation(name: "text.empty"))
            }
            ForEach(session.history) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) { metadata(entry); Spacer(minLength: 12); actions(entry) }
                        VStack(alignment: .leading, spacing: 10) { metadata(entry); actions(entry) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(t("原文", "Source")).font(.caption2).foregroundStyle(.secondary)
                        Text(entry.input).font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(t("译文", "Translation")).font(.caption2).foregroundStyle(.secondary)
                        Text(entry.translation.isEmpty ? t("暂无译文", "No translation received") : entry.translation)
                            .font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                    .modifier(HistoryGeometryObservation(name: "text." + entry.id.uuidString))
            }
        }.historyScrollGutter()
    }
    private func metadata(_ entry: TextTranslationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.result.direction.title(language) + " · " + (entry.isMarkdown ? "Markdown" : t("文本", "Text")))
                .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.result.provider.name + " · " + entry.result.provider.model)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if entry.result.status != .completed { Text(status(entry.result.status)).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func actions(_ entry: TextTranslationHistoryEntry) -> some View {
        HStack(spacing: 8) {
            TextActionMenu(label: t("复制历史内容", "Copy history contents"), symbol: "doc.on.doc", actions: [
                .init(title: t("复制原文", "Copy source"), perform: { copy(entry.input) }),
                .init(title: t("复制译文", "Copy translation"), enabled: !entry.translation.isEmpty, perform: { copy(entry.translation) })
            ]).frame(width: 34, height: 34)
                .modifier(HistoryGeometryObservation(name: "copy." + entry.id.uuidString))
            Button {
                if session.openHistory(entry.id) { restored() }
            } label: { Label(t("打开", "Open"), systemImage: "arrow.up.forward") }
                .buttonStyle(WorkbenchCompactButtonStyle()).disabled(session.isRunning || session.hasPendingSave)
                .modifier(HistoryGeometryObservation(name: "open." + entry.id.uuidString))
                .help(t("恢复到工作区；不会自动翻译或修改历史", "Restore to the workspace without translating or changing history"))
        }
    }
    private func status(_ value: TextTranslationStatus) -> String {
        switch value {
        case .generating: return t("正在翻译", "Translating")
        case .completed: return t("已完成", "Completed")
        case .failed: return t("翻译失败 · 已保留收到的内容", "Translation failed · Received content retained")
        case .stopped: return t("已停止 · 已保留收到的内容", "Stopped · Received content retained")
        case .interrupted: return t("已中断 · 已保留收到的内容", "Interrupted · Received content retained")
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

@MainActor struct TextTranslationHistoryView: View {
    @ObservedObject var session: TextTranslationSession
    var restored: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: languageChoice).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("文本历史记录", "Text translation history")).font(.title2)
                Spacer(minLength: 12)
                Button(t("完成", "Done")) { dismiss() }.buttonStyle(WorkbenchCompactButtonStyle()).keyboardShortcut(.cancelAction)
            }
            ScrollView { TextTranslationHistoryList(session: session, restored: restored).padding(2) }
        }.padding(24).frame(minWidth: 460, idealWidth: 700, minHeight: 420, idealHeight: 640)
    }
}
