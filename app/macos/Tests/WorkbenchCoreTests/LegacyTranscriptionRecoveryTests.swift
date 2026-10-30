import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct LegacyTranscriptionRecoveryTests {
    @Test func oldCheckpointRestoresLocallyAndKeepsAudioEditsExportAndOriginalBytes() async throws {
        let service = QueueControlledTranscriber()
        let f = try await PostRecordingFixture(service: service); defer { f.remove() }
        f.credentials.readFailure = .credential
        let id = UUID()
        let path = try checkpoint(f, resultID: id, finished: false)
        let checkpointBytes = try Data(contentsOf: path)
        let recovery = LegacyTranscriptionRecovery(recordings: f.store)
        #expect(recovery.recover(recordings: f.recordings, processing: f.processing))
        let result = try #require(f.processing.selectedResult(recordingID: f.id))
        #expect(result.id == id && result.text == "Original received text")
        #expect(result.currentDocument.missingIntervals.map(\.startFrame) == [0])
        #expect(result.currentDocument.missingIntervals.map(\.endFrame) == [Int64(f.recordings.selectedRecording!.duration * 24_000)])
        #expect(f.processing.saveTranscriptText(recordingID: f.id, resultID: id, text: "User edited old text"))
        let reopened = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: f.credentials, service: service)
        #expect(recovery.recover(recordings: f.recordings, processing: reopened))
        #expect(reopened.materials[f.id]?.results.map(\.text) == ["User edited old text"])
        let output = f.root.appendingPathComponent("old-result.md")
        #expect(reopened.exportTranscript(recordingID: f.id, resultID: id, format: .markdown, includeTimestamps: false, language: .english, to: output))
        #expect(try String(contentsOf: output, encoding: .utf8) == "User edited old text")
        #expect(try Data(contentsOf: path) == checkpointBytes)
        #expect(try Data(contentsOf: f.recordings.audioURL(for: f.id)) == f.bytes)
        #expect(await service.requestCount == 0)
        // A user-deleted recovered result must not reappear on a later launch.
        #expect(reopened.requestDeletion(.result(recordingID: f.id, resultID: id)))
        #expect(reopened.confirmDeletion())
        let afterDeletion = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: f.credentials, service: service)
        #expect(recovery.recover(recordings: f.recordings, processing: afterDeletion))
        #expect(afterDeletion.materials[f.id]?.results.isEmpty == true)
        #expect(try Data(contentsOf: path) == checkpointBytes)
    }

    @Test func failedRecoveryRetainsCheckpointAndRetriesWithoutNetwork() async throws {
        let service = QueueControlledTranscriber()
        let f = try await PostRecordingFixture(service: service); defer { f.remove() }
        let id = UUID(), path = try checkpoint(f, resultID: id, finished: true)
        let bytes = try Data(contentsOf: path)
        let target = path.deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let recovery = LegacyTranscriptionRecovery(recordings: f.store)
        #expect(!recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(try Data(contentsOf: path) == bytes)
        try FileManager.default.removeItem(at: target)
        #expect(recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(f.processing.materials[f.id]?.results.map(\.id) == [id])
        #expect(f.processing.selectedResult(recordingID: f.id)?.currentDocument.missingIntervals.isEmpty == true)
        #expect(try Data(contentsOf: path) == bytes)
        #expect(await service.requestCount == 0)
    }

    @Test func unavailableConsumptionMarkerBlocksResultDeletionUntilLocalRecoverySucceeds() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let id = UUID(), path = try checkpoint(f, resultID: id, finished: true)
        let recovery = LegacyTranscriptionRecovery(recordings: f.store)
        #expect(recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(f.processing.saveTranscriptText(recordingID: f.id, resultID: id, text: "Keep this edit"))
        let marker = path.deletingLastPathComponent().appendingPathComponent("legacy-transcription-recovered.json")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        #expect(!recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(!f.processing.requestDeletion(.result(recordingID: f.id, resultID: id)))
        #expect(f.processing.deletionError == .unsavedChanges)
        #expect(f.processing.selectedResult(recordingID: f.id)?.text == "Keep this edit")
        try FileManager.default.removeItem(at: marker)
        #expect(recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(f.processing.requestDeletion(.result(recordingID: f.id, resultID: id)))
        #expect(f.processing.confirmDeletion())
        #expect(recovery.recover(recordings: f.recordings, processing: f.processing))
        #expect(f.processing.materials[f.id]?.results.isEmpty == true)
    }

    private func checkpoint(_ f: PostRecordingFixture, resultID: UUID, finished: Bool) throws -> URL {
        let draft = LegacyTranscriptionDraft(snapshot: .init(recordingID: f.id, resultID: resultID, createdAt: Date(), source: .microphone,
            configuration: .init(provider: .aiHubMix, model: "gpt-live-transcribe")), document: .init(text: "Original received text"),
            capturedEndFrame: 0, unconfirmedStartFrame: 0, finished: finished)
        let path = f.recordings.audioURL(for: f.id).deletingLastPathComponent().appendingPathComponent("live-transcript-draft.json")
        try JSONEncoder().encode(draft).write(to: path)
        return path
    }
}
