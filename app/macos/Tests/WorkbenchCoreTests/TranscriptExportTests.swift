import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TranscriptExportTests {
    @Test func timestampedExportsUseCurrentParagraphsAndGlobalSourceTimes() async throws {
        let fixture = try await PostRecordingFixture(service: ExportTimedTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let result = try #require(fixture.processing.materials[fixture.id]?.results.first)
        let edit = (result.text as NSString).range(of: "phrase")
        #expect(fixture.processing.replaceTranscriptText(recordingID: fixture.id, resultID: result.id, range: edit, replacement: "sentence"))
        let expected = "  [00:00:02.125] First sentence. \n[00:10:00.250] Next phrase.\r\n\r\n[01:00:02.125] 中文段落。\n[Timing unavailable] 尾段。  \n"
        for format in TranscriptExportFormat.allCases {
            let output = fixture.root.appendingPathComponent("timestamped.\(format.rawValue)")
            #expect(fixture.processing.exportTranscript(recordingID: fixture.id, resultID: result.id, format: format, includeTimestamps: true, language: .english, to: output))
            #expect(try String(contentsOf: output, encoding: .utf8) == expected)
        }
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func exportingLatestUnsavedDraftKeepsSaveFailureVisibleAndProtectsAudio() async throws {
        let fixture = try await PostRecordingFixture(service: ExportTimedTranscriber())
        defer { fixture.remove() }
        fixture.processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await fixture.processing.transcribe(fixture.id, requestTimestamps: true)
        let result = try #require(fixture.processing.materials[fixture.id]?.results.first)
        let storagePath = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: storagePath)
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: false)
        let edited = "未保存的中文。\r\n\r\nEnglish draft.  \n"
        #expect(!fixture.processing.saveTranscriptText(recordingID: fixture.id, resultID: result.id, text: edited))
        let output = fixture.root.appendingPathComponent("draft.md")
        #expect(fixture.processing.exportTranscript(recordingID: fixture.id, resultID: result.id, format: .markdown, includeTimestamps: true, language: .zhHans, to: output))
        #expect(try String(contentsOf: output, encoding: .utf8) == "[无时间信息] 未保存的中文。\r\n\r\n[无时间信息] English draft.  \n")
        #expect(fixture.processing.error == .storage)
        #expect(fixture.processing.hasUnsavedTranscript(recordingID: fixture.id))
        #expect(!fixture.processing.exportTranscript(recordingID: fixture.id, resultID: result.id, format: .text, includeTimestamps: true, to: fixture.recordings.audioURL(for: fixture.id)))
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
        #expect(!fixture.processing.exportTranscript(recordingID: fixture.id, resultID: result.id, format: .markdown, includeTimestamps: true, to: fixture.root))
        #expect(fixture.processing.transcriptText(recordingID: fixture.id, resultID: result.id) == edited)
    }

    @Test func legacyHistoryExportsExactPlainTextOrExplicitMissingTimesWithoutProcessingAudio() async throws {
        let fixture = try await PostRecordingFixture()
        defer { fixture.remove() }
        let resultID = UUID()
        let text = "\r\n  旧记录 👩🏽‍💻。\r\n\r\n# English notes\n  \n"
        let history: [String: Any] = ["results": [["id": resultID.uuidString, "createdAt": 100, "model": "old-model", "text": text]]]
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try JSONSerialization.data(withJSONObject: history).write(to: path)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: fixture.credentials, service: ControlledTranscriber())
        for format in TranscriptExportFormat.allCases {
            let plain = fixture.root.appendingPathComponent("legacy-plain.\(format.rawValue)")
            #expect(reopened.exportTranscript(recordingID: fixture.id, resultID: resultID, format: format, includeTimestamps: false, language: .zhHans, to: plain))
            #expect(try Data(contentsOf: plain) == Data(text.utf8))
            let timed = fixture.root.appendingPathComponent("legacy-timed.\(format.rawValue)")
            #expect(reopened.exportTranscript(recordingID: fixture.id, resultID: resultID, format: format, includeTimestamps: true, language: .english, to: timed))
            #expect(try String(contentsOf: timed, encoding: .utf8) == "\r\n[Timing unavailable]   旧记录 👩🏽‍💻。\r\n\r\n[Timing unavailable] # English notes\n  \n")
        }
        #expect(reopened.materials[fixture.id]?.results.count == 1)
        #expect(reopened.materials[fixture.id]?.attempt == nil)
        #expect(reopened.transcriptText(recordingID: fixture.id, resultID: resultID) == text)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }
}

private struct ExportTimedTranscriber: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String { "Unused" }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        let text = "  First phrase. Next phrase.\r\n\r\n中文段落。\n尾段。  \n"
        let source = text as NSString
        let anchors = [("First phrase.", 2.125, Int64(0)), ("Next phrase.", 600.25, Int64(9_600_000)), ("中文段落。", 3602.125, Int64(57_600_000))].map { value in
            let range = source.range(of: value.0)
            return TranscriptAnchor(sourceStart: value.1, sourceEnd: value.1 + 1,
                                    range: TranscriptTextRange(location: range.location, length: range.length), chunkStartFrame: value.2)
        }
        return TranscribedAudio(text: text, anchors: anchors)
    }
}
