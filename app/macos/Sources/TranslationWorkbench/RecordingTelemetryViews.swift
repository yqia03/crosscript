import SwiftUI
import WorkbenchCore

@MainActor struct RecordingClockView: View {
    @ObservedObject var telemetry: RecordingTelemetry
    var fixedDuration: TimeInterval? = nil
    var prefix = ""
    var body: some View {
        Text(prefix + recordingClock(fixedDuration ?? telemetry.elapsed)).monospacedDigit()
    }
}

@MainActor struct RecordingInputMeter: View {
    @ObservedObject var telemetry: RecordingTelemetry
    let language: WorkbenchLanguage
    private let accent = Color(red: 0.16, green: 0.47, blue: 0.53)
    private let muted = Color(red: 0.36, green: 0.44, blue: 0.49)
    var body: some View {
        let level = min(1, max(0, telemetry.inputLevel))
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.09))
                    Capsule().fill(accent.opacity(0.75)).frame(width: geometry.size.width * level)
                }
            }.frame(height: 7)
                .accessibilityLabel(language.text("音源电平", "Audio source level"))
                .accessibilityValue("\(Int(level * 100))%")
            HStack {
                Text(language.text("输入电平", "Input level")); Spacer()
                Text("\(Int(level * 100))%").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(muted)
        }
    }
}

@MainActor struct RecordingMenuLabel: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var telemetry: RecordingTelemetry
    let language: AppLanguage
    var body: some View {
        Label(title, systemImage: symbol).accessibilityLabel(session.activityTitle(using: language))
    }
    private var title: String {
        if session.needsSaveRetry { return language.text("待保存", "Save pending") }
        if session.isBusy { return language.text("处理中", "Updating") }
        if session.hasActiveRecording {
            return (session.isPaused ? language.text("已暂停 ", "Paused ") : "") + recordingClock(telemetry.elapsed)
        }
        return ""
    }
    private var symbol: String {
        if session.lastError != nil { return "exclamationmark.circle" }
        if session.isPaused { return "pause.circle" }
        return session.isRecording ? "record.circle" : "waveform.circle"
    }
}
