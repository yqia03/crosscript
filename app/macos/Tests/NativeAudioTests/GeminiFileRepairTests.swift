import AVFoundation
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

/// All requests terminate in URLProtocol. No credential storage or remote service is used.
@Suite(.serialized) struct GeminiFileRepairTests {
    @Test func capabilityAndTargetAndCredentialValidationPrecedeAudioOrNetwork() async throws {
        let boundary = GeminiRepairResponses()
        defer { GeminiRepairURLProtocol.responses = nil }
        let configuration = GeminiBilingualIntervalRepairer.configuration
        let closed = GeminiBilingualIntervalRepairer(sessionConfiguration: boundary.configuration())
        let open = service(boundary)
        #expect(configuration.model != AudioServiceConfiguration(provider: .gemini).model)
        #expect(configuration.credentialScope == AudioServiceConfiguration(provider: .gemini).credentialScope)
        #expect(configuration.credentialScope != AudioServiceConfiguration(provider: .openAI).credentialScope)
        #expect(!configuration.supportsSegmentTimestamps)
        let absentAudio = URL(fileURLWithPath: "/controlled-nonexistent-audio.caf")
        #expect(!closed.supports(configuration: configuration, direction: .englishToChinese))
        let invalid: [AudioServiceConfiguration] = [
            .init(provider: .gemini), .init(provider: .aiHubMix, model: configuration.model),
            .init(provider: .gemini, baseURL: "https://other.invalid/v1beta", model: configuration.model)
        ]
        for target in invalid {
            #expect(!open.supports(configuration: target, direction: .chineseToEnglish))
            await #expect(throws: AudioProcessingError.configuration) {
                try await open.repair(audio: absentAudio, interval: range(), channel: .source,
                    configuration: target, direction: .chineseToEnglish, apiKey: "fixture-only")
            }
        }
        await #expect(throws: AudioProcessingError.configuration) {
            try await closed.repair(audio: absentAudio, interval: range(), channel: .source,
                configuration: configuration, direction: .englishToChinese, apiKey: "fixture-only")
        }
        for key in ["", " \n", "fixture\r\ninjection", "fixture\tkey", "fixture\u{7f}", "fixture\u{85}"] {
            await #expect(throws: AudioProcessingError.credential) {
                try await open.repair(audio: absentAudio, interval: range(), channel: .source,
                    configuration: configuration, direction: .englishToChinese, apiKey: key)
            }
        }
        #expect(boundary.requests.isEmpty)
    }

    @Test func heapBackedASCIIKeyReachesTheControlledAdapterWithoutBeingRejected() async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses()
        let key = String(repeating: "fixture-only-", count: 4)
        let result = try await service(boundary).repair(audio: fixture.audio, interval: range(), channel: .source,
            configuration: GeminiBilingualIntervalRepairer.configuration, direction: .englishToChinese, apiKey: key)
        #expect(result.text == "completed text")
        #expect(boundary.requests.count == 1)
        #expect(boundary.requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == key)
    }

    @Test(arguments: TextTranslationDirection.allCases, BilingualChannel.allCases)
    func fixedGenerateContentContractPreservesDirectionAndChannel(direction: TextTranslationDirection, channel: BilingualChannel) async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses()
        let result = try await repair(service(boundary), audio: fixture.audio, channel: channel, direction: direction)
        #expect(result.text == "completed text")
        #expect(result.anchors.isEmpty && result.missingIntervals.isEmpty)
        let request = try #require(boundary.requests.only)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-only")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try body(request)
        #expect(body["input"] == nil && body["generation_config"] == nil && body["model"] == nil)
        let generation = try #require(body["generationConfig"] as? [String: Any])
        #expect(generation["maxOutputTokens"] as? Int == 4096)
        #expect(generation["candidateCount"] as? Int == 1)
        #expect(generation["responseMimeType"] as? String == "application/json")
        let thinking = try #require(generation["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "MINIMAL")
        #expect(thinking["includeThoughts"] as? Bool == false)
        let schema = try #require(generation["responseSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["text"])
        let parts = try parts(request)
        let prompt = try #require(parts.first?["text"] as? String)
        let source = direction == .englishToChinese ? "English" : "Chinese"
        let target = direction == .englishToChinese ? "Simplified Chinese" : "English"
        #expect(prompt.contains("\(source) speech"))
        #expect(channel == .source ? prompt.contains("Do not translate") : prompt.contains("into \(target)"))
        #expect(try wav(request).count > 44)
        #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains("fixture-only"))
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func convertedWAVContainsOnlyRequestedRangeAndLeavesOriginalUnchanged(rate: Double) async throws {
        let fixture = try GeminiRepairAudio(seconds: 3, rate: rate, amplitude: { $0 < 1 ? 0.1 : $0 < 2 ? 0.5 : 0.9 })
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let original = try Data(contentsOf: fixture.audio)
        let temporaryBefore = try temporaryCuts()
        let boundary = GeminiRepairResponses()
        _ = try await repair(service(boundary), audio: fixture.audio, interval: .init(startFrame: 24_000, endFrame: 48_000))
        let audio = try wav(#require(boundary.requests.only))
        #expect(String(decoding: audio.prefix(4), as: UTF8.self) == "RIFF")
        #expect(abs(Double(audio.count - 44) / 32_000 - 1) < 0.001)
        let samples = pcm(audio)
        // Exclude converter edge ringing while checking the interior contains no outer speech.
        #expect(samples.dropFirst(100).dropLast(100).allSatisfy { abs(Int($0) - 16_384) < 100 })
        #expect(try Data(contentsOf: fixture.audio) == original)
        #expect(try temporaryCuts() == temporaryBefore)
    }

    @Test func longIntervalUploadsEveryFrameInBoundedSequentialSlices() async throws {
        let fixture = try GeminiRepairAudio(seconds: 63, rate: 48_000, amplitude: { $0 < 61 ? 0.25 : 0.75 })
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let original = try Data(contentsOf: fixture.audio)
        let boundary = GeminiRepairResponses(replies: [.text("first"), .text("tail")])
        let result = try await repair(service(boundary), audio: fixture.audio,
            interval: .init(startFrame: 24_000, endFrame: 62 * 24_000 + 6_000))
        #expect(result.text == "first\n\ntail")
        #expect(boundary.requests.count == 2)
        let uploads = try boundary.requests.map(wav)
        #expect(uploads.allSatisfy { $0.count < 2_000_000 })
        let uploadedFrames: Int = uploads.reduce(0) { $0 + ($1.count - 44) / 2 }
        #expect(uploadedFrames == 980_000)
        #expect(pcm(try #require(uploads.last)).dropFirst(100).dropLast(100).allSatisfy { abs(Int($0) - 24_576) < 100 })
        #expect(try Data(contentsOf: fixture.audio) == original)
    }

    @Test func wholeRangeIsValidatedBeforeFirstRequest() async throws {
        let fixture = try GeminiRepairAudio(seconds: 61)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses()
        await #expect(throws: AudioProcessingError.unsupportedAudio) {
            try await repair(service(boundary), audio: fixture.audio, interval: .init(startFrame: 0, endFrame: 62 * 24_000))
        }
        #expect(boundary.requests.isEmpty)
    }

    @Test func laterSliceFailureReturnsNoPartialSuccessAndDoesNotRetryOrUploadTail() async throws {
        let fixture = try GeminiRepairAudio(seconds: 121)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let original = try Data(contentsOf: fixture.audio)
        let boundary = GeminiRepairResponses(replies: [.text("already billable"), .http(503), .text("must not upload")])
        do {
            _ = try await repair(service(boundary), audio: fixture.audio, interval: .init(startFrame: 0, endFrame: 121 * 24_000))
            Issue.record("A failed second slice cannot complete the whole part")
        } catch let failure as AudioRequestFailure {
            #expect(failure.category == .unavailable)
            #expect(failure.diagnostics.failedChunk == 2)
            #expect(failure.diagnostics.code == 503)
            #expect(!String(describing: failure).contains("private-response-marker"))
        }
        #expect(boundary.requests.count == 2)
        #expect(try Data(contentsOf: fixture.audio) == original)
    }

    @Test(arguments: ["MAX_TOKENS", "SAFETY", "CONTINUATION", "empty", "malformed", "extra", "blocked", "thoughtOnly", "twoCandidates", "missing"])
    func incompleteOrInvalidContentCannotClearTheGap(kind: String) async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.invalid(kind)])
        await #expect(throws: AudioProcessingError.processing) { try await repair(service(boundary), audio: fixture.audio) }
        #expect(boundary.requests.count == 1)
    }

    @Test func thoughtPartsAreExcludedFromTheSingleJSONDocument() async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.thoughtAndText])
        let result = try await repair(service(boundary), audio: fixture.audio)
        #expect(result.text == "visible only")
    }

    @Test(arguments: [302, 401, 403, 404, 429, 500])
    func HTTPFailuresAreNumericAndNeverEchoTheResponse(status: Int) async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.http(status)])
        do {
            _ = try await repair(service(boundary), audio: fixture.audio)
            Issue.record("Expected HTTP failure")
        } catch let failure as AudioRequestFailure {
            #expect(failure.diagnostics.code == status)
            #expect(!String(describing: failure).contains("private-response-marker"))
            #expect(!String(describing: failure).contains("fixture-only"))
        }
        #expect(boundary.requests.count == 1)
    }

    @Test func redirectCannotForwardCredentialsOrAudio() async throws {
        let fixture = try GeminiRepairAudio(seconds: 1)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.redirect])
        do {
            _ = try await repair(service(boundary), audio: fixture.audio)
            Issue.record("Expected rejected redirect")
        } catch let failure as AudioRequestFailure { #expect(failure.category == .configuration) }
        #expect(boundary.requests.count == 1)
        #expect(boundary.requests.allSatisfy { $0.url?.host == "generativelanguage.googleapis.com" })
    }

    @Test func cancellationStopsOutstandingRequestWithoutStartingNextSlice() async throws {
        let fixture = try GeminiRepairAudio(seconds: 61)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.hold])
        let adapter = service(boundary)
        let task = Task { try await repair(adapter, audio: fixture.audio, interval: .init(startFrame: 0, endFrame: 61 * 24_000)) }
        for _ in 0..<300 where boundary.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(boundary.requests.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<100 where boundary.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(boundary.stops > 0)
        #expect(boundary.requests.count == 1)
    }

    @Test @MainActor func sessionPersistsSuccessfulSlicesAndResumesOnlyUnfinishedAudio() async throws {
        let configuration = GeminiBilingualIntervalRepairer.configuration
        let fixture = try GeminiRepairAudio(seconds: 61)
        defer { fixture.remove(); GeminiRepairURLProtocol.responses = nil }
        let boundary = GeminiRepairResponses(replies: [.text("first minute retained"), .http(503), .text("last second")])
        let store = RecordingStore(root: fixture.directory.appendingPathComponent("library"))
        let id = UUID()
        try store.save(.init(id: id, startedAt: Date(), defaultName: "Repair", name: "Repair", duration: 61, status: .saved))
        try FileManager.default.copyItem(at: fixture.audio, to: store.audioURL(for: id))
        let originalAudio = try Data(contentsOf: store.audioURL(for: id))
        let results = BilingualResultStore(recordings: store)
        var document = BilingualTranscriptDocument()
        document.append("USER EDIT", channel: .source, eventID: "s", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.append("用户译文", channel: .translation, eventID: "t", elapsedMilliseconds: nil, connectionStartFrame: 0)
        document.addMissing([.init(startFrame: 0, endFrame: 61 * 24_000)], channel: .source)
        document.finish()
        let source = BilingualResult(recordingID: id, configuration: .init(provider: .gemini), direction: .englishToChinese, document: document)
        try results.publish(source)
        let credentials = FileRepairFixtureCredentials()
        let session = BilingualRepairSession(recordings: RecordingSession(store: store, recorder: FileRepairFixtureRecorder()),
            results: results, journal: BilingualRepairStore(recordings: store), credentials: credentials,
            service: service(boundary), gate: BackgroundProcessingGate())
        let taskID = try #require(session.submit(recordingID: id, sourceResultID: source.id, configuration: configuration))
        try await settle { session.runningID == nil }
        #expect(session.tasks.first?.status == .failed)
        #expect(session.tasks.first?.parts.count == 2)
        #expect(session.tasks.first?.completedCount == 1)
        var partialResults = try results.load(id)
        #expect(partialResults.count == 2)
        #expect(partialResults.first == source)
        #expect(partialResults.last?.document.source.text.contains("first minute retained") == true)
        let previous = try #require(partialResults.last)
        partialResults[partialResults.count - 1].document.edit("USER EDITED PARTIAL", channel: .source)
        try results.saveEdit(partialResults[partialResults.count - 1], replacing: previous)
        let restored = BilingualRepairSession(recordings: RecordingSession(store: store, recorder: FileRepairFixtureRecorder()),
            results: results, journal: BilingualRepairStore(recordings: store), credentials: credentials,
            service: service(boundary), gate: BackgroundProcessingGate())
        #expect(restored.runningID == nil && restored.tasks.first?.status == .failed)
        #expect(boundary.requests.count == 2)
        restored.resume(taskID)
        try await settle { restored.runningID == nil }
        #expect(restored.tasks.first?.status == .completed)
        #expect(boundary.requests.count == 3)
        #expect(try wav(#require(boundary.requests.last)).count == 32_044)
        #expect(try results.load(id).prefix(partialResults.count).elementsEqual(partialResults))
        #expect(try Data(contentsOf: store.audioURL(for: id)) == originalAudio)
        #expect(credentials.scopes == [configuration.credentialScope, configuration.credentialScope])
    }

    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }

    private func range() -> MissingInterval { .init(startFrame: 0, endFrame: 24_000) }
    private func service(_ boundary: GeminiRepairResponses) -> GeminiBilingualIntervalRepairer {
        .init(sessionConfiguration: boundary.configuration(), capabilityAllowsRepair: true)
    }
    private func repair(_ service: GeminiBilingualIntervalRepairer, audio: URL, interval: MissingInterval? = nil,
                        channel: BilingualChannel = .source, direction: TextTranslationDirection = .englishToChinese) async throws -> TranscriptDocument {
        try await service.repair(audio: audio, interval: interval ?? range(), channel: channel,
            configuration: GeminiBilingualIntervalRepairer.configuration, direction: direction, apiKey: "fixture-only")
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func parts(_ request: URLRequest) throws -> [[String: Any]] {
        let contents = try #require(body(request)["contents"] as? [[String: Any]])
        return try #require(contents.first?["parts"] as? [[String: Any]])
    }
    private func wav(_ request: URLRequest) throws -> Data {
        let inline = try #require(parts(request).last?["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == "audio/wav")
        let encoded = try #require(inline["data"] as? String)
        return try #require(Data(base64Encoded: encoded))
    }
    private func pcm(_ wav: Data) -> [Int16] {
        wav.withUnsafeBytes { raw in stride(from: 44, to: wav.count, by: 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self)) } }
    }
    private func temporaryCuts() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("workbench-gemini-repair-") })
    }
}

