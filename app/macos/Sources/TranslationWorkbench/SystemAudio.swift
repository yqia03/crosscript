import AppKit
import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import WorkbenchCore

private enum SystemAudioError: LocalizedError {
    case permission
    case applicationUnavailable
    case applicationStopped
    case displayUnavailable
    case existingRecording
    case alreadyRecording
    case noActiveRecording
    case invalidFormat
    case captureFailed(String)
    case saveFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permission:
            return text("系统声音采集需要“屏幕与系统音频录制”权限。请在系统设置 → 隐私与安全性中允许本 App，然后重试；系统可能要求重新打开 App。App 只保存音频，不保存屏幕画面。", "System audio capture requires Screen & System Audio Recording permission. Allow this app in System Settings → Privacy & Security, then retry; macOS may require reopening the app. The app saves audio only, without screen images.")
        case .applicationUnavailable:
            return text("所选应用已退出、重新启动或当前无法采集。请刷新应用列表并重新选择；录音未切换到整机声音。", "The selected app has quit, restarted, or cannot currently be captured. Refresh the application list and select it again. Recording did not switch to all system audio.")
        case .applicationStopped:
            return text("所选应用已退出，系统声音采集已停止；已采集音频保留在历史中。", "The selected app has quit. Capture stopped, and the captured audio remains in history.")
        case .displayUnavailable:
            return text("当前没有可供系统声音采集的显示器或窗口。请唤醒或重新连接显示器后开始新的录音；已有资料保留。", "No display or window is available for system audio capture. Wake or reconnect the display, then start a new recording. Existing material is retained.")
        case .existingRecording:
            return text("录音目标已存在。为保留已有资料，本次录音未开始。", "The recording destination already exists. Recording did not start so the existing material remains safe.")
        case .alreadyRecording:
            return text("已有录音正在进行，请先停止当前录音。", "A recording is already in progress. Stop it before starting another.")
        case .noActiveRecording:
            return text("当前录音已经结束，请开始新的录音。", "This recording has ended. Start a new recording.")
        case .invalidFormat:
            return text("系统返回的音频格式无法保存，采集已停止。", "The system returned an audio format that could not be saved. Capture stopped.")
        case .captureFailed(let detail):
            return text("系统声音采集失败，已停止采集。", "System audio capture failed and stopped.") + "\n" + detail
        case .saveFailed(let detail):
            return text("无法继续保存系统声音，采集已停止；请检查磁盘空间与保存位置。", "System audio could not be saved. Capture stopped; check free disk space and the save location.") + "\n" + detail
        case .cleanupFailed(let detail):
            return text("系统未能确认上一项采集已停止。已保存音频保留；请重新打开 App 后再录音。", "The system could not confirm that the previous capture stopped. Saved audio remains available. Reopen the app before recording again.") + "\n" + detail
        }
    }

    private func text(_ chinese: String, _ english: String) -> String {
        AppLanguage.current.text(chinese, english)
    }

    static func capture(_ error: Error) -> Error {
        let native = error as NSError
        if native.domain == SCStreamErrorDomain,
           native.code == SCStreamError.Code.userDeclined.rawValue {
            return SystemAudioError.permission
        }
        if native.domain == SCStreamErrorDomain,
           native.code == SCStreamError.Code.noCaptureSource.rawValue {
            return SystemAudioError.displayUnavailable
        }
        return SystemAudioError.captureFailed(error.localizedDescription)
    }
}

@MainActor
final class AudioApplicationList: ObservableObject {
    @Published private(set) var applications: [AudioApplication] = []

