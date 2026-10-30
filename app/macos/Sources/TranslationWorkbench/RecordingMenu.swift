import AppKit
import SwiftUI
import WorkbenchCore

extension Notification.Name {
    static let showCurrentRecording = Notification.Name("dev.uown.show-current-recording")
}

@MainActor
struct RecordingMenu: View {
    @ObservedObject var session: RecordingSession
    let playback: PlaybackController
    var bilingualLive: LiveBilingualSession? = nil
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @Environment(\.openWindow) private var openWindow

    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func text(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    private var recordingActions: RecordingActions { .init(recordings: session, bilingual: bilingualLive) }

    var body: some View {
        Text(session.activityTitle(using: language))
        if let recording = session.activeRecording {
            Text(recording.name)
            Text(recording.source.title(using: WorkbenchLanguage(choice: language)))
            RecordingClockView(telemetry: session.telemetry)
        }
        if session.lastError != nil {
            Text(text("操作未完成，请打开工作台查看详情。", "An action failed. Open the workbench for details."))
        }
        Divider()
        Button(text("打开工作台", "Open workbench")) {
            if let id = session.activeID { session.select(id) }
            openWindow(id: "workbench")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .showCurrentRecording, object: nil)
        }
        if session.hasActiveRecording {
            if !session.needsSaveRetry {
                Button(recordingActions.isFinishingPause ? text("暂停收尾中…", "Finishing pause…") : session.isPaused ? text("继续录音", "Resume recording") : text("暂停录音", "Pause recording")) {
                    Task { await recordingActions.togglePause() }
                }.disabled(!recordingActions.canTogglePause)
            }
            Button(session.needsSaveRetry ? text("重试保存", "Retry save") : text("停止并保存", "Stop and save")) {
                Task { await recordingActions.stop() }
            }.disabled(session.isBusy)
        } else {
            Button(text("开始录音", "Start recording")) {
                playback.stop()
                Task { await session.start() }
            }.disabled(!recordingActions.canStart)
        }
        Divider()
        Button(text("退出翻译工作台…", "Quit Translation Workbench…")) { NSApp.terminate(nil) }
    }
}

/// Holds power assertions only during capture. ScreenCaptureKit's display-based
/// audio filters also need protection from idle display sleep. Explicit sleep
/// remains an interruption; these assertions never restart a stopped stream.
@MainActor
final class RecordingActivity {
    private var token: NSObjectProtocol?

    func setActive(_ source: AudioSource?) {
        if let source, token == nil {
            var options: ProcessInfo.ActivityOptions = [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled]
            if !source.isMicrophone { options.insert(.idleDisplaySleepDisabled) }
            token = ProcessInfo.processInfo.beginActivity(
                options: options,
                reason: "Saving an active audio recording")
        } else if source == nil, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
