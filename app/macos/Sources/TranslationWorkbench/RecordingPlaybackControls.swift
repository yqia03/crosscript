import SwiftUI
import WorkbenchCore

/// Playback clock updates stay inside the transport, away from long transcript views.
@MainActor
struct RecordingPlaybackControls: View {
    @ObservedObject var playback: PlaybackController
    let url: URL
    let duration: TimeInterval
    let language: WorkbenchLanguage
    private let muted = Color(red: 0.36, green: 0.44, blue: 0.49)
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    var body: some View {
        let loaded = playback.loadedURL == url
        let total = loaded && playback.duration > 0 ? playback.duration : duration
        VStack(spacing: 15) {
            VStack(spacing: 12) {
                Button {
                    do {
                        if playback.loadedURL != url { try playback.load(url) }
                        try playback.toggle()
                    } catch { /* PlaybackController publishes this error. */ }
                } label: {
                    Label(loaded && playback.isPlaying ? t("暂停回听", "Pause") : t("回听录音", "Listen"), systemImage: loaded && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 19).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 13))
                Text(recordingClock(loaded ? playback.currentTime : 0) + " / " + recordingClock(total)).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
            }
            Slider(value: Binding(get: { playback.loadedURL == url ? min(playback.currentTime, max(0.1, total)) : 0 }, set: { value in
                do {
                    if playback.loadedURL != url { try playback.load(url) }
                    playback.seek(to: value)
                } catch { /* PlaybackController publishes this error. */ }
            }), in: 0...max(0.1, total)).accessibilityLabel(t("回听位置", "Playback position")).disabled(total <= 0)
        }.frame(maxWidth: 440)
    }
}
