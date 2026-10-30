import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct MaterialDeletionTests {
    @Test func wholeMaterialConfirmationIncludesBilingualEditsAndRejectsAChangedSnapshot() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let bilingual = BilingualResultStore(recordings: fixture.store)
        var document = BilingualTranscriptDocument()
        document.finish()
        document.edit("Independent source edit", channel: .source)
        document.edit("独立译文编辑", channel: .translation)
        let first = BilingualResult(recordingID: fixture.id, configuration: .init(model: "controlled-only"), direction: .englishToChinese, document: document)
        try bilingual.publish(first)
        let second = BilingualResult(recordingID: fixture.id, configuration: first.configuration, direction: first.direction, document: document)
        try bilingual.publish(second)
        var deletedIDs: [UUID] = []
        fixture.processing.didDeleteMaterial = { deletedIDs.append($0) }
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.pendingDeletion?.resultCount == 3)
        var edited = second
        edited.document.edit("Changed after confirmation", channel: .translation)
        try bilingual.saveEdit(edited, replacing: second)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .staleConfirmation)
        #expect(deletedIDs.isEmpty)
        #expect(try bilingual.load(fixture.id) == [first, edited])
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        fixture.trash.fails = true
        #expect(!fixture.processing.confirmDeletion())
        #expect(deletedIDs.isEmpty)
        fixture.trash.fails = false
        #expect(fixture.processing.confirmDeletion())
        #expect(deletedIDs == [fixture.id])
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.destination.appendingPathComponent("bilingual-results.json").path))
    }

    @Test func unreadableBilingualHistoryCannotBeReportedAsZeroOrDeletedAfterConfirmation() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.pendingDeletion?.resultCount == 0)
        let path = fixture.audio.deletingLastPathComponent().appendingPathComponent("bilingual-results.json")
        try Data("unreadable controlled index".utf8).write(to: path)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .storage)
        fixture.processing.cancelDeletion()
        #expect(!fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.pendingDeletion == nil)
        #expect(fixture.processing.deletionError == .storage)
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        #expect(try String(contentsOf: path, encoding: .utf8) == "unreadable controlled index")
    }

    @Test func confirmingOneResultPreservesOtherEditsAndAudioAfterRestart() async throws {
        let fixture = try await PostRecordingFixture(service: TimedEditingTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let first = try #require(fixture.processing.materials[fixture.id]?.results.first)
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: first.id, text: "My edited first version"))
        await fixture.processing.transcribe(fixture.id)
        let second = try #require(fixture.processing.materials[fixture.id]?.results.last)
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: second.id,
            range: NSRange(location: 6, length: 5), replacement: "everyone"))
        let retained = try #require(fixture.processing.materials[fixture.id]?.results.last)

        #expect(fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: first.id)))
        let confirmation = try #require(fixture.processing.pendingDeletion)
        #expect(confirmation.recordingName == "sample")
        #expect(confirmation.resultCount == 2)
        #expect(confirmation.resultNumber == 1)
        #expect(confirmation.result?.text == "My edited first version")
        #expect(confirmation.result?.configuration.provider == .aiHubMix)
        fixture.processing.cancelDeletion()
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.materials[fixture.id]?.results.count == 2)

        #expect(fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: first.id)))
        #expect(fixture.processing.confirmDeletion())
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Hello everyone. Next phrase.\n你好世界。"])
        #expect(reopened.materials[fixture.id]?.results.first?.id == second.id)
        #expect(reopened.materials[fixture.id]?.results.first == retained)
        #expect(reopened.materials[fixture.id]?.results.first?.paragraphs.map(\.playbackStart) == [2, 8, 14])
        let paragraph = retained.paragraphs[1]
        #expect(reopened.playbackStart(recordingID: fixture.id, resultID: second.id, paragraphRange: paragraph.range) == 8)
        let exported = fixture.root.appendingPathComponent("remaining.md")
        #expect(reopened.exportTranscript(recordingID: fixture.id, resultID: second.id, format: .markdown, includeTimestamps: true, to: exported))
        #expect(try String(contentsOf: exported, encoding: .utf8) == "[00:00:02.000] Hello everyone. \n[00:00:08.000] Next phrase.\n[00:00:14.000] 你好世界。")
        #expect(fixture.recordings.recordings.count == 1)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("sample.wav")) == fixture.bytes)
    }

    @Test func wholeMaterialMovesOnlyManagedCopyAndResultsToTrash() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        await fixture.processing.transcribe(fixture.id)
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        let confirmation = try #require(fixture.processing.pendingDeletion)
        #expect(confirmation.isImported)
        #expect(confirmation.resultCount == 2)
        #expect(confirmation.result == nil)
        fixture.processing.cancelDeletion()
        #expect(fixture.recordings.selectedID == fixture.id)
        #expect(fixture.processing.materials[fixture.id]?.results.count == 2)

        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.confirmDeletion())
        #expect(fixture.recordings.recordings.isEmpty)
        #expect(fixture.recordings.selectedID == nil)
        #expect(fixture.processing.materials[fixture.id] == nil)
        let reopened = RecordingSession(store: fixture.store, recorder: ImportUnusedRecorder())
        #expect(reopened.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        #expect(try Data(contentsOf: fixture.trash.destination.appendingPathComponent("source.wav")) == fixture.bytes)
    }

    @Test func failedResultSaveKeepsBothVersionsAndTheConfirmationCanBeRetried() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        await fixture.processing.transcribe(fixture.id)
        let results = try #require(fixture.processing.materials[fixture.id]?.results)
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: results[0].id, text: "Keep my first draft"))
        #expect(fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: results[0].id)))
        let directory = fixture.audio.deletingLastPathComponent()
        let temporarilyUnavailable = fixture.root.appendingPathComponent("Unavailable")
        try FileManager.default.moveItem(at: directory, to: temporarilyUnavailable)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .storage)
        #expect(fixture.processing.pendingDeletion != nil)
        #expect(fixture.processing.materials[fixture.id]?.results.map(\.text) == ["Keep my first draft", "Hello. 你好。"])
        #expect(!fixture.processing.hasUnsavedTranscript(recordingID: fixture.id))
        try FileManager.default.moveItem(at: temporarilyUnavailable, to: directory)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Keep my first draft", "Hello. 你好。"])
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        #expect(fixture.processing.confirmDeletion())
        #expect(fixture.processing.materials[fixture.id]?.results.map(\.id) == [results[1].id])
    }

    @Test func failedWholeMaterialMovePreservesHistoryAndAllFilesForRetry() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: "Still here after a failed deletion"))
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        fixture.trash.fails = true
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .storage)
        #expect(fixture.processing.pendingDeletion != nil)
        #expect(fixture.recordings.selectedID == fixture.id)
        let reopenedRecordings = RecordingSession(store: fixture.store, recorder: ImportUnusedRecorder())
        let reopened = PostRecordingSession(recordings: reopenedRecordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopenedRecordings.recordings.map(\.id) == [fixture.id])
        #expect(reopened.transcriptText(recordingID: fixture.id, resultID: result.id) == "Still here after a failed deletion")
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        fixture.trash.fails = false
        #expect(fixture.processing.confirmDeletion())
        #expect(fixture.recordings.recordings.isEmpty)
    }

    @Test func changedNameEditsOrNewVersionRequireAFreshConfirmation() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: result.id)))
        fixture.recordings.rename(id: fixture.id, name: "Renamed source")
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .staleConfirmation)
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: "Later edit"))
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .staleConfirmation)
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        await fixture.processing.transcribe(fixture.id)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .staleConfirmation)
        #expect(fixture.processing.materials[fixture.id]?.results.map(\.text) == ["Later edit", "Hello. 你好。"])
        #expect(fixture.recordings.selectedRecording?.name == "Renamed source")
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
    }

    @Test func failedDraftSaveBlocksBothDeletionScopesUntilItIsSaved() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        let directory = fixture.audio.deletingLastPathComponent()
        let unavailable = fixture.root.appendingPathComponent("Unavailable")
        try FileManager.default.moveItem(at: directory, to: unavailable)
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: "Unsaved user draft"))
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .unsavedChanges)
        fixture.processing.cancelDeletion()
        #expect(!fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: result.id)))
        #expect(!fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        #expect(fixture.processing.deletionError == .unsavedChanges)
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: result.id) == "Unsaved user draft")
        try FileManager.default.moveItem(at: unavailable, to: directory)
        fixture.processing.retrySaving()
        #expect(fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: result.id)))
        #expect(fixture.processing.pendingDeletion?.result?.text == "Unsaved user draft")
        fixture.processing.cancelDeletion()
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.transcriptText(recordingID: fixture.id, resultID: result.id) == "Unsaved user draft")
    }

    @Test func relatedTranscriptionBlocksDeletionAndInvalidatesEarlierConfirmation() async throws {
        let service = PausableEditingTranscriber()
        let fixture = try await MaterialDeletionFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let result = try #require(fixture.processing.selectedResult(recordingID: fixture.id))
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        await service.pause()
        let work = Task { await fixture.processing.transcribe(fixture.id) }
        while fixture.processing.runningID == nil { await Task.yield() }
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .busy)
        #expect(!fixture.processing.requestDeletion(.result(recordingID: fixture.id, resultID: result.id)))
        await service.finish()
        await work.value
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .staleConfirmation)
        #expect(fixture.processing.materials[fixture.id]?.results.count == 2)
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
    }

    @Test func deletingTheLastLegacyResultLeavesAudioAvailableForExplicitRetranscription() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        let resultID = UUID()
        let history: [String: Any] = ["results": [["id": resultID.uuidString, "createdAt": 100,
            "model": "legacy-model", "text": "旧版本的用户修改"]]]
        try JSONSerialization.data(withJSONObject: history).write(to: fixture.audio.deletingLastPathComponent().appendingPathComponent("transcription.json"))
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(processing.requestDeletion(.result(recordingID: fixture.id, resultID: resultID)))
        #expect(processing.pendingDeletion?.result?.configuration.model == "legacy-model")
        #expect(processing.confirmDeletion())
        #expect(processing.selectedResult(recordingID: fixture.id) == nil)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.isEmpty == true)
        #expect(fixture.recordings.recordings.map(\.id) == [fixture.id])
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        reopened.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await reopened.transcribe(fixture.id)
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Hello. 你好。"])
        #expect(reopened.selectedResult(recordingID: fixture.id)?.id != resultID)
    }

    @Test func recordingTransitionsPauseAndPendingRecordingSaveBlockDeletion() async throws {
        let recorder = DeletionRecorder()
        let fixture = try await MaterialDeletionFixture(recorder: recorder)
        defer { fixture.remove() }
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        let starting = Task { await fixture.recordings.start() }
        while !recorder.permissionRequested { await Task.yield() }
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .busy)
        recorder.holdPermission = false
        await starting.value
        #expect(fixture.recordings.isRecording)
        #expect(!fixture.processing.confirmDeletion())
        await fixture.recordings.pause()
        #expect(fixture.recordings.isPaused)
        #expect(!fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        let activeID = try #require(fixture.recordings.activeID)
        let metadata = fixture.recordings.audioURL(for: activeID).deletingLastPathComponent().appendingPathComponent("recording.json")
        let heldMetadata = fixture.root.appendingPathComponent("HeldMetadata.json")
        try FileManager.default.moveItem(at: metadata, to: heldMetadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        fixture.recordings.stop()
        #expect(fixture.recordings.needsSaveRetry)
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .busy)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.moveItem(at: heldMetadata, to: metadata)
        fixture.recordings.stop()
        #expect(!fixture.recordings.needsSaveRetry)
        fixture.processing.cancelDeletion()
        #expect(fixture.recordings.recordings.count == 2)
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
    }

    @Test func importingAudioBlocksPreviouslyPreparedDeletion() async throws {
        let fixture = try await MaterialDeletionFixture()
        defer { fixture.remove() }
        #expect(fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        let importer = SuspendedDeletionImporter()
        let importing = Task { await fixture.recordings.importAudio(from: fixture.source, using: importer) }
        while !fixture.recordings.isImporting { await Task.yield() }
        #expect(!fixture.processing.confirmDeletion())
        #expect(fixture.processing.deletionError == .busy)
        #expect(!fixture.processing.requestDeletion(.material(recordingID: fixture.id)))
        await importer.finish()
        await importing.value
        fixture.processing.cancelDeletion()
        #expect(fixture.recordings.recordings.count == 2)
        #expect(try Data(contentsOf: fixture.audio) == fixture.bytes)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }
}

