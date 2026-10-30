import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct BilingualTranscriptTests {
    let configuration = AudioServiceConfiguration(provider: .openAI, model: "gpt-realtime-translate")
    @Test func openingEmptyHistoryClearsSavedTextButCannotDiscardActiveOrUnsavedText() throws {
        var rejectsSave = false
        let state = BilingualSessionState {
            if rejectsSave { throw AudioProcessingError.storage }
            return $0
        }
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
        state.receive(.configured, generation: token)
        state.receive(.text(channel: .source, eventID: "s", delta: "Keep this recording's text", elapsedMilliseconds: nil), generation: token)
        state.reopen(nil)
        #expect(state.document.source.text == "Keep this recording's text")
        rejectsSave = true
        state.finish()
        state.reopen(nil)
        #expect(state.needsSaveRetry && !state.document.source.text.isEmpty)
        rejectsSave = false
        state.retrySave()
        state.reopen(nil)
        #expect(state.result == nil && state.document.source.text.isEmpty && state.document.translation.text.isEmpty && state.cloudState == .idle)
    }
    @Test func quitPreflightPreservesActiveObservationUntilConfirmedStopAndFailedResultOwnsRecording() throws {
        var saved: [BilingualResult] = []
        let state = BilingualSessionState { saved.append($0); return $0 }
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
        state.receive(.configured, generation: token)
        state.receive(.text(channel: .source, eventID: "before-quit", delta: "Keep this speech", elapsedMilliseconds: nil), generation: token)
        #expect(state.prepareEditsForQuit())
        #expect(state.isActive && saved.isEmpty && !state.canReplaceResult)
        // Cancelling the quit confirmation does not finish or publish anything.
        state.receive(.text(channel: .translation, eventID: "after-cancel", delta: "继续保留", elapsedMilliseconds: nil), generation: token)
        state.receive(.failed, generation: token)
        #expect(!state.isActive && !state.needsSaveRetry && !state.canReplaceResult)
        #expect(state.prepareEditsForQuit() && !state.prepareToQuit())
        state.finish()
        #expect(state.prepareToQuit() && saved.count == 1)
        #expect(saved[0].document.source.text == "Keep this speech")
        #expect(saved[0].document.translation.text == "继续保留" && !saved[0].document.isComplete)
        state.receive(.text(channel: .translation, eventID: "late", delta: "Must be ignored", elapsedMilliseconds: nil), generation: token)
        #expect(state.document.translation.text == "继续保留")
    }

    @Test func documentedWireUsesDedicatedTargetAndDoesNotEnableUnverifiedCapture() throws {
        let wire = try LiveTranslationProtocol(configuration: configuration, direction: .englishToChinese)
        #expect(wire.webSocketURL.absoluteString.contains("/realtime/translations?"))
        let setup = try #require(JSONSerialization.jsonObject(with: wire.configurationMessage()) as? [String: Any])
        let session = try #require(setup["session"] as? [String: Any])
        #expect(session["instructions"] == nil)
        let audio = try #require(session["audio"] as? [String: Any])
        #expect((audio["output"] as? [String: Any])?["language"] as? String == "zh")
        #expect(!LiveBilingualCapability.forConfiguration(configuration).canStart)
        #expect(LiveBilingualCapability.forConfiguration(.init(provider: .aiHubMix, model: "gpt-realtime-translate")) == .unavailable)
        #expect(throws: AudioProcessingError.self) { try LiveTranslationProtocol(configuration: .init(provider: .aiHubMix), direction: .englishToChinese) }
        #expect(try wire.event(Data(#"{"type":"session.output_audio.delta","delta":"ignored audio"}"#.utf8)) == .ignored)
        #expect(try wire.event(Data(#"{"type":"session.closed"}"#.utf8)) == .closed)
    }
    @Test func sourceAndTargetDoNotPairByIndexOrTimestampAndDeltasKeepWhitespace() throws {
        let wire = try LiveTranslationProtocol(configuration: configuration, direction: .englishToChinese)
        var saved: BilingualResult?
        let state = BilingualSessionState { saved = $0; return $0 }
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
        state.receive(.configured, generation: token)
        for json in [
            #"{"type":"session.output_transcript.delta","event_id":"t1","delta":"你好","elapsed_ms":1200}"#,
            #"{"type":"session.input_transcript.delta","event_id":"s1","delta":"Hello","elapsed_ms":1200}"#,
            #"{"type":"session.input_transcript.delta","event_id":"s2","delta":" world","elapsed_ms":1200}"#,
            #"{"type":"session.output_transcript.delta","event_id":"t2","delta":"，世界"}"#] {
            state.receive(try wire.event(Data(json.utf8)), generation: token)
        }
        state.receive(.text(channel: .source, eventID: "s1", delta: "duplicate", elapsedMilliseconds: 1200), generation: token)
        #expect(state.document.source.text == "Hello world")
        #expect(state.document.translation.text == "你好，世界")
        #expect(state.document.alignment.count == 4)
        #expect(state.document.source.anchors.isEmpty && state.document.translation.anchors.isEmpty)
        #expect(state.firstSourceLatency != nil && state.firstTranslationLatency != nil)
        state.reviewEarlierText(); #expect(!state.followsLatest && state.cloudState == .connected)
        state.returnToLatest(); state.beginFinishing()
        state.receive(.text(channel: .translation, eventID: "tail", delta: "。", elapsedMilliseconds: nil), generation: token)
        state.receive(.closed, generation: token)
        #expect(saved?.document.translation.text == "你好，世界。")
        #expect(saved?.document.isComplete == true)
        state.receive(.text(channel: .source, eventID: "late", delta: "late", elapsedMilliseconds: nil), generation: token)
        #expect(state.document.source.text == "Hello world")
    }
    @Test func interruptedOrPartialBilingualStreamNeverClaimsComplete() throws {
        var document = BilingualTranscriptDocument()
        document.append("Source", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("译文片段", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.addMissing([.init(startFrame: 24_000, endFrame: 48_000)], channel: .translation)
        document.finish(completedChannels: [.source])
        #expect(!document.isComplete && document.completedChannels == [.source])
        #expect(document.translation.missingIntervals.first?.end == 2)
        let state = BilingualSessionState { $0 }
        let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .chineseToEnglish))
        state.receive(.failed, generation: token)
        #expect(!state.prepareToQuit())
        #expect(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .chineseToEnglish) == nil)
        state.finish()
        #expect(!state.document.isComplete && state.cloudState == .failed)
    }
    @Test func saveFailureKeepsEditablePendingResultAndRejectsOldGeneration() throws {
        var fail = true
        var saved: [BilingualResult] = []
        let state = BilingualSessionState { if fail { throw AudioProcessingError.storage }; saved.append($0); return $0 }
        let id = UUID(), token = try #require(state.beginObservation(recordingID: id, configuration: configuration, direction: .englishToChinese))
        state.receive(.text(channel: .source, eventID: "s", delta: "source", elapsedMilliseconds: 200), generation: token)
        state.receive(.text(channel: .translation, eventID: "t", delta: "译文", elapsedMilliseconds: 200), generation: token)
        state.finish()
        let resultID = state.result?.id
        #expect(state.needsSaveRetry && !state.prepareToQuit())
        state.editPending("user edit", channel: .translation)
        #expect(state.document.alignment.allSatisfy { $0.channel != .translation })
        #expect(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese) == nil)
        fail = false; state.retrySave()
        #expect(saved.first?.id == resultID && saved.first?.document.translation.text == "user edit")
        let next = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
        state.receive(.text(channel: .source, eventID: "late", delta: "old", elapsedMilliseconds: 400), generation: token)
        #expect(state.document.source.text.isEmpty)
        state.receive(.text(channel: .source, eventID: "new", delta: "new", elapsedMilliseconds: 200), generation: next)
        #expect(state.document.source.text == "new")
    }
    @Test func closedSourceOnlyAndUnconfirmedStopRemainIncomplete() throws {
        for closeNormally in [false, true] {
            let state = BilingualSessionState { $0 }
            let token = try #require(state.beginObservation(recordingID: UUID(), configuration: configuration, direction: .englishToChinese))
            state.receive(.text(channel: .source, eventID: "s", delta: "source", elapsedMilliseconds: nil), generation: token)
            if closeNormally { state.receive(.closed, generation: token) }
            else {
                state.receive(.text(channel: .translation, eventID: "t", delta: "partial translation", elapsedMilliseconds: nil), generation: token)
                state.finish()
            }
            #expect(!state.document.isComplete)
            #expect(state.document.completedChannels == (closeNormally ? [.source] : []))
        }
    }
    @Test func historicalEditsSurviveWriteFailureAndCannotOverwriteAnotherVersion() throws {
        var document = BilingualTranscriptDocument()
        document.append("source", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("translation", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.finish()
        let id = UUID()
        let first = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        let second = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        var stored = [first, second], fail = true
        let history = BilingualHistorySession(recordingID: id, load: { stored }, save: { edited, previous in
            if fail { throw AudioProcessingError.storage }
            guard let index = stored.firstIndex(of: previous) else { throw AudioProcessingError.storage }
            stored[index] = edited
        })
        history.reload()
        #expect(history.selectedID == second.id)
        history.translationText = "User edit"
        #expect(history.save() == nil && history.saveFailed)
        #expect(!history.select(first.id))
        history.reload()
        #expect(history.translationText == "User edit" && history.exported.contains("User edit"))
        #expect(stored == [first, second])
        fail = false
        #expect(history.save()?.document.translation.text == "User edit")
        #expect(stored[0] == first && !history.hasUnsavedChanges)
        #expect(history.select(first.id) && history.translationText == "translation")
        history.sourceText = "discard this"; history.discardChanges()
        #expect(!history.hasUnsavedChanges && history.sourceText == "source")
    }
    @Test func independentStoreRetainsAudioOtherResultsEditsAndHistoryAfterFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilingual-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingStore(root: root), id = UUID()
        try recordings.save(Recording(id: id, startedAt: Date(), defaultName: "Bilingual", name: "Bilingual", duration: 2, status: .saved))
        try Data([1, 2, 3]).write(to: recordings.audioURL(for: id))
        let store = BilingualResultStore(recordings: recordings)
        var document = BilingualTranscriptDocument()
        document.append("source", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("译文", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.finish()
        let original = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        try store.publish(original)
        let state = BilingualSessionState { try store.publish($0) }
        state.reopen(original)
        let history = state.history(recordingID: id, store: store)
        history.reload(); history.sourceText = "Retained draft"
        #expect(state.history(recordingID: id, store: store) === history)
        #expect(state.hasUnsavedHistoryEdits && state.hasUnsavedHistoryEdits(for: id))
        #expect(state.prepareToQuit())
        #expect(!state.hasUnsavedHistoryEdits)
        #expect(try store.load(id).first?.document.source.text == "Retained draft")
        #expect(state.document.source.text == "Retained draft")
        // Reopen the original immutable fixture for the independent-store checks.
        let retained = try #require(store.load(id).first)
        try store.saveEdit(original, replacing: retained)
        var edited = original; edited.document.edit("用户编辑", channel: .translation)
        try store.saveEdit(edited, replacing: original)
        #expect(try store.publish(original) == edited)
        #expect(throws: AudioProcessingError.self) { try store.saveEdit(original, replacing: original) }
        let other = BilingualResult(recordingID: id, configuration: configuration, direction: .englishToChinese, document: document)
        try store.publish(other)
        #expect(try BilingualResultStore(recordings: recordings).load(id) == [edited, other])
        #expect(try Data(contentsOf: recordings.audioURL(for: id)) == Data([1, 2, 3]))
        #expect(try recordings.loadTranscription(for: id).results.isEmpty)
        let path = recordings.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("bilingual-results.json")
        let backup = path.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: path, to: backup)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(throws: RecordingStoreError.self) { try store.publish(other) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: backup, to: path)
        #expect(try store.load(id) == [edited, other])
    }
}
