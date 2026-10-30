import AVFoundation
import WorkbenchCore

/// The hardware boundary used by local and live microphone capture. Controlled
/// captures can supply PCM without opening a real microphone in tests.
@MainActor
protocol MicrophoneCapture: AnyObject {
    var format: AVAudioFormat { get }
    var isRunning: Bool { get }
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onConfigurationChange: (@Sendable () -> Void)? { get set }
    func validate() throws
    func start() throws
    func pause()
    func stop()
}

@MainActor
final class EngineMicrophoneCapture: MicrophoneCapture {
    let format: AVAudioFormat
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onConfigurationChange: (@Sendable () -> Void)?
    var isRunning: Bool { engine.isRunning }
    private let engine: AVAudioEngine
    private let device: AudioInputDevice
    private var observer: NSObjectProtocol?
    private var tapped = false

    init(device: AudioInputDevice) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw MicrophoneDeviceError.bindingFailed }
        try CoreAudioMicrophoneDevices.bind(unit, to: device)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneDeviceError.unavailable }
        self.engine = engine
        self.device = device
        self.format = format
    }

    func validate() throws {
        guard CoreAudioMicrophoneDevices.inputs().contains(where: { $0.device.uid == device.uid }),
              let unit = engine.inputNode.audioUnit,
              CoreAudioMicrophoneDevices.currentUID(unit) == device.uid,
              engine.inputNode.outputFormat(forBus: 0) == format else { throw MicrophoneDeviceError.routeChanged }
    }

    func start() throws {
        try validate()
        if !tapped {
            let receive = onAudio
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in receive?(buffer) }
            tapped = true
            let changed = onConfigurationChange
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in changed?() }
        }
        engine.prepare()
        try engine.start()
        try validate()
    }

    func pause() { engine.pause() }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
    }
}
