import AVFoundation
import WorkbenchCore

/// Device capture for live audio and explicitly selected microphone devices.
/// Each tap writes locally before delivering PCM to the live service.
@MainActor final class LiveMicrophoneRecorder: AudioRecording {
    var onFailure: ((Error) -> Void)?
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?
    var onLiveAudioFailure: (@Sendable (Error) -> Void)?
    private let devices: MicrophoneDeviceCatalog
    private let requestAccess: () async throws -> Void
    private let hasAccess: () -> Bool
    private let makeCapture: @MainActor (AudioInputDevice) throws -> any MicrophoneCapture
    private var capture: (any MicrophoneCapture)?
    private var selectedDevice: AudioInputDevice?
    private var writer: LiveMicrophoneWriter?
    private var identity: UUID?
    private var timer: Timer?
    private var isPaused = false
    private var savedDuration: TimeInterval = 0
    var currentTime: TimeInterval { writer?.snapshot.0 ?? savedDuration }
    var capturedInputDevice: AudioInputDevice? { capture == nil ? nil : selectedDevice }
    var power: Float { writer?.snapshot.1 ?? -160 }

    init(devices: MicrophoneDeviceCatalog = .system,
         requestAccess: @escaping () async throws -> Void = {
             switch AVCaptureDevice.authorizationStatus(for: .audio) {
             case .authorized: return
             case .notDetermined:
                 guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MicrophoneDeviceError.permission }
             default: throw MicrophoneDeviceError.permission
             }
         },
         hasAccess: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         makeCapture: @escaping @MainActor (AudioInputDevice) throws -> any MicrophoneCapture = { try DeviceMicrophoneCapture(device: $0) }) {
        self.devices = devices
        self.requestAccess = requestAccess
        self.hasAccess = hasAccess
        self.makeCapture = makeCapture
    }

    deinit { timer?.invalidate() }

    func requestPermission(for source: AudioSource) async throws {
        guard capture == nil else { throw MicrophoneDeviceError.active }
        _ = try devices.resolve(source)
        try await requestAccess()
    }

    func start(at url: URL, source: AudioSource) async throws {
        guard capture == nil else { throw MicrophoneDeviceError.active }
        let device = try devices.resolve(source)
        guard hasAccess() else { throw MicrophoneDeviceError.permission }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MicrophoneDeviceError.destination }
        let candidate = try makeCapture(device)
        try candidate.validate()
        let id = UUID()
        let output = try LiveMicrophoneWriter(url: url, format: candidate.format, receive: onLiveAudio, liveFailed: onLiveAudioFailure) { [weak self] error in
            Task { @MainActor [weak self] in self?.fail(error, id: id) }
        }
        output.setPaused(true)
        candidate.onAudio = { buffer in output.append(buffer) }
        candidate.onConfigurationChange = { [weak self] in
            // Freeze on the native callback queue, then inspect and tear down on
            // main instead of tearing down from inside a native notification.
            output.setPaused(true)
            Task { @MainActor [weak self] in self?.configurationChanged(id: id) }
        }
        capture = candidate; writer = output; selectedDevice = device; identity = id; savedDuration = 0; isPaused = false
        do {
            try candidate.start()
            try validateDevice()
            output.setPaused(false)
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.configurationChanged(id: id) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { _ = stop(); throw error }
    }

    func pause() async throws {
        guard let writer, let capture else { throw MicrophoneDeviceError.stopped }
        isPaused = true
        writer.setPaused(true)
        capture.pause()
    }

    func resume() async throws {
        guard let writer, let capture else { throw MicrophoneDeviceError.stopped }
        try validateDevice()
        guard hasAccess() else { throw MicrophoneDeviceError.permission }
        try capture.start()
        try validateDevice()
        isPaused = false
        writer.setPaused(false)
    }

    func stop() -> TimeInterval {
        identity = nil
        timer?.invalidate(); timer = nil
        writer?.setPaused(true)
        capture?.onConfigurationChange = nil
        capture?.stop()
        savedDuration = writer?.finish() ?? savedDuration
        writer = nil; capture = nil; selectedDevice = nil; isPaused = false
        return savedDuration
    }

    private func validateDevice() throws {
        guard let selectedDevice,
              devices.devices().contains(where: { $0.uid == selectedDevice.uid }), let capture else { throw MicrophoneDeviceError.routeChanged }
        try capture.validate()
    }

    private func configurationChanged(id: UUID) {
        guard identity == id, let capture else { return }
        do {
            guard hasAccess() else { throw MicrophoneDeviceError.permission }
            try validateDevice()
            // Startup can issue a delayed notification even though the
            // selected route and format are still valid and capture is running.
            guard isPaused || capture.isRunning else { throw MicrophoneDeviceError.routeChanged }
            writer?.setPaused(isPaused)
        } catch { fail(error, id: id) }
    }

    private func fail(_ error: Error, id: UUID) {
        guard identity == id else { return }
        _ = stop()
        onFailure?(error)
    }
}

private final class LiveMicrophoneWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var paused = false
    private var frames: Int64 = 0
    private let sampleRate: Double
    private var level: Float = -160
    private let conversion: LiveAudioConversion?
    private let failure: @Sendable (Error) -> Void

    init(url: URL, format: AVAudioFormat, receive: (@Sendable (LiveAudioChunk) -> Void)?, liveFailed: (@Sendable (Error) -> Void)?,
         failure: @escaping @Sendable (Error) -> Void) throws {
        sampleRate = format.sampleRate
        self.failure = failure
        conversion = receive.map { LiveAudioConversion(receive: $0, onFailure: liveFailed) }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    var snapshot: (TimeInterval, Float) {
        lock.lock(); defer { lock.unlock() }
        return (Double(frames) / sampleRate, level)
    }
    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if value { level = -160 }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !paused, let file else { return }
        do {
            try file.write(from: buffer)
            frames += Int64(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Double = 0
                for index in 0..<Int(buffer.frameLength) { sum += Double(samples[index] * samples[index]) }
                level = Float(max(-160, min(0, 10 * log10(max(sum / Double(buffer.frameLength), 1e-16)))))
            }
            conversion?.append(buffer)
        } catch { paused = true; failure(error) }
    }
    func finish() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        paused = true; file = nil; level = -160
        return Double(frames) / sampleRate
    }
}
