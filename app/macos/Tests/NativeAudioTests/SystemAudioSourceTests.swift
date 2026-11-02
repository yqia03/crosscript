import AppKit
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized)
@MainActor
struct SystemAudioSourceTests {
    // These identity failures are checked before ScreenCaptureKit is asked for
    // content. The normal offline suite never records desktop audio or prompts.
    @Test(arguments: ["missingProcess", "differentBundle", "missingLaunch", "oldLaunch"], [false, true])
    func unavailableApplicationNeverFallsBackOrCreatesMaterial(identity: String, live: Bool) async throws {
        let source = try invalidSource(identity)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unavailable-system-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SourceRecorder()
        defer { _ = recorder.stop() }
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        if live { #expect(session.configureLiveAudio { _ in Issue.record("Unavailable source delivered live audio") }) }
        session.selectSource(source)
        await session.start(workflow: live ? .liveTranslation : .transcription)
        #expect(!session.hasActiveRecording)
        #expect(session.recordings.isEmpty)
        #expect(session.selectedSource == source)
        #expect(session.lastError != nil)
        #expect(recorder.currentTime == 0)
    }

    @Test(arguments: ["missingProcess", "differentBundle", "missingLaunch", "oldLaunch"])
    func unavailableApplicationCannotCreateAudioWhenStartedDirectly(identity: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unavailable-system-start-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("audio.caf")
        let recorder = SystemAudioRecorder()
        defer { _ = recorder.stop() }
        let source = try invalidSource(identity)
        await #expect(throws: (any Error).self) { try await recorder.start(at: destination, source: source) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(recorder.currentTime == 0)
    }

    private func invalidSource(_ identity: String) throws -> AudioSource {
        let running = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier != nil && $0.launchDate != nil
        })
        let bundle = try #require(running.bundleIdentifier)
        let launch = try #require(running.launchDate)
        return .application(AudioApplication(
            bundleIdentifier: identity == "differentBundle" ? "dev.crosscript.synthetic.nonexistent" : bundle,
            name: "Unavailable synthetic selection",
            processID: identity == "missingProcess" ? Int32.max : running.processIdentifier,
            launchDate: identity == "missingLaunch" ? nil : (identity == "oldLaunch" ? launch.addingTimeInterval(-60) : launch)))
    }
}
