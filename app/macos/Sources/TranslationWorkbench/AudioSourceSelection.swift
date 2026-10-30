import AppKit
import SwiftUI
import WorkbenchCore

private typealias SourceViewState<Value> = SwiftUI.State<Value>

extension AudioSource {
    var symbol: String {
        switch self {
        case .microphone, .microphoneDevice: return "mic"
        case .system: return "desktopcomputer"
        case .application: return "app.badge"
        }
    }

    func title(using language: WorkbenchLanguage) -> String {
        switch self {
        case .microphone: return language.text("麦克风 · 系统默认", "Microphone · System default")
        case .microphoneDevice(let device): return device.name
        case .system: return language.text("系统声音 · 整台电脑", "System audio · Entire Mac")
        case .application(let application): return language.text("应用声音 · ", "App audio · ") + application.name
        }
    }
}

@MainActor
struct AudioSourceSelection: View {
    @ObservedObject var session: RecordingSession
    @StateObject private var applicationList = AudioApplicationList()
    @StateObject private var microphoneList = MicrophoneDeviceList()
    let language: WorkbenchLanguage
    var compact = false
    var toolbar = false

    @SourceViewState<Bool> private var showsPermissionDetails = false
    @SourceViewState<Bool> private var showsSources = false
    private var displayedSource: AudioSource { session.activeRecording?.source ?? session.selectedSource }
    private var locked: Bool { session.isBusy || session.hasActiveRecording || session.isImporting }
    private var usesMicrophone: Bool { displayedSource.isMicrophone }
    private var selectedApplication: AudioApplication? {
        if case .application(let application) = displayedSource { return application }
        return nil
    }
    private var selectedApplicationUnavailable: Bool {
        selectedApplication.map { !applicationList.applications.contains($0) } ?? false
    }
    private var selectedMicrophoneUnavailable: Bool {
        guard case .microphoneDevice(let device) = displayedSource else { return false }
        return !microphoneList.devices.contains { $0.uid == device.uid }
    }
    private var sourceUnavailable: Bool { selectedApplicationUnavailable || selectedMicrophoneUnavailable }
    private var compactTitle: String {
        displayedSource.title(using: language) + (sourceUnavailable ? t("（不可用）", " (unavailable)") : "")
    }
    private func t(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }

    var body: some View {
        Group {
            if compact {
                if toolbar { compactButton.buttonStyle(WorkbenchCompactButtonStyle())
                    .modifier(LiveToolbarGeometryObservation(name: "source")) }
                else { compactButton.buttonStyle(.borderless) }
            } else { fullLayout }
        }
        .onAppear { refreshSources() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in microphoneList.refresh() }
        .onChange(of: locked) { _, locked in if locked { showsSources = false } }
    }

