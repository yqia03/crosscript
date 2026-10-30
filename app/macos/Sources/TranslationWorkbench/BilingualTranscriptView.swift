import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore
private typealias BilingualViewState<Value> = SwiftUI.State<Value>

/// Both layouts observe the same state; neither view owns audio or a transport.
@MainActor struct BilingualTranscriptView: View {
    @ObservedObject var state: BilingualSessionState
    @ObservedObject var recordings: RecordingSession
    let configuration: AudioServiceConfiguration
    let openSettings: () -> Void
    let openCaptions: () -> Void
    var live: LiveBilingualSession? = nil
    var beforeStart: () -> Void = {}
    var canStartRecording = true
    var readerHeight: CGFloat = 300
    var fillsAvailableHeight = false
    var renameRecording: ((Recording) -> Void)? = nil
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @BilingualViewState private var exportFailed = false
    @BilingualViewState private var availableWidth: CGFloat = 1_000
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let live {
                BilingualLiveControls(live: live, recordings: recordings, configuration: configuration,
                    openSettings: openSettings, beforeStart: beforeStart, canStartRecording: canStartRecording,
                    renameRecording: renameRecording, availableWidth: availableWidth)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("同声传译", "Live translation")).font(.system(size: 28, weight: .semibold, design: .rounded))
                    BilingualStatusView(state: state, localStatus: recordings.activityTitle(using: language), showsCompleteness: false,
                        compact: availableWidth < 500)
                    if state.result == nil {
                        Text(t("所选服务暂不能开始同声传译，请检查服务设置。", "Live translation is unavailable for this service. Check service settings."))
                            .foregroundStyle(.secondary).font(.caption)
                        Button(t("服务设置", "Service settings"), action: openSettings)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                let toolsLayout = availableWidth >= 690
                    ? AnyLayout(HStackLayout(spacing: 12))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                toolsLayout {
                    BilingualCaptionControls(state: state, compact: availableWidth < 350)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) { readingButtons }
                }
                if let completeness = BilingualStatusView(state: state, localStatus: "").completenessTitle {
                    Label(completeness, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("bilingual-completeness-status")
                }
                // Keep each native reader alive through streaming and resizing.
                // Size-fitting alternatives repeatedly instantiate TextKit views.
                let columnsLayout = availableWidth >= 650
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                columnsLayout { columns }
                    .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .leading).glassCard()
            if state.needsSaveRetry {
                Text(t("双语文字尚未保存，可复制或另存。重试不会重新调用服务。", "Bilingual text is awaiting local save. Copy or export is available; retry does not call a service.")).foregroundStyle(.orange)
                Button(t("重试保存", "Retry save")) { if let live { live.retrySave() } else { state.retrySave() } }
            }
            if exportFailed { Text(t("导出失败，原结果仍保留。", "Export failed. The original result is retained.")).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .leading)
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                    if width > 0 { availableWidth = width }
                }
            })
    }
    @ViewBuilder private var columns: some View {
        ForEach(BilingualChannel.allCases.filter(state.visibleChannels.contains), id: \.self) { channel in
            VStack(alignment: .leading, spacing: 8) {
                Text(channel == .source ? t("原文", "Source") : t("译文", "Translation")).font(.headline)
                Group {
                    if state.needsSaveRetry {
                        TextEditor(text: Binding(get: { state.document.text(channel) },
                            set: { state.editPending($0, channel: channel) }))
                            .font(.system(size: min(48, max(14, state.fontSize.isFinite ? state.fontSize : 24))))
                            .accessibilityLabel(channel == .source ? t("待保存原文编辑", "Edit unsaved source") : t("待保存译文编辑", "Edit unsaved translation"))
                    } else {
                        LiveTranscriptReader(text: state.document.text(channel), followsLatest: state.followsLatest,
                            label: channel == .source ? t("实时原文", "Live source text") : t("实时译文", "Live translated text"),
                            fontSize: state.fontSize, onReview: { state.reviewEarlierText() })
                    }
                }.frame(minHeight: fillsAvailableHeight ? 60 : max(220, readerHeight),
                        maxHeight: fillsAvailableHeight ? .infinity : max(220, readerHeight))
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if state.document.text(channel).isEmpty {
                            Text(emptyMessage(channel)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(18).allowsHitTesting(false)
                        }
                    }
                let missing = channel == .source ? state.document.source.missingIntervals : state.document.translation.missingIntervals
                if !missing.isEmpty {
                    Menu(t("待补齐 \(missing.count) 段", "\(missing.count) missing ranges")) {
                        ForEach(missing) { interval in
                            Text(t(String(format: "缺失区间 %.1f–%.1f 秒", interval.start, interval.end), String(format: "Missing range %.1f–%.1f s", interval.start, interval.end)))
                        }
                    }.font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .leading)
        }
    }
    @ViewBuilder private var readingButtons: some View {
        Button(action: openCaptions) { Label(t("字幕窗", "Captions"), systemImage: "captions.bubble") }
            .buttonStyle(WorkbenchCompactButtonStyle())
        if !state.followsLatest {
            Button { state.returnToLatest() } label: { Label(t("回到最新", "Latest"), systemImage: "arrow.down.to.line") }
                .buttonStyle(WorkbenchCompactButtonStyle())
        }
        Menu { exportButtons } label: { Label(t("复制与导出", "Copy and export"), systemImage: "square.and.arrow.up") }
            .fixedSize().disabled(!hasVisibleText && state.document.source.text.isEmpty && state.document.translation.text.isEmpty)
    }
    private var hasVisibleText: Bool {
        state.visibleChannels.contains { !state.document.text($0).isEmpty }
    }
    private func emptyMessage(_ channel: BilingualChannel) -> String {
        if state.result == nil { return channel == .source ? t("开始后，原文会显示在这里。", "Source text appears here after starting.") : t("译文会独立显示在这里。", "Translation appears here independently.") }
        if state.document.isFinished { return channel == .source ? t("此结果尚无原文。已保存的录音仍保留。", "This result has no source text. Saved audio is retained.") : t("此结果尚无译文。可在历史中查看缺口与补齐操作。", "This result has no translation. Check History for gaps and repair options.") }
        return channel == .source ? t("等待原文…", "Waiting for source text…") : t("等待译文…", "Waiting for translation…")
    }
    @ViewBuilder private var exportButtons: some View {
        Button(t("复制显示文字", "Copy visible text")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(state.document.exported(channels: state.visibleChannels), forType: .string)
        }.disabled(!hasVisibleText)
        Button(t("另存双语文本", "Save bilingual text")) {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = ExportFilename.record(bilingual: true, extension: "txt")
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do { try state.document.exported().write(to: destination, atomically: true, encoding: .utf8); exportFailed = false }
            catch { exportFailed = true }
        }.disabled(state.document.source.text.isEmpty && state.document.translation.text.isEmpty)
    }
}

