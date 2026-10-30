import SwiftUI
import WorkbenchCore

private typealias BilingualControlState<Value> = SwiftUI.State<Value>

@MainActor struct BilingualLiveControls: View {
    @ObservedObject var live: LiveBilingualSession
    @ObservedObject var recordings: RecordingSession
    let configuration: AudioServiceConfiguration
    let openSettings: () -> Void
    let beforeStart: () -> Void
    let canStartRecording: Bool
    var renameRecording: ((Recording) -> Void)? = nil
    var availableWidth: CGFloat = 1_000
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @BilingualControlState private var direction: TextTranslationDirection = .englishToChinese
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = availableWidth >= 1_100
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout {
                heading.frame(maxWidth: .infinity, alignment: .leading)
                actions.frame(maxWidth: availableWidth >= 1_100 ? nil : .infinity, alignment: .trailing)
            }
            if live.isAwaitingCredentials {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(t("等待钥匙串授权，本地录音继续…", "Waiting for Keychain authorization; local recording continues…"))
                    Button(t("取消连接", "Cancel connection")) { live.cancelCloud() }.buttonStyle(.borderless)
                }.font(.caption)
            }
            if live.cloudError != nil {
                Text(failureDescription).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if live.checkpointNeedsSaveRetry {
                HStack {
                    Text(t("恢复副本待保存，当前文字仍保留。", "Recovery copy needs saving. Current text is retained."))
                    Button(t("重试保存", "Retry save")) { if live.isActive { live.checkpoint() } else { live.retrySave() } }
                }.font(.caption).foregroundStyle(.orange)
            }
            if !live.isActive && !LiveBilingualCapability.forConfiguration(configuration).canStart {
                Text(t("所选服务暂不能开始同声传译，请检查服务设置。", "Live interpretation is unavailable for this service. Check service settings."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .modifier(LiveToolbarGeometryObservation(name: "header"))
        .onAppear { if let result = live.presentation.result { direction = result.direction } }
        .onChange(of: live.presentation.result?.id) { _, _ in
            if !live.isActive, let result = live.presentation.result { direction = result.direction }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            let titleLayout = headingWidth >= 640
                ? AnyLayout(HStackLayout(spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            titleLayout { title; status }
            let metadataLayout = headingWidth >= 500
                ? AnyLayout(HStackLayout(spacing: 8))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            metadataLayout { metadata }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var headingWidth: CGFloat { availableWidth - (availableWidth >= 1_100 ? 600 : 0) }
    private var title: some View {
        Text(t("同声传译", "Live translation")).font(.system(size: 28, weight: .semibold, design: .rounded))
            .modifier(LiveToolbarGeometryObservation(name: "title"))
    }
    private var status: some View {
        BilingualStatusView(state: live.presentation, localStatus: recordings.activityTitle(using: language),
            showsCompleteness: false, compact: headingWidth < 500)
    }
    @ViewBuilder private var metadata: some View {
        if let recording = displayedRecording {
            if let renameRecording {
                Button { renameRecording(recording) } label: {
                    Label(recording.name, systemImage: "pencil").lineLimit(1)
                }.buttonStyle(.plain).help(t("修改录音名称", "Rename recording"))
                    .accessibilityLabel(t("修改录音名称：", "Rename recording: ") + recording.name)
            } else { Text(recording.name).lineLimit(1) }
        }
        if live.isActive {
            Text(directionTitle(live.snapshot?.direction ?? direction))
        } else {
            TranslationDirectionPicker(direction: $direction, catalog: .live, language: language)
                .frame(maxWidth: 340).disabled(!recordings.canCreateProject)
                .accessibilityLabel(t("翻译方向", "Translation direction"))
        }
    }
    private var displayedRecording: Recording? {
        if let active = recordings.activeRecording, live.isActive { return active }
        guard let id = live.presentation.result?.recordingID else {
            return recordings.selectedRecording?.workflow == .liveTranslation ? recordings.selectedRecording : nil
        }
        return recordings.recordings.first { $0.id == id }
    }
    private func directionTitle(_ value: TextTranslationDirection) -> String {
        value.title(language)
    }
    private var actions: some View {
        HStack(spacing: 8) {
            AudioSourceSelection(session: recordings, language: WorkbenchLanguage(choice: language), compact: true, toolbar: true)
                .fixedSize(horizontal: true, vertical: false)
            if live.isActive { BilingualSessionButtons(live: live, recordings: recordings).fixedSize() }
            else {
                Button {
                    guard canStartRecording else { return }
                    beforeStart()
                    Task { await live.start(configuration: configuration, direction: direction) }
                } label: { Label(t("开始同声传译", "Start live translation"), systemImage: "mic") }
                    .buttonStyle(WorkbenchCompactButtonStyle())
                    .fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                    .modifier(LiveToolbarGeometryObservation(name: "start"))
                    .disabled(!canStartRecording || !recordings.canCreateProject || !live.presentation.canReplaceResult
                              || live.checkpointNeedsSaveRetry || !LiveBilingualCapability.forConfiguration(configuration).canStart)
            }
            if live.canReconnect && !live.isAwaitingCredentials {
                Button { Task { await live.reconnect() } } label: { Label(t("重新连接", "Reconnect"), systemImage: "arrow.clockwise") }
                    .buttonStyle(WorkbenchCompactButtonStyle())
            }
            Menu {
                if live.isActive && (live.cloudState == .connected || live.cloudState == .connecting || live.cloudState == .reconnecting) {
                    Button(t("停止翻译，继续录音", "Stop translation; keep recording")) { live.cancelCloud() }
                    Divider()
                }
                Button(t("服务设置", "Service settings"), action: openSettings)
                if !live.isActive {
                    Text(t("开始会将音频发送到所选服务，并在本机保留录音。", "Starting sends audio to the selected service and keeps a local recording."))
                }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 34) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .modifier(LiveToolbarGeometryObservation(name: "more"))
                .help(t("更多操作", "More actions")).accessibilityLabel(t("更多操作", "More actions"))
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var failureDescription: String {
        switch live.cloudFailureReason {
        case .cancelled: return live.isActive
            ? t("翻译已停止，录音继续。", "Translation stopped; recording continues.")
            : t("翻译已停止。", "Translation stopped.")
        case .captureConversion: return t("实时音频处理失败，录音仍独立保存。", "Live audio processing failed. Recording is saved independently.")
        case .audioBacklog: return t("网络发送积压，翻译已停止。可重新连接当前讲话。", "Audio upload stalled. Reconnect to the current speech.")
        case .credentials: return t("无法读取 Gemini 密钥，请检查钥匙串及服务设置。", "The Gemini key is unavailable. Check Keychain and service settings.")
        case .responseTimeout: return t("等待服务响应超时，可重新连接。", "Service response timed out. Reconnect to continue.")
        case .uploadTimeout: return t("音频上传超时，可重新连接。", "Audio upload timed out. Reconnect to continue.")
        case .protocolFailure: return t("服务返回内容无法继续处理，可重新连接。", "The service response could not be processed. Reconnect to continue.")
        case .connection, .none: return t("连接不可用，请检查网络、服务权限和账户额度。", "Connection unavailable. Check the network, service access and quota.")
        }
    }
}

/// Main and caption windows route actions to the same owner, including pause drain guards.
@MainActor struct BilingualSessionButtons: View {
    @ObservedObject var live: LiveBilingualSession
    @ObservedObject var recordings: RecordingSession
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: languageChoice).text(zh, en) }
    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { if recordings.isPaused { await live.resume() } else { await live.pause() } }
            } label: {
                Label(live.isPausing ? t("暂停收尾中…", "Finishing pause…") : recordings.isPaused ? t("继续录音", "Resume") : t("暂停录音", "Pause"),
                      systemImage: recordings.isPaused ? "play.fill" : "pause.fill")
            }.disabled(live.isPausing || recordings.isBusy || !recordings.hasActiveRecording || recordings.needsSaveRetry || live.cloudState == .finishing)
            Button { Task { await live.stop() } } label: { Label(t("停止并保存", "Stop and save"), systemImage: "stop.fill") }
                .disabled(recordings.isBusy || live.cloudState == .finishing)
        }.buttonStyle(WorkbenchCompactButtonStyle())
    }
}

@MainActor struct BilingualActivityStrip: View {
    @ObservedObject var live: LiveBilingualSession
    let open: () -> Void
    @AppStorage("interfaceLanguage") private var language = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }
    var body: some View {
        if live.isActive || live.needsSaveRetry || live.checkpointNeedsSaveRetry {
            Button(action: open) {
                Label(title, systemImage: live.cloudState == .failed ? "cloud.slash" : "character.bubble")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).padding(12).glassCard()
        }
    }
    private var title: String {
        if live.needsSaveRetry || live.checkpointNeedsSaveRetry { return t("双语结果待保存 · 返回处理", "Bilingual result needs saving · Open") }
        switch live.cloudState {
        case .idle: return t("同声传译未连接", "Live interpretation disconnected")
        case .connecting: return t("同声传译正在连接", "Connecting live interpretation")
        case .reconnecting: return t("同声传译正在重连", "Reconnecting live interpretation")
        case .connected: return t("同声传译已连接 · 打开双语字幕", "Live interpretation connected · Open captions")
        case .finishing: return t("同声传译正在收尾", "Finishing live interpretation")
        case .failed: return t("双语服务不可用 · 本地录音状态独立", "Bilingual service unavailable · Local recording is independent")
        case .completed: return t("同声传译已结束", "Live interpretation ended")
        }
    }
}

// Optional observation of the production buttons for native layout regression tests.
// The normal path has no GeometryReader and does not change button layout.
struct LiveToolbarGeometryObserverKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var liveToolbarGeometryObserver: ((String, CGRect) -> Void)? {
        get { self[LiveToolbarGeometryObserverKey.self] }
        set { self[LiveToolbarGeometryObserverKey.self] = newValue }
    }
}
struct LiveToolbarGeometryObservation: ViewModifier {
    let name: String
    @Environment(\.liveToolbarGeometryObserver) private var observe
    func body(content: Content) -> some View {
        if let observe {
            content.background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in observe(name, frame) }
            })
        } else { content }
    }
}
