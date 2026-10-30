import AVFoundation
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized)
@MainActor
struct MicrophoneDeviceTests {
    @Test(arguments: [false, true])
    func selectedInputIsCapturedAndRetainedAcrossBothWorkflows(live: Bool) async throws {
        let fixture = try MicrophoneFixture()
        defer { fixture.cleanUp() }
        let source = AudioSource.microphoneDevice(fixture.selected)
        let router = SourceRecorder(liveMicrophone: fixture.recorder)
        if live { router.onLiveAudio = { _ in } }
        let session = RecordingSession(store: RecordingStore(root: fixture.root), recorder: router)
        session.selectSource(source)
        await session.start(workflow: live ? .liveTranslation : .transcription)
        #expect(session.isRecording)
        #expect(fixture.capturedDevice == fixture.selected)
        fixture.hardware.emitSpeech()
        session.selectSource(.microphone)
        #expect(session.selectedSource == source)
        await session.pause()
        session.selectSource(.system)
        #expect(session.selectedSource == source)
        await session.resume()
        fixture.hardware.emitSpeech()
        session.stop()
        let recording = try #require(session.selectedRecording)
        #expect(recording.source == source)
        #expect(recording.duration == 0.2)
        #expect(try AudioFileInspection.duration(at: session.audioURL(for: recording.id)) == 0.2)
        let reopened = RecordingSession(store: RecordingStore(root: fixture.root), recorder: router)
        reopened.activateWorkflow(live ? .liveTranslation : .transcription)
        #expect(reopened.selectedRecording?.source == source)
    }

    @Test func unavailableSelectedInputDoesNotAskPermissionOrCreateMaterial() async throws {
        let fixture = try MicrophoneFixture()
        defer { fixture.cleanUp() }
        fixture.available = false
        let session = RecordingSession(store: RecordingStore(root: fixture.root), recorder: SourceRecorder(liveMicrophone: fixture.recorder))
        session.selectSource(.microphoneDevice(fixture.selected))
        await session.start()
        #expect(!session.isRecording)
        #expect(session.recordings.isEmpty)
        #expect(fixture.permissionRequests == 0)
        #expect(fixture.capturedDevice == nil)
        #expect(session.lastError != nil)
    }

    @Test func disconnectedInputCannotResumeAndKeepsWrittenAudio() async throws {
        let fixture = try MicrophoneFixture()
        defer { fixture.cleanUp() }
        let session = RecordingSession(store: RecordingStore(root: fixture.root), recorder: SourceRecorder(liveMicrophone: fixture.recorder))
        let source = AudioSource.microphoneDevice(fixture.selected)
        session.selectSource(source)
        await session.start()
        fixture.hardware.emitSpeech()
        await session.pause()
        fixture.available = false
        await session.resume()
        let recording = try #require(session.selectedRecording)
        #expect(!session.hasActiveRecording)
        #expect(recording.source == source)
        #expect(recording.status == .interrupted)
        #expect(recording.interruptionReason == .captureFailure)
        #expect(try AudioFileInspection.duration(at: session.audioURL(for: recording.id)) == 0.1)
        #expect(session.lastError != nil)
    }

    @Test func routeReplacementStopsCaptureButHealthyStartupNotificationDoesNot() async throws {
        let fixture = try MicrophoneFixture()
        defer { fixture.cleanUp() }
        let session = RecordingSession(store: RecordingStore(root: fixture.root), recorder: SourceRecorder(liveMicrophone: fixture.recorder))
        session.selectSource(.microphoneDevice(fixture.selected))
        await session.start()
        fixture.hardware.onConfigurationChange?()
        for _ in 0..<10 { await Task.yield() }
        #expect(session.isRecording)
        fixture.hardware.emitSpeech()
        fixture.hardware.routeAvailable = false
        fixture.hardware.onConfigurationChange?()
        for _ in 0..<100 where session.hasActiveRecording { await Task.yield() }
        let recording = try #require(session.selectedRecording)
        #expect(!session.hasActiveRecording)
        #expect(!fixture.hardware.isRunning)
        #expect(recording.status == .interrupted)
        #expect(recording.duration == 0.1)
        #expect(try AudioFileInspection.duration(at: session.audioURL(for: recording.id)) == 0.1)
    }
}

@MainActor
private final class MicrophoneFixture {
    let selected = AudioInputDevice(uid: "controlled:usb-input", name: "USB meeting microphone")
    let other = AudioInputDevice(uid: "controlled:builtin", name: "Built-in microphone")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("microphone-selection-\(UUID())")
    let hardware = ControlledMicrophoneCapture()
    var available = true
    var permissionRequests = 0
    var capturedDevice: AudioInputDevice?
    lazy var recorder = LiveMicrophoneRecorder(
        devices: MicrophoneDeviceCatalog(devices: { [unowned self] in self.available ? [self.selected, self.other] : [self.other] },
                                        defaultUID: { [unowned self] in self.other.uid }),
        requestAccess: { [unowned self] in self.permissionRequests += 1 }, hasAccess: { true },
        makeCapture: { [unowned self] device in self.capturedDevice = device; return self.hardware })
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanUp() { _ = recorder.stop(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class ControlledMicrophoneCapture: MicrophoneCapture {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onConfigurationChange: (@Sendable () -> Void)?
    var isRunning = false
    var routeAvailable = true
    func validate() throws { if !routeAvailable { throw MicrophoneDeviceError.routeChanged } }
    func start() throws { isRunning = true }
    func pause() { isRunning = false }
    func stop() { isRunning = false }
    func emitSpeech() {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for index in 0..<4_800 { buffer.floatChannelData![0][index] = 0.2 }
        onAudio?(buffer)
    }
}
