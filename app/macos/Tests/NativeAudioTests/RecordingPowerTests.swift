import Foundation
import IOKit.pwr_mgt
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

// Application commands with a controlled recorder and real macOS assertions.
// This does not replace actual idle-display, sleep or long-recording acceptance.
@Suite(.serialized)
@MainActor
struct RecordingPowerTests {
    @Test(arguments: [
        (AudioSource.microphone, false),
        (AudioSource.microphoneDevice(AudioInputDevice(uid: "controlled:external-input", name: "External microphone")), false),
        (AudioSource.system, true),
        (AudioSource.application(AudioApplication(bundleIdentifier: "test.audio-fixture", name: "Test fixture",
            processID: 123, launchDate: Date(timeIntervalSinceReferenceDate: 0))), true)
    ])
    func recordingPowerFollowsTheSourceAndCaptureCommands(source: AudioSource, keepsDisplayAwake: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-power-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = RecordingActivity()
        let session = RecordingSession(store: RecordingStore(root: directory), recorder: PowerTestRecorder(),
                                       captureActivity: activity.setActive)
        defer { session.stop() }
        session.selectSource(source)

        await session.start()
        #expect(session.isRecording)
        let id = try #require(session.activeID)
        #expect(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep))
        #expect(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep) == keepsDisplayAwake)

        await session.pause()
        #expect(session.isPaused)
        #expect(!(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep)))
        #expect(!(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)))

        await session.resume()
        #expect(session.activeID == id)
        #expect(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep) == keepsDisplayAwake)
        session.stop()
        #expect(session.selectedRecording?.status == .saved)
        #expect(session.selectedRecording?.source == source)
        #expect(!(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep)))
        #expect(!(try hasRecordingAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)))
    }

    private func hasRecordingAssertion(_ type: String) throws -> Bool {
        var result: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&result)
        #expect(status == kIOReturnSuccess)
        let dictionary = try #require(result?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        let assertions = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return assertions.contains {
            $0[kIOPMAssertionTypeKey] as? String == type &&
            $0[kIOPMAssertionNameKey] as? String == "Saving an active audio recording" &&
            $0[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn)
        }
    }
}

@MainActor
private final class PowerTestRecorder: AudioRecording {
    var currentTime: TimeInterval { 1 }
    var power: Float { -160 }
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {
        try Data([0]).write(to: url)
    }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { currentTime }
}