@MainActor private final class MaterialDeletionFixture {
    let root: URL
    let source: URL
    let audio: URL
    let id: UUID
    let store: RecordingStore
    let recordings: RecordingSession
    let processing: PostRecordingSession
    let credentials = MemoryAudioCredentials()
    let bytes = Data("deletion-controlled original audio".utf8)
    let trash: ControlledMaterialTrash

    init(service: any FileTranscribing = ControlledTranscriber(), recorder: (any AudioRecording)? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.wav")
        try bytes.write(to: source)
        let trash = ControlledMaterialTrash(destination: root.appendingPathComponent("ControlledTrash"))
        self.trash = trash
        store = RecordingStore(root: root.appendingPathComponent("Recordings"), moveToTrash: { try trash.move($0) })
        recordings = RecordingSession(store: store, recorder: recorder ?? ImportUnusedRecorder())
        await recordings.importAudio(from: source, using: ControlledAudioImporter())
        id = try #require(recordings.selectedID)
        audio = recordings.audioURL(for: id)
        processing = PostRecordingSession(recordings: recordings, store: store, credentials: credentials, service: service)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ControlledMaterialTrash {
    let destination: URL
    var fails = false
    init(destination: URL) { self.destination = destination }
    func move(_ source: URL) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

@MainActor private final class DeletionRecorder: AudioRecording {
    var currentTime: TimeInterval { 12 }
    var power: Float { -120 }
    var onFailure: ((Error) -> Void)?
    var holdPermission = true
    var permissionRequested = false
    func requestPermission(for source: AudioSource) async throws {
        permissionRequested = true
        while holdPermission { await Task.yield() }
    }
    func start(at url: URL, source: AudioSource) async throws { try Data("controlled recorded audio".utf8).write(to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 12 }
}

private actor SuspendedDeletionImporter: AudioImporting {
    private var done = false
    func finish() { done = true }
    func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval {
        while !done { await Task.yield() }
        try FileManager.default.copyItem(at: source, to: destination)
        return 12
    }
}
