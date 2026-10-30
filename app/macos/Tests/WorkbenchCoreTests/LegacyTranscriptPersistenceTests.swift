import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct LegacyTranscriptPersistenceTests {
    @Test func legacyResultPreservesOlderEditsAndRetryIsIdempotentAfterReopen() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await service.finishAll("Original file transcript")
        await fixture.processing.transcribe(fixture.id)
        let old = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: old.id, text: "Preserved user edit"))
        let audio = try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id))
        let id = UUID(), date = Date()
        let configuration = AudioServiceConfiguration(provider: .aiHubMix, model: "gpt-live-transcribe")
        let document = TranscriptDocument(text: "Captured live source text")
        #expect(fixture.processing.saveTranscriptResult(recordingID: fixture.id, resultID: id,
            createdAt: date, configuration: configuration, document: document))
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: id, text: "Edited live version"))
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(reopened.saveTranscriptResult(recordingID: fixture.id, resultID: id,
            createdAt: date, configuration: configuration, document: document))
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Preserved user edit", "Edited live version"])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == audio)
        #expect(await service.requestCount == 1)
    }

    @Test func failedLegacyResultSaveRetainsEditsAndLocalRetryNeverStartsACloudRequest() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let id = UUID(), date = Date()
        let configuration = AudioServiceConfiguration(provider: .aiHubMix, model: "gpt-live-transcribe")
        #expect(!fixture.processing.saveTranscriptResult(recordingID: fixture.id, resultID: id,
            createdAt: date, configuration: configuration, document: TranscriptDocument(text: "Live draft")))
        #expect(fixture.processing.hasUnsavedTranscript(recordingID: fixture.id))
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: id, text: "Edited unsaved live draft"))
        #expect(!fixture.processing.prepareToQuit())
        try FileManager.default.removeItem(at: path)
        fixture.processing.retrySaving()
        #expect(fixture.processing.prepareToQuit())
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service)
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Edited unsaved live draft"])
        #expect(await service.requestCount == 0)
    }
}
