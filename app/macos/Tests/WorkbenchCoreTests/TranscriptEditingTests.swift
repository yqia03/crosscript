import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TranscriptEditingTests {
    @Test func editedResultReopensAndRetranscriptionKeepsItsTextAndOriginalAudio() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let resultID = try #require(fixture.processing.materials[fixture.id]?.results.first?.id)
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: resultID, text: "Edited English.\n\n已编辑的中文。"))
        await fixture.processing.transcribe(fixture.id)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Edited English.\n\n已编辑的中文。", "Hello. 你好。"])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func failedSaveRetainsLatestDraftWithoutOverwritingAnotherResult() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        await fixture.processing.transcribe(fixture.id)
        let results = try #require(fixture.processing.materials[fixture.id]?.results)
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: results[0].id, text: "Unsaved draft"))
        #expect(fixture.processing.pendingSaveID == fixture.id)
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: results[0].id) == "Unsaved draft")
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: results[1].id, text: "Must not overwrite pending"))
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: results[0].id, text: "Latest draft"))
        #expect(!fixture.processing.prepareToQuit())
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: results[0].id) == "Latest draft")
        try FileManager.default.removeItem(at: path)
        #expect(fixture.processing.prepareToQuit())
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Latest draft", "Hello. 你好。"])
        #expect(fixture.processing.pendingSaveID == nil)
    }

    @Test func copyAndExportsUseCurrentTextAndCannotOverwriteManagedAudio() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let resultID = try #require(fixture.processing.materials[fixture.id]?.results.first?.id)
        let edited = "# Notes\n\nHello 👩🏽‍💻\r\n你好。\n"
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: resultID, text: edited))
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: resultID) == edited)
        for format in TranscriptExportFormat.allCases {
            let output = fixture.root.appendingPathComponent("export.\(format.rawValue)")
            #expect(fixture.processing.exportTranscript(recordingID: fixture.id, resultID: resultID, format: format, to: output))
            #expect(try String(contentsOf: output, encoding: .utf8) == edited)
        }
        #expect(!fixture.processing.exportTranscript(recordingID: fixture.id, resultID: resultID, format: .text, to: fixture.recordings.audioURL(for: fixture.id)))
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
        #expect(!fixture.processing.exportTranscript(recordingID: fixture.id, resultID: resultID, format: .markdown, to: fixture.root))
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: resultID) == edited)
    }

    @Test func paragraphEditsSaveIntoTheSameFullTextAndRejectStaleRanges() async throws {
        let fixture = try await PostRecordingFixture(service: TimedEditingTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let original = try #require(fixture.processing.materials[fixture.id]?.results.first)
        let paragraph = original.paragraphs[1]
        #expect(fixture.processing.replaceTranscriptParagraph(recordingID: fixture.id, resultID: original.id,
            paragraphRange: paragraph.range, expectedText: paragraph.text,
            range: NSRange(location: 5, length: 6), replacement: "中文 👩🏽‍💻"))
        let edited = "Hello world. Next 中文 👩🏽‍💻.\n你好世界。"
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: original.id) == edited)
        #expect(!fixture.processing.replaceTranscriptParagraph(recordingID: fixture.id, resultID: original.id,
            paragraphRange: paragraph.range, expectedText: paragraph.text,
            range: NSRange(location: 0, length: 1), replacement: "X"))
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: TimedEditingTranscriber())
        #expect(reopened.transcriptText(recordingID: fixture.id, resultID: original.id) == edited)
        #expect(reopened.materials[fixture.id]?.results.first?.paragraphs.map(\.playbackStart) == [2, 8, 14])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func sourceSegmentsRemainReachableWithoutChangingReturnedText() async throws {
        let fixture = try await PostRecordingFixture(service: TimedEditingTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let result = try #require(fixture.processing.materials[fixture.id]?.results.first)
        #expect(result.text == "Hello world. Next phrase.\n你好世界。")
        #expect(result.paragraphs.map(\.playbackStart) == [2, 8, 14])
        #expect(result.paragraphs.map(\.text) == ["Hello world. ", "Next phrase.", "你好世界。"])
        #expect(fixture.processing.playbackStart(recordingID: fixture.id, resultID: result.id, paragraphRange: NSRange(location: 13, length: 12)) == 8)
    }

    @Test func concurrentTranscriptionAndFailedEditsKeepEveryRecordingDraft() async throws {
        let service = PausableEditingTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let firstID = fixture.id
        await fixture.processing.transcribe(firstID)
        let firstResultID = try #require(fixture.processing.materials[firstID]?.results.first?.id)
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let secondID = fixture.id
        await fixture.processing.transcribe(secondID)
        let secondResultID = try #require(fixture.processing.materials[secondID]?.results.first?.id)
        await service.pause()
        let work = Task { await fixture.processing.transcribe(firstID) }
        while fixture.processing.runningID == nil { await Task.yield() }
        let paths = [firstID, secondID].map { fixture.recordings.audioURL(for: $0).deletingLastPathComponent().appendingPathComponent("transcription.json") }
        for path in paths {
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        }
        #expect(!fixture.processing.saveTranscriptText(recordingID: firstID, resultID: firstResultID, text: "First recording draft"))
        #expect(!fixture.processing.saveTranscriptText(recordingID: secondID, resultID: secondResultID, text: "Second recording draft"))
        #expect(fixture.processing.transcriptText(recordingID: secondID, resultID: secondResultID) == "Second recording draft")
        await service.finish()
        await work.value
        for path in paths { try FileManager.default.removeItem(at: path) }
        fixture.processing.retrySaving()
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[firstID]?.results.map(\.text) == ["First recording draft", "Generated source"])
        #expect(reopened.materials[secondID]?.results.map(\.text) == ["Second recording draft"])
        #expect(fixture.processing.pendingSaveID == nil)
    }

    @Test func editsSplitMergeInsertAndDeleteWithoutInventingParagraphTimes() async throws {
        let fixture = try await PostRecordingFixture(service: TimedEditingTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let original = try #require(fixture.processing.materials[fixture.id]?.results.first)
        let originalAnchors = try #require(original.document?.anchors)
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: original.id, range: NSRange(location: 6, length: 5), replacement: "everyone"))
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: original.id, range: NSRange(location: 6, length: 0), replacement: "\n"))
        #expect(fixture.processing.materials[fixture.id]?.results.first?.paragraphs.map(\.playbackStart) == [2, nil, 8, 14])
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: original.id, range: NSRange(location: 0, length: 0), replacement: "Draft\n"))
        #expect(fixture.processing.materials[fixture.id]?.results.first?.paragraphs.map(\.playbackStart) == [nil, 2, nil, 8, 14])
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: original.id, range: NSRange(location: 12, length: 1), replacement: ""))
        let merged = try #require(fixture.processing.materials[fixture.id]?.results.first)
        #expect(merged.paragraphs.map(\.playbackStart) == [nil, 2, 8, 14])
        #expect(merged.document?.anchors.map(\.id) == originalAnchors.map(\.id))
        #expect(merged.document?.anchors.map(\.originalRange) == originalAnchors.map(\.originalRange))
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: original.id, range: NSRange(location: 22, length: 12), replacement: ""))
        let deleted = try #require(fixture.processing.materials[fixture.id]?.results.first)
        #expect(deleted.document?.anchors.map(\.sourceStart) == [2, 14])
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: original.id, text: "Entire replacement"))
        #expect(fixture.processing.materials[fixture.id]?.results.first?.paragraphs.map(\.playbackStart) == [nil])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func legacyHistoryKeepsTextAndOfficialProvenanceWithoutFabricatingTimes() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let resultID = UUID()
        let historicalText = "Legacy English.\n\n历史中文。"
        let history: [String: Any] = ["results": [["id": resultID.uuidString, "createdAt": 100, "model": "old-model", "text": historicalText]]]
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try JSONSerialization.data(withJSONObject: history).write(to: path)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: TimedEditingTranscriber())
        let old = try #require(reopened.materials[fixture.id]?.results.first)
        #expect(old.text == historicalText)
        #expect(old.configuration.provider == .openAI)
        #expect(old.paragraphs.map(\.playbackStart) == [nil, nil])
        #expect(reopened.saveTranscriptText(recordingID: fixture.id, resultID: resultID, text: "Edited legacy text"))
        reopened.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await reopened.transcribe(fixture.id, requestTimestamps: true)
        fixture.recordings.rename(id: fixture.id, name: "Renamed source")
        let after = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: TimedEditingTranscriber())
        let results = try #require(after.materials[fixture.id]?.results)
        #expect(results.map(\.text) == ["Edited legacy text", "Hello world. Next phrase.\n你好世界。"])
        #expect(results[0].configuration.provider == .openAI)
        #expect(results[0].paragraphs.map(\.playbackStart) == [nil])
        #expect(results[1].configuration.provider == .aiHubMix)
        #expect(results[1].paragraphs.map(\.playbackStart) == [2, 8, 14])
        #expect(after.materials[fixture.id]?.attempt?.requestedTimestamps == true)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func locatingALateParagraphInLongHistoryKeepsTheUIResponsive() async throws {
        let service = LongEditingTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let result = try #require(fixture.processing.materials[fixture.id]?.results.first)
        let lastParagraph = (result.text as NSString).range(of: "Paragraph 2499. ")
        try #require(lastParagraph.location != NSNotFound)
        let range = (result.text as NSString).paragraphRange(for: lastParagraph)
        // byParagraphs excludes the newline used to separate the source paragraphs.
        let paragraphRange = NSRange(location: range.location, length: range.length - 1)
        var samples: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date.timeIntervalSinceReferenceDate
            #expect(fixture.processing.playbackStart(recordingID: fixture.id, resultID: result.id, paragraphRange: paragraphRange) == 24990)
            samples.append(Date.timeIntervalSinceReferenceDate - start)
        }
        // A paragraph click must not monopolize the main thread for a playback tick (100 ms).
        #expect(samples.sorted()[2] < 0.1)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func invalidUTF16EditCannotCorruptCurrentText() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id)
        let resultID = try #require(fixture.processing.materials[fixture.id]?.results.first?.id)
        #expect(fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: resultID, text: "😀你好"))
        #expect(!fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: resultID, range: NSRange(location: 1, length: 1), replacement: "broken"))
        #expect(!fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: resultID, range: NSRange(location: Int.max, length: 1), replacement: "overflow"))
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: resultID) == "😀你好")
    }
}

