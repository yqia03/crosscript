import Combine
import Foundation
import Testing
@testable import WorkbenchCore

@MainActor struct RecordingTelemetryTests {
    @Test func audioMeterUpdatesDoNotInvalidateRecordingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = TelemetryRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        await session.start()
        try #require(session.isRecording)
        var notifications = 0
        let observation = session.objectWillChange.sink { notifications += 1 }
        recorder.currentTime = 3.25
        recorder.power = -12
        try await Task.sleep(for: .milliseconds(650))
        print("RECORDING_TELEMETRY metadataInvalidations=\(notifications), elapsed=\(session.elapsed), level=\(session.inputLevel)")
        #expect(session.elapsed == 3.25)
        #expect(session.inputLevel > 0.2)
        #expect(notifications == 0, "Metering must update only its own display, not rebuild every open workspace.")
        observation.cancel()
        session.stop()
        #expect(session.selectedRecording?.duration == 3.25)
    }
}

@MainActor private final class TelemetryRecorder: AudioRecording {
    var currentTime: TimeInterval = 0
    var power: Float = -160
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { try Data([0]).write(to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { currentTime }
}
