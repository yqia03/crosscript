import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualDeletionTests {
    @Test func confirmedSingleAndLastDeletionKeepAudioOrdinaryTranscriptAndOtherEdits() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let first = try f.addResult("Original user edit"), second = try f.addResult("Second user edit")
        let ordinaryBefore = try Data(contentsOf: f.directory.appendingPathComponent("transcription.json"))
        let state = BilingualSessionState { try f.results.publish($0) }
        let history = state.history(recordingID: f.id, store: f.results)
        history.reload(); state.reopen(second)
        #expect(history.requestDeletion(recordingName: "Delete fixture", blockingReason: { nil }))
        let confirmation = try #require(history.pendingDeletion)
        #expect(confirmation.result.id == second.id && confirmation.resultNumber == 2 && confirmation.otherResultCount == 1)
        history.cancelDeletion()
        #expect(try f.results.load(f.id) == [first, second])
        #expect(history.requestDeletion(recordingName: "Delete fixture", blockingReason: { nil }))
        let deleted = try #require(history.confirmDeletion(blockingReason: { nil }))
        state.resultWasDeleted(recordingID: f.id, resultID: deleted)
        #expect(state.result == nil && state.cloudState == .idle && !state.needsSaveRetry)
        #expect(history.selectedID == first.id && history.sourceText == first.document.source.text)
        #expect(state.history(recordingID: f.id, store: f.results) === history)
        #expect(try f.results.load(f.id) == [first])
        #expect(history.requestDeletion(recordingName: "Delete fixture", blockingReason: { nil }))
        #expect(history.pendingDeletion?.otherResultCount == 0)
        #expect(history.confirmDeletion(blockingReason: { nil }) == first.id)
        #expect(try BilingualResultStore(recordings: f.store).load(f.id).isEmpty)
        #expect(history.results.isEmpty && history.selectedID == nil && history.exported == "\n\n")
        #expect(try Data(contentsOf: f.store.audioURL(for: f.id)) == f.audio)
        #expect(try Data(contentsOf: f.directory.appendingPathComponent("transcription.json")) == ordinaryBefore)
        #expect(try f.store.load().recordings.contains { $0.id == f.id })
        #expect(throws: BilingualResultStoreError.self) { try f.results.publish(second) }
        let fresh = try f.addResult("New independent result")
        #expect(try f.results.load(f.id) == [fresh])
        #expect(throws: BilingualResultStoreError.self) { try f.results.publish(first) }
    }

    @Test func unsavedEditsActivityAndChangedSelectionCannotDeleteThroughAnOldConfirmation() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let first = try f.addResult("First"), second = try f.addResult("Second")
        let history = BilingualHistorySession(recordingID: f.id, store: f.results); history.reload()
        history.translationText = "Unwritten user edit"
        #expect(!history.requestDeletion(recordingName: "Fixture", blockingReason: { nil }))
        #expect(history.deletionError == .unsavedChanges && history.translationText == "Unwritten user edit")
        history.discardChanges()
        var active = true
        let blocker = { active ? MaterialDeletionError.busy : nil }
        #expect(!history.requestDeletion(recordingName: "Fixture", blockingReason: blocker))
        active = false
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: blocker))
        active = true
        #expect(history.confirmDeletion(blockingReason: blocker) == nil && history.deletionError == .busy)
        active = false
        #expect(history.select(first.id))
        #expect(history.confirmDeletion(blockingReason: blocker) == nil && history.deletionError == .staleConfirmation)
        #expect(try f.results.load(f.id) == [first, second])
        history.cancelDeletion(); #expect(history.select(second.id))
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: blocker))
        history.sourceText = "Edit made after confirmation"
        #expect(history.confirmDeletion(blockingReason: blocker) == nil && history.deletionError == .unsavedChanges)
        #expect(try f.results.load(f.id) == [first, second])
    }

    @Test func concurrentSavedChangesAndFailedWritesKeepTheExactConfirmedResult() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let original = try f.addResult("Original")
        let state = BilingualSessionState { try f.results.publish($0) }
        let history = state.history(recordingID: f.id, store: f.results); history.reload(); state.reopen(original)
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: { nil }))
        var edited = original; edited.document.edit("Saved elsewhere", channel: .source)
        try f.results.saveEdit(edited, replacing: original)
        #expect(history.confirmDeletion(blockingReason: { nil }) == nil && history.deletionError == .staleConfirmation)
        #expect(try f.results.load(f.id) == [edited])
        history.cancelDeletion(); history.reload()
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: { nil }))
        let path = f.directory.appendingPathComponent("bilingual-results.json"), retained = f.directory.appendingPathComponent("retained-index.json")
        let bytes = try Data(contentsOf: path)
        try FileManager.default.moveItem(at: path, to: retained)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(history.confirmDeletion(blockingReason: { nil }) == nil && history.deletionError == .storage)
        #expect(history.selectedID == edited.id && history.sourceText == "Saved elsewhere" && state.result?.id == original.id)
        #expect(try Data(contentsOf: retained) == bytes)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: retained, to: path)
        // Keep the index readable but deny creation of the atomic replacement.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path) }
        #expect(try f.results.load(f.id) == [edited])
        #expect(history.confirmDeletion(blockingReason: { nil }) == nil && history.deletionError == .storage)
        #expect(try Data(contentsOf: path) == bytes)
        #expect(history.sourceText == "Saved elsewhere" && state.result?.id == original.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        let deleted = try #require(history.confirmDeletion(blockingReason: { nil }))
        state.resultWasDeleted(recordingID: f.id, resultID: deleted)
        #expect(state.result == nil && history.pendingDeletion == nil && history.deletionError == nil)
        #expect(try f.results.load(f.id).isEmpty)
    }

    @Test func completedRepairJournalDoesNotLockOrResurrectADeletedPublicationAfterRestart() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let original = try f.addResult("Keep source user edit", missing: true)
        var task = BilingualRepairTask(source: original, configuration: f.configuration)
        for index in task.parts.indices { task.parts[index].document = .init(text: "Controlled repaired range") }
        task.status = .completed
        try f.results.publish(task.result)
        let journal = BilingualRepairStore(recordings: f.store)
        try journal.save([task], recordingID: f.id)
        let credentials = DeletionCredentials()
        let recordings = RecordingSession(store: f.store, recorder: DeletionRecorder())
        func makeSession() -> BilingualRepairSession {
            .init(recordings: recordings, results: f.results, journal: journal, credentials: credentials,
                  service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
        }
        let repair = makeSession()
        let history = BilingualHistorySession(recordingID: f.id, store: f.results); history.reload()
        let blocker = { repair.occupiesMaterial(f.id) ? MaterialDeletionError.busy : nil }
        #expect(!repair.occupiesMaterial(f.id))
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: blocker))
        #expect(history.confirmDeletion(blockingReason: blocker) == task.resultID)
        repair.retrySaving(); #expect(repair.prepareToQuit())
        let restored = makeSession(); restored.retrySaving()
        #expect(!restored.occupiesMaterial(f.id) && restored.prepareToQuit())
        #expect(try f.results.load(f.id) == [original] && credentials.reads == 0)
        #expect(try journal.load(f.id) == [task])
        // A delayed direct publisher must also respect the durable deletion.
        #expect(throws: BilingualResultStoreError.self) { try f.results.publish(task.result) }
        #expect(try f.results.load(f.id) == [original])
    }

    @Test func deletionBlocksPendingRepairAndDoesNotClearAnUnrelatedReadingResult() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let original = try f.addResult("Original", missing: true), other = try f.addResult("Another independent version")
        var task = BilingualRepairTask(source: original, configuration: f.configuration)
        task.parts[0].document = .init(text: "Pending original fragment")
        task.pendingDocument = task.result.document; task.status = .awaitingLocalSave
        let journal = BilingualRepairStore(recordings: f.store); try journal.save([task], recordingID: f.id)
        let repair = BilingualRepairSession(recordings: RecordingSession(store: f.store, recorder: DeletionRecorder()),
            results: f.results, journal: journal, credentials: DeletionCredentials(), service: UnavailableBilingualRepair(), gate: BackgroundProcessingGate())
        let state = BilingualSessionState { try f.results.publish($0) }
        let history = state.history(recordingID: f.id, store: f.results); history.reload()
        #expect(!history.requestDeletion(recordingName: "Fixture", blockingReason: { repair.occupiesMaterial(f.id) ? .busy : nil }))
        #expect(try f.results.load(f.id) == [original, other])
        state.reopen(other)
        state.resultWasDeleted(recordingID: f.id, resultID: original.id)
        #expect(state.result == other && !state.needsSaveRetry)
    }

    @Test func deletedLiveResultRejectsLateEventsAndWholeMaterialRemovalDropsItsEditor() throws {
        let f = try BilingualDeletionFixture(); defer { f.remove() }
        let state = BilingualSessionState { try f.results.publish($0) }
        let token = try #require(state.beginObservation(recordingID: f.id, configuration: f.configuration, direction: .englishToChinese))
        state.receive(.configured, generation: token)
        state.receive(.text(channel: .source, eventID: "s", delta: "Controlled source", elapsedMilliseconds: nil), generation: token)
        state.receive(.text(channel: .translation, eventID: "t", delta: "受控译文", elapsedMilliseconds: nil), generation: token)
        state.receive(.closed, generation: token)
        let history = state.history(recordingID: f.id, store: f.results); history.reload()
        #expect(history.requestDeletion(recordingName: "Fixture", blockingReason: { nil }))
        let deleted = try #require(history.confirmDeletion(blockingReason: { nil }))
        state.resultWasDeleted(recordingID: f.id, resultID: deleted)
        state.receive(.text(channel: .source, eventID: "late", delta: "Do not restore", elapsedMilliseconds: nil), generation: token)
        state.receive(.closed, generation: token); state.retrySave()
        #expect(state.result == nil && state.prepareToQuit() && !state.needsSaveRetry)
        #expect(try f.results.load(f.id).isEmpty)
        state.forgetMaterial(f.id)
        #expect(state.history(recordingID: f.id, store: f.results) !== history)
        #expect(!state.hasUnsavedHistoryEdits && state.result == nil)
    }
}

