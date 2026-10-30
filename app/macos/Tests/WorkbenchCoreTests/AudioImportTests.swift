import Foundation
import Testing
@testable import WorkbenchCore

@MainActor
struct AudioImportTests {
    @Test func rejectedImportLeavesExistingMaterialAndSourceUntouched() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let id = fixture.id
        let video = fixture.root.appendingPathComponent("video.mp4")
        try fixture.bytes.write(to: video)
        await fixture.recordings.importAudio(from: video, using: ControlledAudioImporter())
        #expect(fixture.recordings.recordings.count == 1)
        #expect(fixture.recordings.selectedID == id)
        #expect(fixture.recordings.lastError != nil)
        #expect(try Data(contentsOf: video) == fixture.bytes)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == fixture.bytes)
    }

    @Test func importedCopySurvivesMovingSourceAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("English lesson.wav")
        let original = Data("controlled audio fixture".utf8)
        try original.write(to: source)
        let store = RecordingStore(root: root.appendingPathComponent("Library"))
        let session = RecordingSession(store: store, recorder: ImportUnusedRecorder())
        await session.importAudio(from: source, using: ControlledAudioImporter())
        let recording = try #require(session.selectedRecording)
        #expect(recording.name == "English lesson")
        #expect(recording.duration == 12)
        #expect(recording.isImported)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("moved.wav"))
        let reopened = RecordingSession(store: store, recorder: ImportUnusedRecorder())
        #expect(reopened.recordings.count == 1)
        #expect(try Data(contentsOf: reopened.audioURL(for: recording.id)) == original)
        #expect(reopened.selectedRecording?.status == .saved)
    }
}

struct ControlledAudioImporter: AudioImporting {
    func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval {
        try FileManager.default.copyItem(at: source, to: destination)
        return 12
    }
}

@MainActor final class ImportUnusedRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }
    var power: Float { -120 }
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
