import AVFoundation
import Combine
import Foundation
import WorkbenchCore

private enum NativeAudioError: LocalizedError {
    case microphonePermission
    case microphoneRestricted
    case unsupportedSource
    case alreadyRecording
    case existingRecording
    case cannotPrepareRecording
    case cannotStartRecording
    case noActiveRecording
    case recordingInterrupted
    case recordingFailed(String?)
    case noPlayback
    case cannotPreparePlayback
    case cannotStartPlayback
    case playbackFailed(String?)

    var errorDescription: String? {
        switch self {
        case .microphonePermission:
            return message("请在系统设置的隐私与安全性中允许访问麦克风，然后重新开始录音。", "Allow microphone access in System Settings → Privacy & Security, then start recording again.")
        case .microphoneRestricted:
            return message("此 Mac 限制了麦克风访问，无法开始录音。", "Microphone access is restricted on this Mac. Recording could not start.")
        case .unsupportedSource:
            return message("这项录音器无法采集所选音源。请重新选择音源。", "This recorder cannot capture the selected audio source. Select the source again.")
        case .alreadyRecording:
            return message("已有录音正在进行，请先停止当前录音。", "A recording is already in progress. Stop it before starting another.")
        case .existingRecording:
            return message("录音目标已存在。为保留已有资料，本次录音未开始。", "The recording destination already exists. Recording did not start so the existing material remains safe.")
        case .cannotPrepareRecording:
            return message("无法准备麦克风录音，请检查音频输入设备和保存位置后重试。", "Could not prepare microphone recording. Check the input device and save location, then try again.")
        case .cannotStartRecording:
            return message("麦克风录音未能开始，请检查输入设备后重试。", "Microphone recording did not start. Check the input device and try again.")
        case .noActiveRecording:
            return message("当前录音已经结束，请开始新的录音。", "This recording has ended. Start a new recording.")
        case .recordingInterrupted:
            return message("录音意外停止，已停止采集。请检查已保存的录音后再开始。", "Recording stopped unexpectedly. Check the saved recording before starting again.")
        case .recordingFailed(let detail):
            return withDetail(message("录音发生错误，采集已停止。", "Recording encountered an error and capture stopped."), detail)
        case .noPlayback:
            return message("请先选择一份已保存的录音。", "Choose a saved recording first.")
        case .cannotPreparePlayback:
            return message("无法准备回放，这份音频可能已损坏或无法读取。", "Could not prepare playback. The audio may be damaged or unreadable.")
        case .cannotStartPlayback:
            return message("音频未能开始播放，请检查输出设备后重试。", "Audio playback did not start. Check the output device and try again.")
        case .playbackFailed(let detail):
            return withDetail(message("音频播放发生错误，播放已停止。", "Audio playback encountered an error and stopped."), detail)
        }
    }

    private func message(_ chinese: String, _ english: String) -> String {
        AppLanguage.current.text(chinese, english)
    }

    private func withDetail(_ message: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        return message + "\n" + detail
    }
}

// AVFoundation delegates need not arrive on the main actor. These relays carry
// only immutable callbacks; the owning adapters validate the session identity.
private final class RecordingDelegate: NSObject, AVAudioRecorderDelegate {
    let didFinish: @Sendable (Bool) -> Void
    let didFail: @Sendable (Error?) -> Void

    init(didFinish: @escaping @Sendable (Bool) -> Void, didFail: @escaping @Sendable (Error?) -> Void) {
        self.didFinish = didFinish
        self.didFail = didFail
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        didFinish(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        didFail(error)
    }
}

@MainActor
final class MicrophoneRecorder: NSObject, AudioRecording {
    var onFailure: ((Error) -> Void)?

    private var recorder: AVAudioRecorder?
    private var recorderDelegate: RecordingDelegate?
    private var sessionID: UUID?
    private var stoppedDuration: TimeInterval = 0
    private var isPaused = false
    private var selectedDevice: AudioInputDevice?
    private var deviceTimer: Timer?

    deinit { deviceTimer?.invalidate() }

    var currentTime: TimeInterval {
        guard let recorder, !isPaused else { return stoppedDuration }
        let time = recorder.currentTime
        return time.isFinite && time >= 0 ? time : stoppedDuration
    }