@MainActor private final class BilingualDeletionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-delete-\(UUID())")
    let id = UUID(), audio = Data([9, 8, 7, 6])
    let configuration = AudioServiceConfiguration(provider: .openAI, model: "controlled-deletion")
    let store: RecordingStore
    let results: BilingualResultStore
    var directory: URL { store.audioURL(for: id).deletingLastPathComponent() }
    init() throws {
        store = RecordingStore(root: root); results = BilingualResultStore(recordings: store)
        try store.save(.init(id: id, startedAt: Date(), defaultName: "Delete fixture", name: "Delete fixture", duration: 4, status: .saved))
        try audio.write(to: store.audioURL(for: id))
        var material = TranscriptionMaterial()
        material.results = [.init(id: UUID(), createdAt: Date(), model: "controlled", text: "Independent ordinary transcript")]
        try store.saveTranscription(material, for: id)
    }
    func addResult(_ text: String, missing: Bool = false) throws -> BilingualResult {
        var document = BilingualTranscriptDocument()
        document.append(text, channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("旧译文用户编辑", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        if missing {
            document.addMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .source)
            document.addMissing([.init(startFrame: 48_000, endFrame: 72_000)], channel: .translation)
        }
        document.finish()
        let result = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        try results.publish(result); return result
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class DeletionCredentials: AudioCredentials {
    var reads = 0
    func read(for configuration: AudioServiceConfiguration) throws -> String? { reads += 1; return nil }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
@MainActor private final class DeletionRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