    func refresh() {
        applications = NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleIdentifier = application.bundleIdentifier,
                  let name = application.localizedName else { return nil }
            return AudioApplication(bundleIdentifier: bundleIdentifier, name: name,
                                    processID: application.processIdentifier, launchDate: application.launchDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class SourceRecorder: AudioRecording {
    var onFailure: ((Error) -> Void)?
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?
    var onLiveAudioFailure: (@Sendable (Error) -> Void)?
    private let microphone: any AudioRecording
    private let liveMicrophone: any AudioRecording
    private let system: SystemAudioRecorder
    private var active: (any AudioRecording)?
    private var sessionID: UUID?
    private var stoppedDuration: TimeInterval = 0

    init(microphone: (any AudioRecording)? = nil, liveMicrophone: (any AudioRecording)? = nil) {
        self.microphone = microphone ?? MicrophoneRecorder()
        self.liveMicrophone = liveMicrophone ?? LiveMicrophoneRecorder()
        self.system = SystemAudioRecorder()
    }

    var currentTime: TimeInterval { active?.currentTime ?? stoppedDuration }
    var power: Float { active?.power ?? -160 }

    func requestPermission(for source: AudioSource) async throws {
        guard active == nil else { throw SystemAudioError.alreadyRecording }
        try await recorder(for: source).requestPermission(for: source)
    }

    func start(at url: URL, source: AudioSource) async throws {
        guard active == nil, sessionID == nil else { throw SystemAudioError.alreadyRecording }
        let id = UUID()
        stoppedDuration = 0
        sessionID = id
        do {
            // A retired system stream must stop before either source starts.
            try await system.waitForStop()
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
            let adapter = recorder(for: source)
            active = adapter
            adapter.onLiveAudio = onLiveAudio
            adapter.onLiveAudioFailure = onLiveAudioFailure
            adapter.onFailure = { [weak self] error in
                guard let self, self.sessionID == id else { return }
                self.onFailure?(error)
            }
            try await adapter.start(at: url, source: source)
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
        } catch {
            if sessionID == id { _ = stop() }
            throw error
        }
    }

    func pause() async throws {
        guard let active else { throw SystemAudioError.noActiveRecording }
        try await active.pause()
    }

    func resume() async throws {
        guard let active else { throw SystemAudioError.noActiveRecording }
        try await active.resume()
    }

    func stop() -> TimeInterval {
        sessionID = nil
        guard let active else { return stoppedDuration }
        active.onFailure = nil
        stoppedDuration = active.stop()
        active.onLiveAudio = nil
        active.onLiveAudioFailure = nil
        self.active = nil
        return stoppedDuration
    }

    private func recorder(for source: AudioSource) -> any AudioRecording {
        if case .microphoneDevice = source { return liveMicrophone }
        if source.isMicrophone { return onLiveAudio == nil ? microphone : liveMicrophone }
        return system
    }
}

// Every mutable file/buffer field is confined to this output's serial queue.
// Main-actor stop drains that queue before releasing the file, so queued samples
// from a retired SCStream can never write into a later recording.
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.uown.system-audio-file")
    private var file: AVAudioFile?
    private var acceptsSamples = true
    private var frames: AVAudioFramePosition = 0
    private let sampleRate: Double = 48_000
    private var level: Float = -160
    private var failure: Error?
    private var streamStopped = false
    private var activeStream: ObjectIdentifier?
    private let didFail: @Sendable (Error) -> Void
    private let liveConversion: LiveAudioConversion?

    init(destination: URL, receiveLive: (@Sendable (LiveAudioChunk) -> Void)?, liveFailed: (@Sendable (Error) -> Void)?, didFail: @escaping @Sendable (Error) -> Void) throws {
        self.didFail = didFail
        self.liveConversion = receiveLive.map { LiveAudioConversion(receive: $0, onFailure: liveFailed) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false) else {
            throw SystemAudioError.invalidFormat
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do {
            file = try AVAudioFile(forWriting: destination, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SystemAudioError.saveFailed(error.localizedDescription)
        }
    }

    var snapshot: (duration: TimeInterval, power: Float, error: Error?) {
        queue.sync { (Double(frames) / sampleRate, level, failure) }
    }

    var hasStopped: Bool { queue.sync { streamStopped } }

    func attach(_ stream: SCStream) {
        queue.sync {
            activeStream = ObjectIdentifier(stream)
            streamStopped = false
            acceptsSamples = true
        }
    }

    // Freeze and drain the serial writer while retaining the same file. The
    // caller then stops the native stream; resume attaches a fresh stream.
    func pause() {
        queue.sync {
            activeStream = nil
            acceptsSamples = false
            level = -160
        }
    }

    func finish() -> TimeInterval {
        queue.sync {
            activeStream = nil
            acceptsSamples = false
            file = nil
            level = -160
            return Double(frames) / sampleRate
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard activeStream == ObjectIdentifier(stream), type == .audio,
              acceptsSamples, CMSampleBufferIsValid(sampleBuffer) else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: streamDescription),
                  format.commonFormat == .pcmFormatFloat32,
                  format.sampleRate == sampleRate, format.channelCount == 2 else { throw SystemAudioError.invalidFormat }
            var required = 0
            var block: CMBlockBuffer?
            defer { withExtendedLifetime(block) {} }
            var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            guard status == noErr, required >= MemoryLayout<AudioBufferList>.size else {
                throw SystemAudioError.invalidFormat
            }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
            status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
            guard status == noErr,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else {
                throw SystemAudioError.invalidFormat
            }
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0 else { return }
            guard sampleCount <= Int(buffer.frameCapacity) else { throw SystemAudioError.invalidFormat }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            guard let file else { throw SystemAudioError.invalidFormat }
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            level = power(of: buffer)
            liveConversion?.append(buffer)
            // Retain the CMSampleBuffer's backing audio block until after the
            // synchronous AVAudioFile conversion/write has consumed its bytes.
        } catch {
            fail(error is SystemAudioError ? error : SystemAudioError.saveFailed(error.localizedDescription))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard activeStream == ObjectIdentifier(stream) else { return }
            streamStopped = true
            fail(SystemAudioError.capture(error))
        }
    }

    private func fail(_ error: Error) {
        guard acceptsSamples else { return }
        failure = error
        acceptsSamples = false
        didFail(error)
    }

    private func power(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sum: Double = 0
        for channel in 0..<channels {
            for frame in 0..<frames {
                let sample = Double(data[buffer.format.isInterleaved ? 0 : channel][buffer.format.isInterleaved ? frame * channels + channel : frame])
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Double(max(1, frames * channels)))
        return rms.isFinite && rms > 0 ? Float(max(-160, min(0, 20 * log10(rms)))) : -160
    }
}

@MainActor
final class SystemAudioRecorder: AudioRecording {
    var onFailure: ((Error) -> Void)?
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)?
    var onLiveAudioFailure: (@Sendable (Error) -> Void)?
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var sessionID: UUID?
    private var source: AudioSource?
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var pendingStop: (id: UUID, task: Task<Error?, Never>)?
    private var pendingStart: (streamID: ObjectIdentifier, task: Task<Void, Error>)?
    private var stoppedDuration: TimeInterval = 0

    var currentTime: TimeInterval { output?.snapshot.duration ?? stoppedDuration }
    var power: Float { output?.snapshot.power ?? -160 }

    deinit {
        timer?.invalidate()
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    func requestPermission(for source: AudioSource) async throws {
        _ = try await content(for: source)
    }

    func start(at url: URL, source: AudioSource) async throws {
        guard sessionID == nil, output == nil else { throw SystemAudioError.alreadyRecording }
        let id = UUID()
        sessionID = id
        self.source = source
        stoppedDuration = 0
        do {
            try await waitForStop()
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw SystemAudioError.existingRecording }
            let filter = try await filter(for: source)
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
            let candidateOutput = try SystemAudioOutput(destination: url, receiveLive: onLiveAudio, liveFailed: onLiveAudioFailure) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.onFailure?(error)
                }
            }
            output = candidateOutput
            try await beginCapture(filter: filter, output: candidateOutput, source: source, id: id)
            observe(id: id)
        } catch {
            if sessionID == id { _ = stop() }
            throw error is SystemAudioError ? error : SystemAudioError.capture(error)
        }
    }

    func pause() async throws {
        guard let id = sessionID, let output else { throw SystemAudioError.noActiveRecording }
        output.pause()
        retireStream()
        try await waitForStop()
        guard sessionID == id else { throw SystemAudioError.noActiveRecording }
    }

    func resume() async throws {
        guard let id = sessionID, let output, let source else { throw SystemAudioError.noActiveRecording }
        guard stream == nil else { return }
        do {
            try await waitForStop()
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
            // Preserve the original application process/launch identity. A new
            // stream cannot contain queued samples from before the pause.
            let filter = try await filter(for: source)
            guard sessionID == id else { throw SystemAudioError.noActiveRecording }
            try await beginCapture(filter: filter, output: output, source: source, id: id)
        } catch {
            if sessionID == id { _ = stop() }
            throw error is SystemAudioError ? error : SystemAudioError.capture(error)
        }
    }

    func stop() -> TimeInterval {
        sessionID = nil
        source = nil
        timer?.invalidate()
        timer = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        if let output { stoppedDuration = output.finish() }
        retireStream()
        output = nil
        return stoppedDuration
    }

    private func retireStream() {
        guard let retiredStream = stream else { return }
        let retiredOutput = output
        let start = pendingStart?.streamID == ObjectIdentifier(retiredStream) ? pendingStart?.task : nil
        let streamAlreadyStopped = retiredOutput?.hasStopped ?? false
        stream = nil
        pendingStart = nil
        if !streamAlreadyStopped {
            pendingStop = (UUID(), Task {
                // A stop requested during native start must wait for that
                // exact start. Otherwise a late completion could resume capture
                // after an attemptToStopStreamState response.
                _ = try? await start?.value
                do {
                    try await retiredStream.stopCapture()
                    withExtendedLifetime(retiredOutput) {}
                    return nil
                } catch {
                    withExtendedLifetime(retiredOutput) {}
                    let native = error as NSError
                    if native.domain == SCStreamErrorDomain,
                       native.code == SCStreamError.Code.attemptToStopStreamState.rawValue {
                        // A failed start or an already-ended stream has no
                        // running capture left for stopCapture to stop.
                        return nil
                    }
                    return SystemAudioError.cleanupFailed(error.localizedDescription)
                }
            })
        }
    }

    func waitForStop() async throws {
        guard let pendingStop else { return }
        if let error = await pendingStop.task.value {
            // A failed stop cannot prove that the old native stream is gone.
            // Keep this result and refuse a new capture instead of overlapping.
            throw error
        }
        if self.pendingStop?.id == pendingStop.id { self.pendingStop = nil }
    }

    private func beginCapture(filter: SCContentFilter, output: SystemAudioOutput, source: AudioSource, id: UUID) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let candidate = SCStream(filter: filter, configuration: configuration, delegate: output)
        // Only audio output is attached: no screen samples are received/saved.
        try candidate.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        output.attach(candidate)
        stream = candidate
        let start = Task { try await candidate.startCapture() }
        pendingStart = (ObjectIdentifier(candidate), start)
        try await start.value
        guard sessionID == id, stream === candidate else { throw SystemAudioError.noActiveRecording }
        pendingStart = nil
        if let failure = output.snapshot.error { throw failure }
        guard CGPreflightScreenCaptureAccess() else { throw SystemAudioError.permission }
        if case .application(let application) = source, !Self.isRunning(application) {
            throw SystemAudioError.applicationUnavailable
        }
    }

