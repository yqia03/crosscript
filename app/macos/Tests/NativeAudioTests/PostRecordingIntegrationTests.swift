import AVFoundation
import Foundation
import Testing
import Security
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct PostRecordingIntegrationTests {
    @Test func reopeningLiveAndRepairedResultsShowsTheirSavedStatusWithoutFileAttempt() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let credentials = TestAudioCredentials()
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: OpenAIFileTranscriber())
        let originalID = UUID(), repairedID = UUID()
        #expect(app.saveTranscriptResult(recordingID: id, resultID: originalID, createdAt: Date(),
            configuration: .init(provider: .aiHubMix, model: "gpt-live-transcribe"),
            document: TranscriptDocument(text: "Retained original", missingIntervals: [.init(startFrame: 0, endFrame: 12_000)])))
        #expect(app.saveTranscriptResult(recordingID: id, resultID: repairedID, createdAt: Date(),
            configuration: .init(provider: .aiHubMix, model: "whisper-large-v3-turbo"),
            document: TranscriptDocument(text: "Independent repaired version")))
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: credentials, service: OpenAIFileTranscriber())
        #expect(reopened.materials[id]?.attempt == nil)
        #expect(reopened.statusTitle(for: id, language: .english) == "Transcript saved")
        reopened.selectResult(recordingID: id, resultID: originalID)
        #expect(reopened.statusTitle(for: id, language: .zhHans) == "已保存 · 有文字待补齐")
        #expect(reopened.selectedResult(recordingID: id)?.text == "Retained original")
    }

    @Test(arguments: [
        ("https://gateway.example/", "https://gateway.example/v1/audio/transcriptions"),
        ("https://gateway.example/v1", "https://gateway.example/v1/audio/transcriptions"),
        ("https://GATEWAY.example:443/v1/audio/transcriptions/", "https://gateway.example/v1/audio/transcriptions"),
        ("https://gateway.example/audio/transcriptions", "https://gateway.example/audio/transcriptions"),
        ("https://gateway.example/proxy/audio/transcriptions", "https://gateway.example/proxy/audio/transcriptions"),
        ("https://gateway.example/proxy/v1/audio/transcriptions", "https://gateway.example/proxy/v1/audio/transcriptions")
    ])
    func legacyCompatibleAddressRemainsVisibleButCannotUpload(address: String, endpoint: String) async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let legacy = AudioServiceConfiguration(provider: .compatible, baseURL: address, model: "whisper-large-v3")
        let settings: [String: Any] = ["version": 2, "selected": "compatible", "profiles": [["provider": "compatible", "baseURL": address, "model": "whisper-large-v3"]]]
        let settingsURL = fixture.recordings.audioURL(for: id).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("audio-configuration.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let credentials = TestAudioCredentials()
        try credentials.save("legacy-only-key", for: legacy.validated())
        let observed = RequestObservations()
        AudioURLProtocol.observe = observed
        let networkConfiguration = URLSessionConfiguration.ephemeral
        networkConfiguration.protocolClasses = [AudioURLProtocol.self]
        let network = URLSession(configuration: networkConfiguration)
        defer { network.invalidateAndCancel(); AudioURLProtocol.observe = nil }
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                       service: OpenAIFileTranscriber(session: network))
        #expect(try app.configuration.transcriptionURL().absoluteString == endpoint)
        #expect(app.credentialAvailability == .unchecked)
        #expect(credentials.readCount == 0)
        await app.transcribe(id)
        #expect(app.error == .unsupportedConfiguration)
        #expect(app.credentialAvailability == .unchecked)
        #expect(credentials.readCount == 0)
        #expect(app.materials[id]?.attempt == nil)
        #expect(app.materials[id]?.results.isEmpty != false)
        #expect(observed.count == 0)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                            service: OpenAIFileTranscriber(session: network))
        #expect(try reopened.configuration.transcriptionURL().absoluteString == endpoint)
        #expect(reopened.configuration.provider == .compatible)
        #expect(reopened.credentialAvailability == .unchecked)
        #expect(credentials.readCount == 0)
    }

    @Test func legacyKeychainItemStaysOfficialAndOtherTargetsRemainIsolated() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        let serviceName = "TranslationWorkbench.T5IsolationTest." + UUID().uuidString
        let legacyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName, kSecAttrAccount as String: "api-key",
            kSecValueData as String: Data("disposable-official-test-value".utf8)]
        #expect(SecItemAdd(legacyQuery as CFDictionary, nil) == errSecSuccess)
        let credentials = KeychainAudioCredentials(service: serviceName)
        let aihub = AudioServiceConfiguration(provider: .aiHubMix)
        let custom = AudioServiceConfiguration(provider: .compatible, baseURL: "https://other.example/v1", model: "whisper-large-v3")
        defer {
            for profile in [AudioServiceConfiguration(), aihub, custom] { try? credentials.delete(for: profile) }
        }
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: OpenAIFileTranscriber())
        #expect(app.credentialAvailability == .unchecked)
        app.saveConfiguration(model: "whisper-1", apiKey: "")
        #expect(app.hasCredential)
        app.saveConfiguration(provider: .aiHubMix, model: aihub.model, apiKey: "")
        #expect(app.hasCredential == false)
        app.saveConfiguration(provider: .aiHubMix, model: aihub.model, apiKey: "disposable-aihub-test-value")
        #expect(try credentials.read(for: custom) == nil)
        try credentials.save("disposable-custom-test-value", for: custom)
        try credentials.delete(for: custom)
        app.saveConfiguration(provider: .aiHubMix, model: aihub.model, apiKey: "")
        #expect(app.hasCredential)
        #expect(try credentials.read(for: aihub) == "disposable-aihub-test-value")
        app.saveConfiguration(model: "whisper-1", apiKey: "")
        #expect(app.hasCredential)
        #expect(try credentials.read(for: AudioServiceConfiguration()) == "disposable-official-test-value")
    }

    @Test(arguments: [
        (403, "insufficient_user_quota", "quotaExceeded"),
        (429, "rate_limit_exceeded", "requestLimited"),
        (404, "model_not_found", "modelUnavailable"),
        (403, "unrecognized_secret_code", "credential"),
        (429, "unrecognized_secret_code", "rateLimited")
    ])
    func aiHubMixErrorsUseSafeCodesAndRequireManualRetry(status: Int, code: String, expected: String) async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let observed = RequestObservations()
        observed.status = status
        observed.errorCode = code
        observed.expectedURL = "https://aihubmix.com/v1/audio/transcriptions"
        observed.expectedModel = "whisper-large-v3"
        AudioURLProtocol.observe = observed
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel(); AudioURLProtocol.observe = nil }
        let credentials = TestAudioCredentials()
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                              service: OpenAIFileTranscriber(session: network))
        processing.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-credential")
        await processing.transcribe(id)
        #expect(observed.validProtocol)
        #expect(processing.materials[id]?.attempt?.failure?.rawValue == expected)
        #expect(processing.materials[id]?.results.isEmpty == true)
        #expect(processing.materials[id]?.attempt?.completedChunks == 0)
        let message = processing.materials[id]?.attempt?.failure?.localizedDescription ?? ""
        #expect(message.contains("controlled-credential") == false)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                            service: OpenAIFileTranscriber(session: network))
        #expect(reopened.materials[id]?.attempt?.failure?.rawValue == expected)
        #expect(reopened.runningID == nil)
        observed.status = 200
        observed.errorCode = nil
        await reopened.transcribe(id)
        #expect(reopened.materials[id]?.results.last?.text == "Part 2.")
        #expect(reopened.materials[id]?.results.last?.configuration.provider == .aiHubMix)
    }

    @Test func savedRecordingCanBeTranscribedAfterCaptureEnds() async throws {
        let fixture = try NativePostFixture(seconds: 3, sampleRate: 48_000, channels: 2, fileExtension: "caf")
        defer { fixture.remove() }
        let recordings = RecordingSession(store: fixture.store, recorder: FixtureFileRecorder(source: fixture.source))
        let observed = RequestObservations()
        AudioURLProtocol.observe = observed
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel(); AudioURLProtocol.observe = nil }
        let processing = PostRecordingSession(recordings: recordings, store: fixture.store, credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        await recordings.start()
        let id = try #require(recordings.activeID)
        await processing.transcribe(id)
        #expect(processing.materials[id]?.attempt == nil)
        recordings.stop()
        await processing.transcribe(id)
        #expect(processing.materials[id]?.results.last?.text == "Part 1.")
        #expect(observed.audioBytes == 96_000)
        #expect(recordings.selectedRecording?.isImported == false)
        #expect(recordings.selectedRecording?.status == .saved)
    }

    @Test func asynchronousKeychainReadsPreserveTargetIsolationAndRespectCancellation() async throws {
        let credentials = KeychainAudioCredentials(service: "TranslationWorkbench.AsyncReadTest." + UUID().uuidString)
        let official = AudioServiceConfiguration()
        let gemini = AudioServiceConfiguration(provider: .gemini)
        defer {
            try? credentials.delete(for: official)
            try? credentials.delete(for: gemini)
        }
        try credentials.save("disposable-official-async-value", for: official)
        try credentials.save("disposable-gemini-async-value", for: gemini)
        #expect(try await credentials.readAsync(for: official) == "disposable-official-async-value")
        #expect(try await credentials.readAsync(for: gemini) == "disposable-gemini-async-value")
        let cancelled = Task { @MainActor in try await credentials.readAsync(for: gemini) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled credential read returned a value") }
        catch { #expect(error is CancellationError) }
        #expect(try credentials.read(for: official) == "disposable-official-async-value")
    }

    @Test func systemKeychainConfigurationCanBeReopenedAndRemoved() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        let serviceName = "TranslationWorkbench.T5Test." + UUID().uuidString
        let credentials = KeychainAudioCredentials(service: serviceName)
        defer { try? credentials.delete(for: AudioServiceConfiguration()) }
        let session = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                           credentials: credentials, service: OpenAIFileTranscriber())
        session.saveConfiguration(model: "whisper-1", apiKey: "non-secret-disposable-test-value")
        #expect(session.hasCredential)
        #expect(session.error == nil)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                            credentials: KeychainAudioCredentials(service: serviceName), service: OpenAIFileTranscriber())
        #expect(reopened.credentialAvailability == .unchecked)
        reopened.removeCredential()
        #expect(reopened.credentialAvailability == .missing)
        #expect(try credentials.read(for: AudioServiceConfiguration()) == nil)
    }

    @Test(arguments: [AudioServiceProvider.openAI, .aiHubMix])
    func longImportedAudioUsesSelectedServiceAndPreservesEveryFrame(provider: AudioServiceProvider) async throws {
        let fixture = try NativePostFixture(seconds: 800)
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        #expect(original.count > 25_000_000)
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let observed = RequestObservations()
        let selected = AudioServiceConfiguration(provider: provider)
        observed.expectedURL = try selected.transcriptionURL().absoluteString
        observed.expectedModel = selected.model
        AudioURLProtocol.observe = observed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioURLProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel(); AudioURLProtocol.observe = nil }
        let credentials = TestAudioCredentials()
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials,
                                              service: OpenAIFileTranscriber(session: network))
        processing.saveConfiguration(provider: provider, baseURL: selected.baseURL, model: selected.model, apiKey: "controlled-credential")
        try FileManager.default.removeItem(at: fixture.source)
        await processing.transcribe(id)
        #expect(processing.materials[id]?.attempt?.status == .completed)
        #expect(processing.materials[id]?.results.last?.text == "Part 1.\n\nPart 2.")
        #expect(observed.validProtocol)
        #expect(observed.audioBytes == 25_600_000)
        #expect(observed.maximumFileBytes < 25_000_000)
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 400, 200])
    func officialErrorsAreSafeAndRetryable(status: Int) async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let observed = RequestObservations()
        observed.status = status
        observed.invalidJSON = true
        AudioURLProtocol.observe = observed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioURLProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel(); AudioURLProtocol.observe = nil }
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                              credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-credential")
        await processing.transcribe(id)
        let expected: AudioProcessingError = [401: .credential, 403: .credential, 404: .unavailable, 429: .rateLimited, 500: .unavailable][status] ?? .processing
        #expect(processing.materials[id]?.attempt?.failure == expected)
        #expect(processing.materials[id]?.results.isEmpty == true)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        #expect(reopened.materials[id]?.attempt?.failure == expected)
        #expect(!expected.localizedDescription.contains("controlled-credential"))
        observed.status = 200
        observed.invalidJSON = false
        await reopened.transcribe(id)
        #expect(reopened.materials[id]?.attempt?.status == .completed)
        let player = PlaybackController()
        try player.load(fixture.recordings.audioURL(for: id))
        #expect(player.duration > 0)
    }

    @Test func importedSymbolicLinkBecomesIndependentPlayableAudio() async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("chosen.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        await fixture.recordings.importAudio(from: link, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let imported = try #require(fixture.recordings.selectedRecording)
        #expect(imported.sourceTitle(using: WorkbenchLanguage(choice: .english)) == "Imported audio")
        #expect(imported.sourceTitle(using: WorkbenchLanguage(choice: .zhHans)) == "导入音频")
        try FileManager.default.removeItem(at: fixture.source)
        let player = PlaybackController()
        try player.load(fixture.recordings.audioURL(for: id))
        #expect(abs(player.duration - 1) < 0.001)
        let reopened = RecordingSession(store: fixture.store, recorder: NoCaptureRecorder())
        #expect(reopened.recordings.count == 1)
    }
}