@MainActor struct BilingualCaptionView: View {
    @ObservedObject var state: BilingualSessionState
    @ObservedObject var recordings: RecordingSession
    var live: LiveBilingualSession? = nil
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @BilingualViewState private var availableWidth: CGFloat = 720
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BilingualStatusView(state: state, localStatus: recordings.activityTitle(using: language), compact: availableWidth < 500)
            BilingualCaptionControls(state: state, compact: availableWidth < 350)
            ForEach(BilingualChannel.allCases.filter(state.visibleChannels.contains), id: \.self) { channel in
                Text(channel == .source ? language.text("原文", "Source") : language.text("译文", "Translation"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LiveTranscriptReader(text: state.document.text(channel), followsLatest: state.followsLatest,
                    label: channel == .source ? language.text("字幕原文", "Caption source") : language.text("字幕译文", "Caption translation"),
                    fontSize: state.fontSize, onReview: { state.reviewEarlierText() })
                    .frame(minHeight: 60)
            }
            let actionsLayout = availableWidth >= 600
                ? AnyLayout(HStackLayout(spacing: 8))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            actionsLayout { captionActions }
        }.padding(14).frame(minWidth: 320, minHeight: 220)
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                    if width > 0 { availableWidth = width }
                }
            })
    }
    @ViewBuilder private var captionActions: some View {
        if !state.followsLatest {
            Button { state.returnToLatest() } label: { Label(language.text("回到最新", "Latest"), systemImage: "arrow.down.to.line") }
                .buttonStyle(WorkbenchCompactButtonStyle())
        }
        if let live, live.isActive { BilingualSessionButtons(live: live, recordings: recordings) }
    }
}
@MainActor private struct BilingualCaptionControls: View {
    @ObservedObject var state: BilingualSessionState
    var compact = false
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout { controls }
    }
    @ViewBuilder private var controls: some View {
        Stepper(language.text("字号", "Text size") + " \(Int(min(48, max(14, state.fontSize.isFinite ? state.fontSize : 24))))", value: $state.fontSize, in: 14...48, step: 2)
            .frame(maxWidth: 130).monospacedDigit()
            .accessibilityValue("\(Int(min(48, max(14, state.fontSize.isFinite ? state.fontSize : 24))))")
        ForEach(BilingualChannel.allCases, id: \.self) { channel in
            Toggle(channel == .source ? language.text("原文", "Source") : language.text("译文", "Translation"),
                isOn: Binding(get: { state.visibleChannels.contains(channel) }, set: { show in
                    if show { state.visibleChannels.insert(channel) }
                    else if state.visibleChannels.count > 1 { state.visibleChannels.remove(channel) }
                })).toggleStyle(.checkbox)
        }
    }
}
@MainActor struct BilingualStatusView: View {
    @ObservedObject var state: BilingualSessionState
    let localStatus: String
    var showsCompleteness = true
    var compact = false
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(spacing: 10))
            layout { statusItems }
            if showsCompleteness, let completenessTitle {
                Label(completenessTitle, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bilingual-completeness-status")
            }
        }
    }
    @ViewBuilder private var statusItems: some View {
        Label(localStatus, systemImage: "record.circle").font(.caption)
        Text(cloudTitle).font(.caption).foregroundStyle(state.cloudState == .failed ? .orange : .secondary)
    }
    var completenessTitle: String? {
        let document = state.document
        let sourceCount = document.source.missingIntervals.count
        let translationCount = document.translation.missingIntervals.count
        let incomplete = document.isFinished && !document.isComplete
        guard incomplete || sourceCount > 0 || translationCount > 0 else { return nil }
        var parts: [String] = []
        if incomplete { parts.append(language.text("双语结果不完整", "Bilingual result incomplete")) }
        if sourceCount > 0 || translationCount > 0 {
            parts.append(language.text("待补齐：原文 \(sourceCount) 段 · 译文 \(translationCount) 段",
                                       "Gaps: source \(sourceCount) · translation \(translationCount)"))
        }
        return parts.joined(separator: " · ")
    }
    private var cloudTitle: String {
        switch state.cloudState {
        case .idle: return language.text("未连接", "Disconnected")
        case .connecting: return language.text("云端正在连接", "Cloud connecting")
        case .reconnecting: return language.text("云端正在重连", "Cloud reconnecting")
        case .connected: return language.text("云端已连接", "Cloud connected")
        case .finishing: return language.text("翻译正在结束", "Finishing translation")
        case .completed: return language.text("翻译已结束", "Translation ended")
        case .failed: return language.text("翻译已断开", "Translation disconnected")
        }
    }
}
