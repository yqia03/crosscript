import Foundation
import WorkbenchCore

extension RecordingSession {
    func activityTitle(using language: AppLanguage) -> String {
        if needsSaveRetry { return language.text("已停止，待保存", "Stopped · Save pending") }
        if isBusy { return language.text("正在处理录音…", "Updating recording…") }
        if isPaused { return language.text("录音已暂停", "Recording paused") }
        if isRecording { return language.text("本地录音中", "Recording locally") }
        return language.text("准备就绪", "Ready to record")
    }
}

extension Recording {
    func sourceTitle(using language: WorkbenchLanguage) -> String {
        if isImported { return language.text("导入音频", "Imported audio") }
        if source == .microphone, let capturedInputDevice {
            return source.title(using: language) + " · " + capturedInputDevice.name
        }
        return source.title(using: language)
    }
    var sourceSymbol: String { isImported ? "square.and.arrow.down" : source.symbol }

    func statusTitle(using language: AppLanguage) -> String {
        switch status {
        case .recording: return language.text("录音中", "Recording")
        case .paused: return language.text("已暂停", "Paused")
        case .saved: return language.text("已保存", "Saved")
        case .interrupted: return language.text("录音曾中断", "Interrupted")
        }
    }

    func interruptionDescription(using language: AppLanguage) -> String {
        switch interruptionReason {
        case .systemSleep:
            return language.text("系统睡眠使录音中断，已保存此前的音频。唤醒后不会自动继续。", "System sleep interrupted this recording. Earlier audio was saved. Recording does not resume on wake.")
        case .unexpectedTermination:
            return language.text("上次未正常结束录音，现有资料已保留。末尾可能缺失，请回听核对。", "The previous recording did not end normally. Existing material was retained; the end may be missing. Listen to check it.")
        case .captureFailure, nil:
            return language.text("此录音曾中断，可回听已保存部分。", "This recording was interrupted. Saved audio is available.")
        }
    }
}

func recordingClock(_ seconds: TimeInterval) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
}
