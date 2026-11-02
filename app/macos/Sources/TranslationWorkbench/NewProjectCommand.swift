import AppKit
import SwiftUI
import WorkbenchCore

/// The active PDF workspace supplies its retained command. Other pages keep the
/// application's existing recording-project action.
@MainActor struct NewProjectCommand {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct NewProjectCommandKey: FocusedValueKey {
    typealias Value = NewProjectCommand
}

extension FocusedValues {
    var newProjectCommand: NewProjectCommand? {
        get { self[NewProjectCommandKey.self] }
        set { self[NewProjectCommandKey.self] = newValue }
    }
}

/// Focus changes belong to the menu subtree. Observing the PDF command on App
/// itself rebuilds its Window content, which publishes a fresh focused command
/// and can feed back into another scene update while entering the PDF page.
@MainActor struct WorkbenchProjectCommands: Commands {
    @ObservedObject var session: RecordingSession
    let playback: PlaybackController
    @ObservedObject var bilingualLive: LiveBilingualSession
    let language: AppLanguage
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newProjectCommand) private var contextualNewProject

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(uiText("新建项目", "New project")) {
                guard canCreateNewProject, hasNoModalPresentation else { return }
                if let contextualNewProject { contextualNewProject.perform(); return }
                playback.stop()
                session.activateWorkflow(.transcription)
                session.newProject()
                NotificationCenter.default.post(name: .showCurrentRecording, object: nil)
                openWindow(id: "workbench")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!canCreateNewProject)
            Button(uiText("开始录音", "Start recording")) {
                playback.stop()
                Task { await session.start() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!recordingActions.canStart)
            Button(uiText("停止并保存", "Stop and save")) { Task { await recordingActions.stop() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!session.hasActiveRecording || session.isBusy)
            Button(recordingActions.isFinishingPause ? uiText("暂停收尾中…", "Finishing pause…") : session.isPaused ? uiText("继续录音", "Resume recording") : uiText("暂停录音", "Pause recording")) {
                Task { await recordingActions.togglePause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!recordingActions.canTogglePause)
        }
    }

    private var canCreateNewProject: Bool {
        // PDF publishes its history/deletion availability. AppKit can still
        // report an attached sheet during onDismiss, but clearing that pointer
        // does not invalidate SwiftUI's menu. Keep that transient check at action
        // time so it cannot leave the PDF command disabled after dismissal.
        if let contextualNewProject { return contextualNewProject.isEnabled }
        return hasNoModalPresentation && recordingActions.canStart
    }
    private var hasNoModalPresentation: Bool {
        NSApp.modalWindow == nil && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
    }
    private var recordingActions: RecordingActions { .init(recordings: session, bilingual: bilingualLive) }

    private func uiText(_ zh: String, _ en: String) -> String { language.text(zh, en) }
}
