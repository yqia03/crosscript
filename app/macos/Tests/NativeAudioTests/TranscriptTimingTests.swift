import AVFoundation
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

/// Controlled HTTP and generated PCM validate mechanics, never speech accuracy.
@Suite(.serialized) @MainActor
struct TranscriptTimingTests {
    @Test func diarizedFileProvidesFullTextAndPlaybackInOneRequestAndReopens() async throws {
        let fixture = try NativePostFixture(seconds: 40)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let text = "Agent: First paragraph.\nB: 第二段。"
        let boundary = TimingResponses(responses: [#"{"task":"transcribe","duration":40,"text":"Agent: First paragraph.\nB: 第二段。","segments":[{"id":"seg_001","type":"transcript.text.segment","speaker":"agent","start":0.4,"end":2.1,"text":"First paragraph."},{"id":"seg_002","type":"transcript.text.segment","speaker":"B","start":4.25,"end":7,"text":"第二段。"}]}"#])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let credentials = TestAudioCredentials()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                       service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize", apiKey: "controlled-credential")
        await app.transcribe(id)
        let result = try #require(app.materials[id]?.results.last)
        #expect(result.text == text)
        #expect(result.paragraphs.map(\.text) == ["Agent: First paragraph.", "B: 第二段。"])
        #expect(result.paragraphs.map(\.playbackStart) == [0.4, 4.25])
        #expect(boundary.requests.count == 1)
        let request = try #require(boundary.requests.first)
        #expect(request.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe-diarize\r\n"))
        #expect(request.contains("name=\"response_format\"\r\n\r\ndiarized_json\r\n"))
        #expect(request.contains("name=\"chunking_strategy\"\r\n\r\nauto\r\n"))
        #expect(!request.contains("timestamp_granularities"))
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                            service: OpenAIFileTranscriber(session: network))
        #expect(reopened.configuration.model == "gpt-4o-transcribe-diarize")
        #expect(reopened.materials[id]?.results.last == result)
        #expect(reopened.playbackStart(recordingID: id, resultID: result.id, paragraphRange: result.paragraphs[1].range) == 4.25)
        #expect(boundary.requests.count == 1)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
    }

    @Test func diarizedPartialTimingKeepsAllTextWithoutGuessingSpeakerOrRepeatedWords() async throws {
        let fixture = try NativePostFixture(seconds: 40)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let text = "A: Again.\nA: Again.\nNarrator: Unknown.\nB: Good.\nC: Overlap.\nD: Missing.\nE: Outside."
        let boundary = TimingResponses(responses: [#"{"text":"A: Again.\nA: Again.\nNarrator: Unknown.\nB: Good.\nC: Overlap.\nD: Missing.\nE: Outside.","segments":[{"speaker":"A","start":0,"end":1,"text":"Again."},{"speaker":"A","start":2,"end":3,"text":"Again."},{"speaker":"A","start":3,"end":4,"text":"Unknown."},{"speaker":"B","start":5,"end":8,"text":"Good."},{"speaker":"C","start":7,"end":9,"text":"Overlap."},{"speaker":"D","end":12,"text":"Missing."},{"speaker":"E","start":41,"end":45,"text":"Outside."}]}"#,
            #"{"text":"No segment timing returned. 保留全文。"}"#])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let credentials = TestAudioCredentials()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                       service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize", apiKey: "controlled-credential")
        await app.transcribe(id)
        let first = try #require(app.materials[id]?.results.last)
        #expect(first.text == text)
        #expect(first.paragraphs.map(\.playbackStart) == [nil, nil, nil, 5, nil, nil, nil])
        #expect(app.saveTranscriptText(recordingID: id, resultID: first.id, text: text + "\nLocal note."))
        await app.transcribe(id)
        let second = try #require(app.materials[id]?.results.last)
        #expect(second.text == "No segment timing returned. 保留全文。")
        #expect(second.currentDocument.anchors.isEmpty)
        #expect(app.transcriptText(recordingID: id, resultID: first.id) == text + "\nLocal note.")
        #expect(app.materials[id]?.results.count == 2)
        #expect(boundary.requests.count == 2)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                            service: OpenAIFileTranscriber(session: network))
        #expect(reopened.materials[id]?.results.last == second)
        #expect(reopened.transcriptText(recordingID: id, resultID: first.id) == text + "\nLocal note.")
        #expect(boundary.requests.count == 2)
    }

    @Test func aLaterTimestampChunkFailurePreservesTheEarlierEditedResult() async throws {
        let fixture = try NativePostFixture(seconds: 800)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let boundary = TimingResponses(responses: [
            #"{"text":"Old first."}"#, #"{"text":"Old second."}"#,
            #"{"text":"New first.","segments":[{"start":1,"end":2,"text":"New first."}]}"#,
            #"{"error":{"message":"untrusted provider message"}}"#
        ])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let credentials = TestAudioCredentials()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-credential")
        await app.transcribe(id)
        let old = try #require(app.materials[id]?.results.first)
        #expect(app.saveTranscriptText(recordingID: id, resultID: old.id, text: "Previously edited. 已整理。"))
        await app.transcribe(id, requestTimestamps: true)
        #expect(app.materials[id]?.attempt?.failure == .processing)
        #expect(app.materials[id]?.attempt?.completedChunks == 1)
        #expect(app.materials[id]?.results.count == 1)
        #expect(app.transcriptText(recordingID: id, resultID: old.id) == "Previously edited. 已整理。")
        #expect(boundary.requests.count == 4)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: OpenAIFileTranscriber(session: network))
        #expect(reopened.materials[id]?.attempt?.status == .failed)
        #expect(reopened.transcriptText(recordingID: id, resultID: old.id) == "Previously edited. 已整理。")
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
    }

    @Test(arguments: [AudioServiceProvider.aiHubMix, .openAI])
    func ambiguousAndInvalidSegmentsKeepEveryWordWithoutInventingLocations(provider: AudioServiceProvider) async throws {
        let fixture = try NativePostFixture(seconds: 10)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let boundary = TimingResponses(responses: [
            #"{"text":"Again.\n\nAgain.\n\nInvalid.\n\nOutside.\n\nUnmatched text.","segments":[{"start":2,"end":3,"text":"Again."},{"start":true,"end":4,"text":"Invalid."},{"start":11,"end":12,"text":"Outside."}]}"#
        ])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: provider, model: provider == .aiHubMix ? "whisper-large-v3" : "whisper-1", apiKey: "controlled-credential")
        await app.transcribe(id, requestTimestamps: true)
        let result = try #require(app.materials[id]?.results.last)
        #expect(result.text == "Again.\n\nAgain.\n\nInvalid.\n\nOutside.\n\nUnmatched text.")
        #expect(result.paragraphs.allSatisfy { $0.playbackStart == nil })
        #expect(result.configuration.provider == provider)
        #expect(boundary.requests.count == 1)
    }

    @Test(arguments: [AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3"),
                      AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3-turbo"),
                      AudioServiceConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize")])
    func longAudioUsesTheActualQuietCutRatherThanTheChunkOrdinal(configuration: AudioServiceConfiguration) async throws {
        let fixture = try NativePostFixture(seconds: 800)
        defer { fixture.remove() }
        // An independently defined signal forces the first quiet boundary to 589.8 s.
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            let file = try AVAudioFile(forWriting: fixture.source, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for second in 0..<800 {
                buffer.int16ChannelData![0].update(repeating: (590..<600).contains(second) ? 1000 : 0, count: 16_000)
                try file.write(from: buffer)
            }
        }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let boundary = TimingResponses(responses: [
            #"{"text":"Before cut.","segments":[{"id":0,"start":580,"end":585,"text":"Before cut."}]}"#,
            #"{"text":"After cut.","segments":[{"id":0,"start":10,"end":15,"text":"After cut."}]}"#
        ])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: configuration.provider, model: configuration.model, apiKey: "controlled-credential")
        await app.transcribe(id, requestTimestamps: true)
        let result = try #require(app.materials[id]?.results.last)
        #expect(result.text == "Before cut.\n\nAfter cut.")
        #expect(result.paragraphs.count == 2)
        #expect(result.paragraphs[0].playbackStart == 580)
        #expect(result.paragraphs[1].playbackStart == 599.8)
        #expect(Set(result.currentDocument.anchors.map(\.id)).count == 2)
        #expect(boundary.requests.count == 2)
    }

    @Test(arguments: [
        AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3"),
        AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-large-v3-turbo"),
        AudioServiceConfiguration(provider: .aiHubMix, model: "whisper-1"),
        AudioServiceConfiguration(provider: .openAI, model: "whisper-1")
    ])
    func oneDefaultTranscriptionProvidesFullTextAndPlaybackWithoutAnotherRequest(configuration: AudioServiceConfiguration) async throws {
        let fixture = try NativePostFixture(seconds: 10)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let boundary = TimingResponses(responses: [#"{"text":"First paragraph.\n\n第二段。","segments":[{"start":0.4,"end":2.1,"text":"First paragraph."},{"start":4.25,"end":7,"text":"第二段。"}]}"#])
        let network = boundary.session()
        defer { network.invalidateAndCancel(); TimingURLProtocol.responses = nil }
        let credentials = TestAudioCredentials()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                       service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: configuration.provider, model: configuration.model, apiKey: "controlled-credential")
        await app.transcribe(id)
        let result = try #require(app.materials[id]?.results.last)
        #expect(result.text == "First paragraph.\n\n第二段。")
        #expect(boundary.requests.count == 1)
        #expect(app.materials[id]?.attempt?.requestedTimestamps == true)
        #expect(boundary.requests.first?.contains("name=\"model\"\r\n\r\n" + configuration.model + "\r\n") == true)
        #expect(boundary.requests.first?.contains("name=\"response_format\"\r\n\r\nverbose_json") == true)
        #expect(boundary.requests.first?.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment") == true)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                            service: OpenAIFileTranscriber(session: network))
        let start = try #require(reopened.playbackStart(recordingID: id, resultID: result.id, paragraphRange: NSRange(location: 18, length: 4)))
        #expect(start == 4.25)
        let player = PlaybackController()
        try player.load(fixture.recordings.audioURL(for: id))
        player.seek(to: start)
        #expect(player.currentTime == 4.25)
        #expect(boundary.requests.count == 1)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
    }
}

private final class TimingResponses: @unchecked Sendable {
    var responses: [String]
    var requests: [String] = []
    init(responses: [String]) { self.responses = responses }
    func session() -> URLSession {
        TimingURLProtocol.responses = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    func response(_ request: URLRequest) -> Data {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        requests.append(String(decoding: body.prefix(1500), as: UTF8.self))
        return Data(responses[min(requests.count - 1, responses.count - 1)].utf8)
    }
}
private final class TimingURLProtocol: URLProtocol, @unchecked Sendable {
    static var responses: TimingResponses?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responses = Self.responses else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let data = responses.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
