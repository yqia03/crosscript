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
final class DeviceMicrophoneCapture: MicrophoneCapture {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onConfigurationChange: (@Sendable () -> Void)?
    var isRunning: Bool { session.isRunning }
    private let session = AVCaptureSession()
    private let device: AVCaptureDevice
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dev.crosscript.microphone.capture")
    private var relay: MicrophoneSampleRelay?
    private var observers: [NSObjectProtocol] = []
    // AVAudioEngine's I/O nodes follow the system defaults. Mutating their
    // borrowed AudioUnit can be undone by a delayed engine reconfiguration.
    // AVCaptureDeviceInput owns the explicitly selected device instead.
    init(device selected: AudioInputDevice) throws {
        guard let device = AVCaptureDevice(uniqueID: selected.uid), device.hasMediaType(.audio), device.isConnected else { throw MicrophoneDeviceError.unavailable }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw MicrophoneDeviceError.bindingFailed }
        session.addInput(input)
        output.audioSettings = format.settings
        guard session.canAddOutput(output) else { throw MicrophoneDeviceError.bindingFailed }
        session.addOutput(output)
    }
    func validate() throws {
        guard device.isConnected, CoreAudioMicrophoneDevices.inputs().contains(where: { $0.device.uid == device.uniqueID }) else { throw MicrophoneDeviceError.routeChanged }
        if let error = relay?.failure { throw error }
    }
    func start() throws {
        try validate()
        let relay = MicrophoneSampleRelay(format: format, receive: onAudio, changed: onConfigurationChange)
        self.relay = relay
        output.setSampleBufferDelegate(relay, queue: queue)
        if observers.isEmpty {
            let changed = onConfigurationChange
            observers = [
                NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { _ in changed?() },
            ]
        }
        let runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? ""
            relay.fail(MicrophoneDeviceError.captureFailed(detail))
        }
        observers.append(runtimeObserver)
        session.startRunning()
        try validate()
        guard session.isRunning else { throw MicrophoneDeviceError.bindingFailed }
    }
    func pause() {
        session.stopRunning()
        queue.sync {}
        removeObservers()
    }
    func stop() {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.sync {}
        relay = nil
        removeObservers()
    }
    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
// AVFoundation calls this delegate on the capture queue, never the main actor.
// Copy PCM while its CMSampleBuffer is alive; the existing writer synchronously
// persists it before delivering any Live audio.
private final class MicrophoneSampleRelay: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let format: AVAudioFormat
    let receive: (@Sendable (AVAudioPCMBuffer) -> Void)?
    let changed: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var storedFailure: Error?
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return storedFailure }
    init(format: AVAudioFormat, receive: (@Sendable (AVAudioPCMBuffer) -> Void)?, changed: (@Sendable () -> Void)?) { self.format = format; self.receive = receive; self.changed = changed }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard failure == nil else { return }
        guard frames > 0 else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let actual = AVAudioFormat(streamDescription: stream), actual == format,
              frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            fail(MicrophoneDeviceError.invalidFormat); return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            fail(MicrophoneDeviceError.invalidFormat); return
        }
        receive?(buffer)
    }
    func fail(_ error: Error) {
        lock.lock()
        let first = storedFailure == nil
        storedFailure = storedFailure ?? error
        lock.unlock()
        if first { changed?() }
    }
}
