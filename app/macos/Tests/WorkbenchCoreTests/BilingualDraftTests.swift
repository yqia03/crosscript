import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualDraftTests {
    @Test func crashBeforeConfigurationRetainsBothInitialRangesAndReceivedText() throws {
        let f = try BilingualDraftFixture(); defer { f.remove() }
        var continuity = BilingualAudioContinuity()
        _ = try continuity.capture(f.chunk(start: 0))
        let draft = BilingualDraft(result: f.result(), continuity: continuity)
        try f.drafts.save(draft)
        #expect(f.drafts.recover(recordings: f.session, results: f.results).isEmpty)
        let recovered = try #require(f.results.load(f.id).first)
        #expect(recovered.id == draft.result.id && !recovered.document.isComplete)
        for channel in BilingualChannel.allCases {
            let document = channel == .source ? recovered.document.source : recovered.document.translation
            #expect(document.missingIntervals.map(\.startFrame) == [0])
            #expect(document.missingIntervals.map(\.endFrame) == [48_000])
        }
        #expect(recovered.document.source.text == "原文片段" && recovered.document.translation.text == "Partial source translation")
        #expect(try f.drafts.load(f.id) == nil && Data(contentsOf: f.store.audioURL(for: f.id)) == f.audio)
    }
    @Test func connectedCrashUsesEachConfirmedBoundaryAndRetainsUncheckpointedAudioTail() throws {
        let f = try BilingualDraftFixture(); defer { f.remove() }
        var continuity = BilingualAudioContinuity()
        let generation = continuity.attachCurrent()
        _ = try continuity.capture(f.chunk(start: 0))
        continuity.confirm(channel: .source, throughFrame: 12_000, generation: generation)
        _ = try continuity.capture(f.chunk(start: 12_000))
        try f.drafts.save(.init(result: f.result(), continuity: continuity))
        #expect(f.drafts.recover(recordings: f.session, results: f.results).isEmpty)
        let document = try #require(f.results.load(f.id).first).document
        #expect(document.source.missingIntervals.map(\.startFrame) == [12_000])
        #expect(document.translation.missingIntervals.map(\.startFrame) == [0])
        #expect(document.source.missingIntervals.last?.endFrame == 48_000)
        #expect(document.translation.missingIntervals.last?.endFrame == 48_000)
        #expect(document.alignment.count == 2 && document.source.anchors.isEmpty)
        #expect(!document.isComplete && document.completedChannels.isEmpty)
    }
    @Test func failedPublicationKeepsDraftAndIdempotentRecoveryPreservesHistoryEdits() throws {
        let f = try BilingualDraftFixture(); defer { f.remove() }
        let draft = BilingualDraft(result: f.result(), continuity: .init())
        try f.drafts.save(draft)
        let resultPath = f.store.audioURL(for: f.id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json")
        try FileManager.default.createDirectory(at: resultPath, withIntermediateDirectories: false)
        #expect(f.drafts.recover(recordings: f.session, results: f.results) == [f.id])
        #expect(try f.drafts.load(f.id) == draft)
        try FileManager.default.removeItem(at: resultPath)
        #expect(f.drafts.recover(recordings: f.session, results: f.results).isEmpty)
        let previous = try #require(f.results.load(f.id).first)
        var edited = previous; edited.document.edit("User edited recovered translation", channel: .translation)
        try f.results.saveEdit(edited, replacing: previous)
        // Simulate a crash after publish but before checkpoint deletion.
        try f.drafts.save(draft)
        #expect(f.drafts.recover(recordings: f.session, results: f.results).isEmpty)
        #expect(try f.results.load(f.id) == [edited])
        #expect(try Data(contentsOf: f.store.audioURL(for: f.id)) == f.audio)
        #expect(try f.store.loadTranscription(for: f.id).results.isEmpty)
    }
    @Test func finishedSnapshotKeepsConfirmationButUnexpectedTailRemainsIncomplete() throws {
        let f = try BilingualDraftFixture(); defer { f.remove() }
        var continuity = BilingualAudioContinuity()
        let generation = continuity.attachCurrent()
        for start in stride(from: Int64(0), to: 48_000, by: 12_000) { _ = try continuity.capture(f.chunk(start: start)) }
        for channel in BilingualChannel.allCases { continuity.confirm(channel: channel, throughFrame: 48_000, generation: generation) }
        var result = f.result(); result.document.finish()
        let draft = BilingualDraft(result: result, continuity: continuity)
        #expect(try draft.recovered(recordedEndFrame: 48_000) == result)
        let extra = try draft.recovered(recordedEndFrame: 60_000)
        #expect(!extra.document.isComplete && extra.document.completedChannels.isEmpty)
        #expect(extra.document.source.missingIntervals.first?.startFrame == 48_000)
        #expect(extra.document.translation.missingIntervals.first?.endFrame == 60_000)
        #expect(throws: AudioProcessingError.self) { try draft.recovered(recordedEndFrame: 47_999) }
    }
    @Test func unsafeCheckpointCannotReadOrReplaceAnExternalFile() throws {
        let f = try BilingualDraftFixture(); defer { f.remove() }
        let draft = BilingualDraft(result: f.result(), continuity: .init())
        let external = f.root.appendingPathComponent("retained-external.json")
        let bytes = Data("EXTERNAL RETAINED".utf8); try bytes.write(to: external)
        let path = f.store.audioURL(for: f.id).deletingLastPathComponent().appendingPathComponent("bilingual-draft.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        #expect(throws: RecordingStoreError.self) { try f.drafts.save(draft) }
        #expect(f.drafts.recover(recordings: f.session, results: f.results) == [f.id])
        #expect(try Data(contentsOf: external) == bytes && f.results.load(f.id).isEmpty)
    }
}

@MainActor private final class BilingualDraftFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-draft-\(UUID())")
    let id = UUID(), audio = Data([4, 3, 2, 1])
    let store: RecordingStore
    let session: RecordingSession
    let results: BilingualResultStore
    let drafts: BilingualDraftStore
    init() throws {
        store = RecordingStore(root: root)
        try store.save(.init(id: id, startedAt: Date(), defaultName: "Checkpoint", name: "Checkpoint", duration: 2, status: .saved))
        try audio.write(to: store.audioURL(for: id))
        session = RecordingSession(store: store, recorder: BilingualDraftRecorder())
        results = .init(recordings: store); drafts = .init(recordings: store)
    }
    func result() -> BilingualResult {
        var document = BilingualTranscriptDocument()
        document.append("原文片段", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("Partial source translation", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        return .init(recordingID: id, configuration: .init(provider: .openAI, model: "controlled-only"), direction: .chineseToEnglish, document: document)
    }
    func chunk(start: Int64) throws -> LiveAudioChunk { try .init(pcm16: Data(repeating: 0, count: 24_000), recordingStartFrame: start) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class BilingualDraftRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
