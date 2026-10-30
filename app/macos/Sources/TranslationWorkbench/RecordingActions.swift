import WorkbenchCore

/// Every window and menu routes an action to the owner of the one capture
/// session. A cloud session may still be finishing after capture has stopped.
@MainActor struct RecordingActions {
    let recordings: RecordingSession
    var bilingual: LiveBilingualSession? = nil
    var canStart: Bool {
        recordings.canCreateProject
            && bilingual?.isActive != true && bilingual?.presentation.canReplaceResult != false
            && bilingual?.checkpointNeedsSaveRetry != true
    }
    var isFinishingPause: Bool { bilingual?.isPausing == true }
    var canTogglePause: Bool {
        recordings.hasActiveRecording && !recordings.isBusy && !recordings.needsSaveRetry
            && !isFinishingPause && bilingual?.cloudState != .finishing
    }
    func togglePause() async {
        guard canTogglePause else { return }
        if let bilingual, bilingual.isActive {
            if recordings.isPaused { await bilingual.resume() } else { await bilingual.pause() }
        } else if recordings.isPaused { await recordings.resume() }
        else { await recordings.pause() }
    }
    func stop() async {
        if let bilingual, bilingual.isActive { await bilingual.stop() }
        else { recordings.stop() }
    }
}