    private var compactButton: some View {
        Button { refreshSources(); showsSources = true } label: {
            HStack(spacing: 7) {
                Image(systemName: sourceUnavailable ? "exclamationmark.triangle" : displayedSource.symbol)
                Text(compactTitle).lineLimit(1).truncationMode(.middle)
                    // Leave room for both symbols, spacing, and button padding within 220 points.
                    .frame(maxWidth: toolbar ? 159 : nil, alignment: .leading)
                    .fixedSize(horizontal: toolbar, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.caption)
        }
        .disabled(locked)
        .popover(isPresented: $showsSources, arrowEdge: .bottom) { sourceMenu }
        .help(compactTitle)
        .accessibilityLabel(t("选择音源：", "Choose audio source: ") + compactTitle)
    }

    private func refreshSources() { applicationList.refresh(); microphoneList.refresh() }

    private func isSelected(_ source: AudioSource) -> Bool {
        if case .microphoneDevice(let candidate) = source,
           case .microphoneDevice(let selected) = displayedSource { return candidate.uid == selected.uid }
        return displayedSource == source
    }

    private var fullLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("音源", "AUDIO SOURCE"))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Button { refreshSources(); showsSources = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: displayedSource.symbol).font(.system(size: 18))
                        .frame(width: 36, height: 36).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(compactTitle).font(.system(size: 13, weight: .semibold))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text(usesMicrophone ? t("收录你身边的声音", "Capture sound around you") : t("仅收录所选范围的播放声音", "Capture playback from the selected source"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.85)))
            }.buttonStyle(.plain).disabled(locked)
                .popover(isPresented: $showsSources, arrowEdge: .bottom) { sourceMenu }
                .accessibilityLabel(t("选择音源：", "Choose audio source: ") + displayedSource.title(using: language))
            if let selectedApplication, !applicationList.applications.contains(selectedApplication) {
                Text(t("所选应用已不可用。请打开应用并在音源菜单中刷新后重新选择。", "The selected app is unavailable. Open it, refresh the source menu, and select it again."))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if selectedMicrophoneUnavailable {
                Text(t("所选麦克风不可用。请连接设备并刷新列表，或选择其他音源。", "The selected microphone is unavailable. Connect it and refresh, or choose another source."))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if locked {
                Text(t("本次音源已固定，停止并保存后可更改。", "This source is fixed until you stop and save."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup(t("权限与录音说明", "Permissions & recording"), isExpanded: $showsPermissionDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(usesMicrophone
                        ? t("点击开始录音时请求麦克风权限；系统声音不会混入。", "Microphone permission is requested when you start. System audio is not mixed in.")
                        : t("开始录音时需要「录屏与系统录音」权限；仅保存声音，不接收或保存屏幕画面。录制时防止自动熄屏，暂停或结束后释放。手动熄屏或睡眠会中断并保留已保存音频。", "Recording requires Screen & System Audio Recording permission. Only audio is captured. Automatic display sleep is prevented while recording; forcing display sleep or system sleep interrupts capture and retains saved audio."))
                    Button { openAudioPrivacySettings(for: displayedSource) } label: {
                        Label(t("打开音频权限设置", "Open audio permission settings"), systemImage: "arrow.up.right.square")
                    }.buttonStyle(.borderless)
                }.padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var sourceMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("选择音源", "Choose audio source")).font(.system(size: 12, weight: .semibold)).padding(8)
            Text(t("麦克风", "Microphones")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            sourceOption(.microphone)
            if let defaultName = microphoneList.devices.first(where: { $0.uid == microphoneList.defaultUID })?.name {
                Text(t("当前默认：", "Current default: ") + defaultName).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            if microphoneList.devices.isEmpty {
                Text(t("未发现可用输入设备", "No input devices available")).font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(microphoneList.devices) { device in sourceOption(.microphoneDevice(device)) }
                    }.padding(.trailing, 8)
                }.frame(height: min(160, CGFloat(microphoneList.devices.count) * 42))
            }
            if selectedMicrophoneUnavailable {
                Text(displayedSource.title(using: language) + t("（不可用）", " (unavailable)"))
                    .font(.caption).foregroundStyle(.orange).padding(8)
            }
            Divider().padding(.vertical, 4)
            sourceOption(.system)
            Divider().padding(.vertical, 4)
            Text(t("指定应用", "Selected app")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            if applicationList.applications.isEmpty {
                Text(t("请先打开要录制的应用", "Open the app you want to record first"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(applicationList.applications) { application in sourceOption(.application(application)) }
                    }.padding(.trailing, 16)
                }.frame(height: min(180, CGFloat(applicationList.applications.count) * 42))
            }
            Button(t("刷新音源列表", "Refresh audio sources"), systemImage: "arrow.clockwise") { refreshSources() }
                .buttonStyle(.borderless).font(.system(size: 12)).padding(8)
            if compact {
                Divider()
                if selectedApplicationUnavailable {
                    Text(t("所选应用已不可用。打开应用并刷新列表后重新选择。", "The selected app is unavailable. Open it, refresh this list, and select it again."))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(t("开始时请求所需音频权限；原始录音保存在本机。", "Audio permission is requested when starting. Original recordings are saved on this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(t("音频权限设置", "Audio permission settings")) { openAudioPrivacySettings(for: displayedSource) }
                    .buttonStyle(.borderless)
            }
        }.padding(10).frame(width: 310)
    }

    private func sourceOption(_ source: AudioSource) -> some View {
        Button { session.selectSource(source); showsSources = false } label: {
            HStack(spacing: 10) {
                Image(systemName: source.symbol).frame(width: 20)
                Text(source.title(using: language)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isSelected(source) { Image(systemName: "checkmark") }
            }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(isSelected(source) ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(locked)
    }

}

@MainActor
func openAudioPrivacySettings(for source: AudioSource = .system) {
    let pane = source.isMicrophone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
    NSWorkspace.shared.open(url)
}
