import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TranscriptVersionTests {
    @Test func newlyGeneratedUnsavedResultRemainsEditableAndCanBeSavedWithoutLosingOldResults() async throws {
        let service = PausableEditingTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let processing = fixture.processing
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await processing.transcribe(fixture.id)
        let old = try #require(processing.selectedResult(recordingID: fixture.id))
        #expect(processing.saveTranscriptText(recordingID: fixture.id, resultID: old.id, text: "Old user edit / 旧修改"))
        let savedOld = try #require(processing.selectedResult(recordingID: fixture.id))
        await service.pause()
        let work = Task { await processing.transcribe(fixture.id) }
        while processing.runningID == nil { await Task.yield() }
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await service.finish()
        await work.value
        let generated = try #require(processing.selectedResult(recordingID: fixture.id))
        #expect(generated.id != old.id)
        #expect(processing.hasUnsavedTranscript(recordingID: fixture.id))
        #expect(processing.canEditTranscript(recordingID: fixture.id, resultID: generated.id))
        #expect(!processing.selectResult(recordingID: fixture.id, resultID: old.id))
        #expect(!processing.saveTranscriptText(recordingID: fixture.id, resultID: generated.id, text: "New correction / 新修改"))
        #expect(processing.transcriptText(recordingID: fixture.id, resultID: generated.id) == "New correction / 新修改")
        let paragraph = try #require(processing.selectedResult(recordingID: fixture.id)?.paragraphs.first)
        #expect(!processing.replaceTranscriptParagraph(recordingID: fixture.id, resultID: generated.id,
            paragraphRange: paragraph.range, expectedText: paragraph.text,
            range: NSRange(location: 0, length: 3), replacement: "Latest"))
        #expect(processing.transcriptText(recordingID: fixture.id, resultID: generated.id) == "Latest correction / 新修改")
        let output = fixture.root.appendingPathComponent("unsaved-result.md")
        #expect(processing.exportTranscript(recordingID: fixture.id, resultID: generated.id, format: .markdown, to: output))
        #expect(try String(contentsOf: output, encoding: .utf8) == "Latest correction / 新修改")
        #expect(!processing.prepareToQuit())
        try FileManager.default.removeItem(at: path)
        #expect(processing.prepareToQuit())
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.first == savedOld)
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Old user edit / 旧修改", "Latest correction / 新修改"])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func finishingRetranscriptionCannotHideOrLockAnUnsavedEditedVersion() async throws {
        let service = PausableEditingTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let processing = fixture.processing
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        await processing.transcribe(fixture.id)
        let old = try #require(processing.selectedResult(recordingID: fixture.id))
        await service.pause()
        let work = Task { await processing.transcribe(fixture.id) }
        while processing.runningID == nil { await Task.yield() }
        let path = fixture.recordings.audioURL(for: fixture.id).deletingLastPathComponent().appendingPathComponent("transcription.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(!processing.saveTranscriptText(recordingID: fixture.id, resultID: old.id, text: "Unsaved bilingual draft / 未保存"))
        await service.finish()
        await work.value
        #expect(processing.selectedResult(recordingID: fixture.id)?.id == old.id)
        #expect(processing.canEditTranscript(recordingID: fixture.id, resultID: old.id))
        #expect(!processing.saveTranscriptText(recordingID: fixture.id, resultID: old.id, text: "Latest draft / 最新修改"))
        #expect(processing.transcriptText(recordingID: fixture.id, resultID: old.id) == "Latest draft / 最新修改")
        #expect(processing.hasUnsavedTranscript(recordingID: fixture.id))
        await processing.transcribe(fixture.id)
        #expect(processing.materials[fixture.id]?.results.count == 2)
        try FileManager.default.removeItem(at: path)
        #expect(processing.prepareToQuit())
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: ControlledTranscriber())
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Latest draft / 最新修改", "Generated source"])
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: fixture.id)) == fixture.bytes)
    }

    @Test func switchingIndependentVersionsKeepsEditsTimingAndSharedHistoryAfterRestart() async throws {
        let service = VersionTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let processing = fixture.processing
        processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-key")
        await processing.transcribe(fixture.id)
        let first = try #require(processing.selectedResult(recordingID: fixture.id))
        #expect(processing.replaceTranscriptText(recordingID: fixture.id, resultID: first.id,
            range: NSRange(location: 6, length: 6), replacement: "edited"))
        processing.saveConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize", apiKey: "other-controlled-key")
        await processing.transcribe(fixture.id)
        let second = try #require(processing.selectedResult(recordingID: fixture.id))
        #expect(second.id != first.id)
        let paragraph = second.paragraphs[0]
        #expect(processing.replaceTranscriptParagraph(recordingID: fixture.id, resultID: second.id,
            paragraphRange: paragraph.range, expectedText: paragraph.text,
            range: NSRange(location: 7, length: 6), replacement: "revised"))
        processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3-turbo", apiKey: "")
        await processing.transcribe(fixture.id)
        let third = try #require(processing.selectedResult(recordingID: fixture.id))
        processing.saveConfiguration(model: "whisper-1", apiKey: "")
        fixture.recordings.rename(id: fixture.id, name: "Shared bilingual notes / 共同笔记")
        let expectedTexts = ["First edited.", "Second revised.", "Third source."]
        let expectedStarts: [TimeInterval] = [2, 20, 40]
        let ids = [first.id, second.id, third.id]
        for (index, id) in ids.enumerated() {
            processing.selectResult(recordingID: fixture.id, resultID: id)
            let selected = try #require(processing.selectedResult(recordingID: fixture.id))
            #expect(selected.id == id)
            #expect(processing.transcriptText(recordingID: fixture.id, resultID: id) == expectedTexts[index])
            #expect(processing.playbackStart(recordingID: fixture.id, resultID: id, paragraphRange: selected.paragraphs[0].range) == expectedStarts[index])
            for format in TranscriptExportFormat.allCases {
                let output = fixture.root.appendingPathComponent("version-\(index).\(format.rawValue)")
                #expect(processing.exportTranscript(recordingID: fixture.id, resultID: id, format: format, to: output))
                #expect(try String(contentsOf: output, encoding: .utf8) == expectedTexts[index])
                #expect(processing.exportTranscript(recordingID: fixture.id, resultID: id, format: format, includeTimestamps: true, to: output))
                #expect(try String(contentsOf: output, encoding: .utf8) == ["[00:00:02.000] First edited.", "[00:00:20.000] Second revised.", "[00:00:40.000] Third source."][index])
            }
        }
        let history = RecordingSession(store: fixture.store, recorder: ImportUnusedRecorder())
        let reopened = PostRecordingSession(recordings: history, store: fixture.store, credentials: fixture.credentials, service: service)
        #expect(history.recordings.count == 1)
        #expect(history.selectedRecording?.name == "Shared bilingual notes / 共同笔记")
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == expectedTexts)
        #expect(reopened.materials[fixture.id]?.results.map(\.configuration) == [
            AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3"),
            AudioServiceConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize"),
            AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3-turbo")
        ])
        for (index, id) in ids.enumerated() {
            reopened.selectResult(recordingID: fixture.id, resultID: id)
            #expect(reopened.selectedResult(recordingID: fixture.id)?.paragraphs.first?.playbackStart == expectedStarts[index])
        }
        #expect(!reopened.selectResult(recordingID: fixture.id, resultID: UUID()))
        #expect(reopened.selectedResult(recordingID: fixture.id)?.id == third.id)
        #expect(await service.submissions == 3)
        // The next explicit request fails at the external boundary; every edited
        // version remains readable, and reopening must not retry the request.
        let beforeFailure = reopened.materials[fixture.id]?.results
        await reopened.transcribe(fixture.id)
        #expect(reopened.materials[fixture.id]?.attempt?.status == .failed)
        #expect(reopened.materials[fixture.id]?.results == beforeFailure)
        #expect(reopened.selectedResult(recordingID: fixture.id)?.id == third.id)
        let afterFailure = PostRecordingSession(recordings: history, store: fixture.store, credentials: fixture.credentials, service: service)
        #expect(afterFailure.materials[fixture.id]?.results == beforeFailure)
        #expect(afterFailure.materials[fixture.id]?.attempt?.status == .failed)
        #expect(await service.submissions == 4)
        #expect(try Data(contentsOf: history.audioURL(for: fixture.id)) == fixture.bytes)
    }
}

private actor VersionTranscriber: FileTranscribing {
    private(set) var submissions = 0
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        submissions += 1
        guard requestTimestamps, submissions <= 3 else { throw AudioProcessingError.processing }
        let text = ["First source.", "Second source.", "Third source."][submissions - 1]
        let start: TimeInterval = [2, 20, 40][submissions - 1]
        return TranscribedAudio(text: text, anchors: [TranscriptAnchor(sourceStart: start, sourceEnd: start + 1,
            range: TranscriptTextRange(location: 0, length: text.utf16.count))])
    }
}