    var power: Float {
        guard let recorder, recorder.isRecording else { return -160 }
        recorder.updateMeters()
        let value = recorder.averagePower(forChannel: 0)
        return value.isFinite ? min(0, max(-160, value)) : -160
    }

    func requestPermission(for source: AudioSource) async throws {
        guard source == .microphone else { throw NativeAudioError.unsupportedSource }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw NativeAudioError.microphonePermission }
        case .denied:
            throw NativeAudioError.microphonePermission
        case .restricted:
            throw NativeAudioError.microphoneRestricted
        @unknown default:
            throw NativeAudioError.microphonePermission
        }
    }

    func start(at url: URL, source: AudioSource) async throws {
        guard source == .microphone else { throw NativeAudioError.unsupportedSource }
        guard recorder == nil else { throw NativeAudioError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NativeAudioError.microphonePermission
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NativeAudioError.existingRecording
        }
        let device = try MicrophoneDeviceCatalog.system.resolve(source)
        stoppedDuration = 0
        isPaused = false

        let candidate: AVAudioRecorder
        do {
            candidate = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        } catch {
            throw NativeAudioError.recordingFailed(error.localizedDescription)
        }

        let id = UUID()
        let relay = RecordingDelegate(
            didFinish: { [weak self] successful in
                Task { @MainActor [weak self] in
                    self?.recordingFinished(id: id, successful: successful)
                }
            },
            didFail: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.recordingFailed(id: id, error: error)
                }
            }
        )
        candidate.delegate = relay
        candidate.isMeteringEnabled = true
        guard candidate.prepareToRecord() else {
            candidate.delegate = nil
            candidate.stop()
            throw NativeAudioError.cannotPrepareRecording
        }

        recorderDelegate = relay
        recorder = candidate
        sessionID = id
        selectedDevice = device
        guard candidate.record() else {
            _ = stop()
            throw NativeAudioError.cannotStartRecording
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                do { try self.validateDevice() }
                catch { _ = self.stop(); self.onFailure?(error) }
            }
        }
        deviceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pause() async throws {
        guard let recorder else { throw NativeAudioError.noActiveRecording }
        guard !isPaused else { return }
        // AVAudioRecorder only guarantees currentTime while recording.
        stoppedDuration = currentTime
        recorder.pause()
        isPaused = true
    }

    func resume() async throws {
        guard let recorder else { throw NativeAudioError.noActiveRecording }
        guard isPaused else { return }
        try validateDevice()
        guard recorder.record() else { throw NativeAudioError.cannotStartRecording }
        isPaused = false
    }

    @discardableResult
    func stop() -> TimeInterval {
        guard let recorder else { return stoppedDuration }
        let capturedDuration = currentTime
        let fileURL = recorder.url
        // Invalidate before closing: a delegate queued by stop belongs to the
        // intentionally finished session and must not report a new failure.
        sessionID = nil
        deviceTimer?.invalidate()
        deviceTimer = nil
        selectedDevice = nil
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recorderDelegate = nil
        isPaused = false

        if let duration = try? AudioFileInspection.duration(at: fileURL) {
            stoppedDuration = duration
        } else if capturedDuration.isFinite && capturedDuration > 0 {
            stoppedDuration = capturedDuration
        }
        return stoppedDuration
    }

    private func recordingFinished(id: UUID, successful: Bool) {
        guard id == sessionID else { return }
        _ = stop()
        onFailure?(successful ? NativeAudioError.recordingInterrupted : NativeAudioError.recordingFailed(nil))
    }

    private func validateDevice() throws {
        guard let selectedDevice,
              CoreAudioMicrophoneDevices.defaultInput()?.uid == selectedDevice.uid else { throw MicrophoneDeviceError.routeChanged }
    }

    private func recordingFailed(id: UUID, error: Error?) {
        guard id == sessionID else { return }
        _ = stop()
        onFailure?(NativeAudioError.recordingFailed(error?.localizedDescription))
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    let didFinish: @Sendable (Bool) -> Void
    let didFail: @Sendable (Error?) -> Void

    init(didFinish: @escaping @Sendable (Bool) -> Void, didFail: @escaping @Sendable (Error?) -> Void) {
        self.didFinish = didFinish
        self.didFail = didFail
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        didFail(error)
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var playerDelegate: PlaybackDelegate?
    private var sessionID: UUID?
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    func load(_ url: URL) throws {
        unload()
        lastError = nil
        do {
            let candidate = try AVAudioPlayer(contentsOf: url)
            guard candidate.prepareToPlay() else { throw NativeAudioError.cannotPreparePlayback }
            player = candidate
            observePlayback(candidate)
            loadedURL = url
            duration = candidate.duration.isFinite ? max(0, candidate.duration) : 0
            currentTime = 0
        } catch {
            let failure = (error as? NativeAudioError) ?? .playbackFailed(error.localizedDescription)
            lastError = failure.localizedDescription
            throw failure
        }
    }

    func toggle() throws {
        guard let player else {
            lastError = NativeAudioError.noPlayback.localizedDescription
            throw NativeAudioError.noPlayback
        }
        lastError = nil
        if isPlaying {
            clearPlaybackObservation()
            player.pause()
            currentTime = min(duration, max(0, player.currentTime))
            isPlaying = false
            cancelTimer()
            return
        }
        if currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        observePlayback(player)
        guard player.play() else {
            clearPlaybackObservation()
            isPlaying = false
            cancelTimer()
            lastError = NativeAudioError.cannotStartPlayback.localizedDescription
            throw NativeAudioError.cannotStartPlayback
        }
        isPlaying = true
        startTimer()
    }

    /// A paragraph action always starts playback, including when another paragraph is playing.
    func play(at time: TimeInterval, from url: URL) throws {
        if loadedURL != url { try load(url) }
        guard time.isFinite, time >= 0, time < duration else {
            if isPlaying { try toggle() }
            let failure = NativeAudioError.playbackFailed(AppLanguage.current.text(
                "段落时间超出这份音频范围，无法定位。", "The paragraph time is outside this audio file."))
            lastError = failure.localizedDescription
            throw failure
        }
        seek(to: time)
        if !isPlaying { try toggle() }
    }

    func seek(to time: TimeInterval) {
        guard let player, time.isFinite else { return }
        let target = min(duration, max(0, time))
        // A completion queued before a manual seek belongs to the old position.
        observePlayback(player)
        player.currentTime = target
        currentTime = target
        if target >= duration {
            clearPlaybackObservation()
            player.pause()
            isPlaying = false
            cancelTimer()
        }
    }

    func stop() {
        clearPlaybackObservation()
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        cancelTimer()
    }

    func dismissError() {
        lastError = nil
    }

    private func unload() {
        stop()
        player = nil
        playerDelegate = nil
        loadedURL = nil
        duration = 0
    }

    private func observePlayback(_ player: AVAudioPlayer) {
        let id = UUID()
        let relay = PlaybackDelegate(
            didFinish: { [weak self] successful in
                Task { @MainActor [weak self] in
                    self?.playbackFinished(id: id, successful: successful)
                }
            },
            didFail: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.playbackFailed(id: id, error: error)
                }
            }
        )
        sessionID = id
        playerDelegate = relay
        player.delegate = relay
    }

    private func clearPlaybackObservation() {
        sessionID = nil
        player?.delegate = nil
        playerDelegate = nil
    }

    private func startTimer() {
        cancelTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPlaybackTime()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshPlaybackTime() {
        guard isPlaying, let player else { return }
        currentTime = min(duration, max(0, player.currentTime))
    }

    private func playbackFinished(id: UUID, successful: Bool) {
        guard id == sessionID else { return }
        clearPlaybackObservation()
        isPlaying = false
        cancelTimer()
        if successful {
            currentTime = duration
        } else {
            currentTime = min(duration, max(0, player?.currentTime ?? currentTime))
            lastError = NativeAudioError.playbackFailed(nil).localizedDescription
        }
    }

    private func playbackFailed(id: UUID, error: Error?) {
        guard id == sessionID else { return }
        clearPlaybackObservation()
        let position = player?.currentTime ?? currentTime
        player?.stop()
        currentTime = min(duration, max(0, position))
        isPlaying = false
        cancelTimer()
        lastError = NativeAudioError.playbackFailed(error?.localizedDescription).localizedDescription
    }
}