    private func filter(for source: AudioSource) async throws -> SCContentFilter {
        let content = try await content(for: source)
        guard let display = content.displays.first else { throw SystemAudioError.displayUnavailable }
        switch source {
        case .system:
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .application(let application):
            guard Self.isRunning(application),
                  let selected = content.applications.first(where: {
                      $0.processID == application.processID && $0.bundleIdentifier == application.bundleIdentifier
                  }) else { throw SystemAudioError.applicationUnavailable }
            return SCContentFilter(display: display, including: [selected], exceptingWindows: [])
        case .microphone, .microphoneDevice:
            throw SystemAudioError.applicationUnavailable
        }
    }

    private func content(for source: AudioSource) async throws -> SCShareableContent {
        if case .application(let application) = source, !Self.isRunning(application) {
            throw SystemAudioError.applicationUnavailable
        }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioError.capture(error)
        }
    }

    private static func isRunning(_ application: AudioApplication) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: application.processID),
              !current.isTerminated, current.bundleIdentifier == application.bundleIdentifier,
              let selectedLaunch = application.launchDate, let actualLaunch = current.launchDate else { return false }
        return actualLaunch == selectedLaunch
    }

    private func observe(id: UUID) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkCapture(id: id) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkCapture(id: id) }
        }
    }

    private func checkCapture(id: UUID) {
        guard sessionID == id else { return }
        let failure: Error?
        if !CGPreflightScreenCaptureAccess() { failure = SystemAudioError.permission }
        else if case .application(let application) = source, !Self.isRunning(application) { failure = SystemAudioError.applicationStopped }
        else { failure = nil }
        if let failure {
            // macOS may defer revocation until this process quits. Its public
            // preflight result remains allowed during that effective grant.
            _ = stop()
            onFailure?(failure)
        }
    }
}
