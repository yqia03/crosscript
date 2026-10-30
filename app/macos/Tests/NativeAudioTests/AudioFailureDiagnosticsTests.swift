import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

/// Replays transport/HTTP failures locally; it does not establish the cause of a real service failure.
@Suite(.serialized) @MainActor
struct AudioFailureDiagnosticsTests {
    @Test func fourthTimedRequestFailurePreservesOldEditsAndExplainsTheClientFailureAfterReopen() async throws {
        let fixture = try NativePostFixture(seconds: 1900)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let original = try Data(contentsOf: fixture.recordings.audioURL(for: id))
        let boundary = DiagnosticResponses(failAt: 8, failure: .timeout)
        let network = boundary.session()
        defer { network.invalidateAndCancel(); DiagnosticURLProtocol.responses = nil }
        let credentials = TestAudioCredentials()
        let service = OpenAIFileTranscriber(session: network)
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: service)
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-credential")
        await app.transcribe(id)
        let old = try #require(app.materials[id]?.results.first)
        #expect(app.saveTranscriptText(recordingID: id, resultID: old.id, text: "User edits. 用户修改。"))
        await app.transcribe(id, requestTimestamps: true)
        let attempt = try #require(app.materials[id]?.attempt)
        #expect(attempt.status == .failed)
        #expect(attempt.failure == .unavailable)
        #expect(attempt.completedChunks == 3)
        let diagnostics = try #require(attempt.diagnostics)
        #expect(diagnostics.origin == .transport)
        #expect(diagnostics.code == URLError.timedOut.rawValue)
        #expect(diagnostics.failedChunk == 4)
        #expect(diagnostics.elapsedSeconds.isFinite && diagnostics.elapsedSeconds >= 0)
        #expect(boundary.requestCount == 8)
        #expect(app.materials[id]?.results.count == 1)
        #expect(app.transcriptText(recordingID: id, resultID: old.id) == "User edits. 用户修改。")
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store, credentials: credentials, service: service)
        #expect(reopened.materials[id]?.attempt?.diagnostics == diagnostics)
        #expect(reopened.transcriptText(recordingID: id, resultID: old.id) == "User edits. 用户修改。")
        #expect(try Data(contentsOf: fixture.recordings.audioURL(for: id)) == original)
        let serialized = String(decoding: try JSONEncoder().encode(try #require(reopened.materials[id])), as: UTF8.self)
        #expect(!serialized.contains("private-response-marker"))
        #expect(!serialized.contains("controlled-credential"))
    }

    @Test(arguments: [404, 503])
    func rejectedRequestsRetainTheExactHTTPStatusWithoutSavingProviderMessages(status: Int) async throws {
        let fixture = try NativePostFixture(seconds: 1)
        defer { fixture.remove() }
        await fixture.recordings.importAudio(from: fixture.source, using: NativeAudioImporter())
        let id = try #require(fixture.recordings.selectedID)
        let boundary = DiagnosticResponses(failAt: 1, failure: .http(status))
        let network = boundary.session()
        defer { network.invalidateAndCancel(); DiagnosticURLProtocol.responses = nil }
        let app = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
                                       credentials: TestAudioCredentials(), service: OpenAIFileTranscriber(session: network))
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "controlled-credential")
        await app.transcribe(id, requestTimestamps: true)
        let attempt = try #require(app.materials[id]?.attempt)
        #expect(attempt.failure == .unavailable)
        #expect(attempt.completedChunks == 0)
        #expect(attempt.diagnostics?.origin == .http)
        #expect(attempt.diagnostics?.code == status)
        #expect(attempt.diagnostics?.failedChunk == 1)
        #expect(boundary.requestCount == 1)
        let serialized = String(decoding: try JSONEncoder().encode(attempt), as: UTF8.self)
        #expect(!serialized.contains("private-response-marker"))
        #expect(!serialized.contains("controlled-credential"))
    }
}

private final class DiagnosticResponses: @unchecked Sendable {
    enum Failure { case timeout, http(Int) }
    private let lock = NSLock()
    private var count = 0
    let failAt: Int
    let failure: Failure
    init(failAt: Int, failure: Failure) { self.failAt = failAt; self.failure = failure }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func nextFailure() -> Failure? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count == failAt ? failure : nil
    }
    func session() -> URLSession {
        DiagnosticURLProtocol.responses = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DiagnosticURLProtocol: URLProtocol, @unchecked Sendable {
    static var responses: DiagnosticResponses?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let boundary = Self.responses else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let status: Int
        let body: Data
        switch boundary.nextFailure() {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "private-response-marker controlled-credential"]))
            return
        case .http(let code):
            status = code
            body = Data(#"{"error":{"message":"private-response-marker controlled-credential"}}"#.utf8)
        case nil:
            status = 200
            body = Data(#"{"text":"Controlled words."}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