@MainActor final class NativePostFixture {
    let root: URL
    let source: URL
    let store: RecordingStore
    let recordings: RecordingSession
    init(seconds: Int, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1, fileExtension: String = "wav") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("sample." + fileExtension)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)!
        let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
        buffer.frameLength = AVAudioFrameCount(sampleRate)
        memset(buffer.int16ChannelData![0], 0, Int(sampleRate) * Int(channels) * 2)
        for _ in 0..<seconds { try file.write(from: buffer) }
        store = RecordingStore(root: root.appendingPathComponent("Recordings"))
        recordings = RecordingSession(store: store, recorder: NoCaptureRecorder())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor final class NoCaptureRecorder: AudioRecording {
    var currentTime: TimeInterval { 0 }
    var power: Float { -120 }
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 0 }
}

@MainActor final class TestAudioCredentials: AudioCredentials {
    var keys = [AudioServiceConfiguration().credentialScope: "controlled-credential"]
    private(set) var readCount = 0
    func read(for configuration: AudioServiceConfiguration) throws -> String? {
        readCount += 1
        return keys[configuration.credentialScope]
    }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = value }
    func delete(for configuration: AudioServiceConfiguration) throws { keys[configuration.credentialScope] = nil }
}

final class RequestObservations: @unchecked Sendable {
    private let lock = NSLock()
    var status = 200
    var invalidJSON = false
    var errorCode: String?
    var expectedURL = "https://api.openai.com/v1/audio/transcriptions"
    var expectedModel = "whisper-1"
    private(set) var validProtocol = true
    private(set) var audioBytes = 0
    private(set) var maximumFileBytes = 0
    private(set) var count = 0
    func response(to request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                body.append(contentsOf: buffer.prefix(size))
            }
        }
        validProtocol = validProtocol && request.url?.absoluteString == expectedURL
            && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer controlled-credential"
            && body.range(of: Data(expectedModel.utf8)) != nil
            && body.range(of: Data("name=\"response_format\"\r\n\r\nverbose_json".utf8)) != nil
        if let start = body.range(of: Data("RIFF".utf8))?.lowerBound, body.count > start + 44 {
            let count = body.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: start + 40, as: UInt32.self))) }
            audioBytes += count
            maximumFileBytes = max(maximumFileBytes, count + 44)
            validProtocol = validProtocol && body.subdata(in: start+8..<start+12) == Data("WAVE".utf8)
        } else { validProtocol = false }
        if let errorCode {
            return (status, try! JSONSerialization.data(withJSONObject: ["error": ["code": errorCode, "message": "controlled-credential must never be exposed"]]))
        }
        let text = invalidJSON ? "controlled-credential raw provider error" : "{\"text\":\"Part \(count).\"}"
        return (status, Data(text.utf8))
    }
}

final class AudioURLProtocol: URLProtocol, @unchecked Sendable {
    static var observe: RequestObservations?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let observe = Self.observe else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, data) = observe.response(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class FixtureFileRecorder: AudioRecording {
    let source: URL
    init(source: URL) { self.source = source }
    var currentTime: TimeInterval { 3 }
    var power: Float { -120 }
    var onFailure: ((Error) -> Void)?
    func requestPermission(for source: AudioSource) async throws {}
    func start(at url: URL, source: AudioSource) async throws { try FileManager.default.copyItem(at: self.source, to: url) }
    func pause() async throws {}
    func resume() async throws {}
    func stop() -> TimeInterval { 3 }
}