actor PausableEditingTranscriber: FileTranscribing {
    private var isPaused = false
    func pause() { isPaused = true }
    func finish() { isPaused = false }
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        while isPaused { await Task.yield() }
        return "Generated source"
    }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
        progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        TranscribedAudio(text: try await transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }

}

struct TimedEditingTranscriber: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        "Hello world. Next phrase.\n你好世界。"
    }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool, progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        TranscribedAudio(text: "Hello world. Next phrase.\n你好世界。", anchors: [
            TranscriptAnchor(sourceStart: 2, sourceEnd: 5, range: TranscriptTextRange(location: 0, length: 12)),
            TranscriptAnchor(sourceStart: 8, sourceEnd: 11, range: TranscriptTextRange(location: 13, length: 12)),
            TranscriptAnchor(sourceStart: 14, sourceEnd: 16, range: TranscriptTextRange(location: 26, length: 5))
        ])
    }
}

private struct LongEditingTranscriber: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String { "Unused" }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        var text = ""
        var anchors: [TranscriptAnchor] = []
        for index in 0..<2500 {
            let paragraph = "Paragraph \(index). The long recording keeps its source timing. 中文段落。"
            anchors.append(TranscriptAnchor(sourceStart: Double(index * 10), sourceEnd: Double(index * 10 + 8),
                range: TranscriptTextRange(location: text.utf16.count, length: paragraph.utf16.count)))
            text += paragraph + "\n"
        }
        return TranscribedAudio(text: text, anchors: anchors)
    }
}