private struct GeminiRepairAudio {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-repair-test-\(UUID())")
    var audio: URL { directory.appendingPathComponent("source.caf") }
    init(seconds: Double, rate: Double = 24_000, amplitude: (Double) -> Float = { _ in 0.25 }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        var frame = 0
        let count = Int(seconds * rate)
        while frame < count {
            buffer.frameLength = AVAudioFrameCount(min(8192, count - frame))
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = amplitude(Double(frame + index) / rate) }
            try file.write(from: buffer)
            frame += Int(buffer.frameLength)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class GeminiRepairResponses: @unchecked Sendable {
    enum Reply { case text(String), http(Int), invalid(String), thoughtAndText, redirect, hold }
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var stopped = 0
    private let replies: [Reply]
    init(replies: [Reply] = [.text("completed text")]) { self.replies = replies }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped += 1 }
    func next(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8192); var data = Data()
            while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            copy.httpBody = data
        }
        recorded.append(copy)
        return recorded.count <= replies.count ? replies[recorded.count - 1] : .http(500)
    }
    func configuration() -> URLSessionConfiguration {
        GeminiRepairURLProtocol.responses = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiRepairURLProtocol.self]
        return configuration
    }
}

private final class GeminiRepairURLProtocol: URLProtocol, @unchecked Sendable {
    static var responses: GeminiRepairResponses?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let boundary = Self.responses else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let reply = boundary.next(request)
        var status = 200
        var content: [String: Any] = ["candidates": [candidate("{\"text\":\"completed text\"}")]]
        switch reply {
        case .hold: return
        case .redirect:
            let destination = URL(string: "https://other.invalid/never")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": destination.absoluteString])!
            var redirect = request; redirect.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        case .http(let code): status = code; content = ["error": ["message": "private-response-marker fixture-only"]]
        case .text(let text):
            let json = try! JSONSerialization.data(withJSONObject: ["text": text])
            content = ["candidates": [candidate(String(decoding: json, as: UTF8.self))]]
        case .thoughtAndText:
            content = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "private thought", "thought": true], ["text": "{\"text\":"], ["text": "\"visible only\"}"]]]]]]
        case .invalid(let kind):
            switch kind {
            case "empty": content = ["candidates": [candidate("{\"text\":\"  \"}")]]
            case "malformed": content = ["candidates": [candidate("not JSON")]]
            case "extra": content = ["candidates": [candidate("{\"text\":\"partial\",\"extra\":true}")]]
            case "blocked": content["promptFeedback"] = ["blockReason": "SAFETY"]
            case "thoughtOnly": content = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{\"text\":\"thought\"}", "thought": true]]]]]]
            case "twoCandidates": content = ["candidates": [candidate("{}"), candidate("{}")]]
            case "missing": content = [:]
            default: content = ["candidates": [candidate("{\"text\":\"partial\"}", finish: kind)]]
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: content))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func candidate(_ text: String, finish: String = "STOP") -> [String: Any] { ["finishReason": finish, "content": ["parts": [["text": text]]]] }
    override func stopLoading() { Self.responses?.stop() }
}

private extension Array { var only: Element? { count == 1 ? first : nil } }

@MainActor private final class FileRepairFixtureCredentials: AudioCredentials {
    var scopes: [String] = []
    func read(for configuration: AudioServiceConfiguration) throws -> String? { scopes.append(configuration.credentialScope); return "fixture-only" }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws {}
    func delete(for configuration: AudioServiceConfiguration) throws {}
}
@MainActor private final class FileRepairFixtureRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }; var power: Float { -160 }; var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}
