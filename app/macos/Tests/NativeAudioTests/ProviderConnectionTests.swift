import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct ProviderConnectionTests {
    @Test func networkFailureKeepsConfigurationAndExplicitRetryCanReturnAnUnlistedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = ProviderHTTPResponse(status: 200, body: #"{"data":[{"id":"other-model"}]}"#, transportError: .timedOut)
        let network = response.session()
        defer { network.invalidateAndCancel(); ProviderURLProtocol.response = nil }
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: NativeProviderTestCredentials(), checker: ProviderModelDirectoryChecker(session: network))
        let profile = try #require(app.saveProfile(name: "Retry", baseURL: "https://example.test", model: "unlisted-model", apiKey: "controlled-key"))
        await app.checkConnection(for: profile.id)
        #expect(app.error == .network)
        #expect(app.profiles == [profile])
        #expect(response.requests.count == 1)
        let recovered = ProviderHTTPResponse(status: 200, body: #"{"data":[{"id":"other-model"}]}"#)
        ProviderURLProtocol.response = recovered
        await app.checkConnection(for: profile.id)
        #expect(app.error == nil)
        #expect(app.connectionReports[profile.id] == .directoryAvailable(modelListed: false, modelCount: 1))
        #expect(recovered.requests.count == 1)
        #expect(app.profiles == [profile])
    }

    @Test func directoryFailuresAreClassifiedWithoutExposingServerBodiesOrRetrying() async throws {
        let cases: [(Int, String, ProviderConfigurationError)] = [
            (401, "", .credential), (403, "", .credential), (429, "", .rateLimited),
            (400, #"{"error":{"code":"model_not_found","message":"private-key-marker"}}"#, .modelUnavailable),
            (400, "", .configuration), (302, "", .configuration), (503, "", .processing), (200, "invalid-json", .processing)
        ]
        for (status, body, expected) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let response = ProviderHTTPResponse(status: status, body: body)
            let network = response.session()
            defer { network.invalidateAndCancel(); ProviderURLProtocol.response = nil }
            let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: NativeProviderTestCredentials(), checker: ProviderModelDirectoryChecker(session: network))
            let profile = try #require(app.saveProfile(name: "Keep this", baseURL: "https://example.test", model: "custom", apiKey: "controlled-key"))
            await app.checkConnection(for: profile.id)
            #expect(app.error == expected)
            #expect(app.profiles == [profile])
            #expect(app.connectionReports.isEmpty)
            #expect(response.requests.count == 1)
            #expect(app.error?.description(.english).contains("private-key-marker") == false)
        }
    }

    @Test(arguments: [404, 405, 501])
    func unsupportedDirectoryRemainsUnverifiedWithoutRejectingCustomModel(status: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = ProviderHTTPResponse(status: status, body: #"{"error":{"message":"private response must not be displayed"}}"#)
        let network = response.session()
        defer { network.invalidateAndCancel(); ProviderURLProtocol.response = nil }
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: NativeProviderTestCredentials(), checker: ProviderModelDirectoryChecker(session: network))
        let profile = try #require(app.saveProfile(name: "Custom", baseURL: "https://custom.test", model: "any-model-id", apiKey: "controlled-key"))
        await app.checkConnection(for: profile.id)
        #expect(app.error == nil)
        #expect(app.connectionReports[profile.id] == .directoryUnsupported(statusCode: status))
        #expect(app.profiles.first?.model == "any-model-id")
        #expect(response.requests.count == 1)
        #expect(response.requests.first?.url?.absoluteString == "https://custom.test/models")
    }

    @Test func savedTargetUsesItsOwnKeyAndDirectoryRequestWithoutGeneratingText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = KeychainProviderCredentials(service: "TranslationWorkbench.Tests.Providers.\(UUID().uuidString)")
        let id = UUID()
        let reference = ProviderCredentialReference(profileID: id, target: "https://provider.test/custom/v1")
        defer { try? credentials.delete(reference: reference) }
        let response = ProviderHTTPResponse(status: 200, body: #"{"data":[{"id":"chosen-model"},{"id":"other-model"}]}"#)
        let network = response.session()
        defer { network.invalidateAndCancel(); ProviderURLProtocol.response = nil }
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                               checker: ProviderModelDirectoryChecker(session: network))
        let profile = try #require(app.saveProfile(id: id, name: "Controlled provider", baseURL: "https://PROVIDER.test:443/custom/v1/chat/completions/", model: "chosen-model", apiKey: "temporary-test-key"))
        #expect(response.requests.isEmpty)
        await app.checkConnection(for: profile.id)
        #expect(app.connectionReports[id] == .directoryAvailable(modelListed: true, modelCount: 2))
        let request = try #require(response.requests.first)
        #expect(response.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://provider.test/custom/v1/models")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer temporary-test-key")
        #expect(try credentials.read(reference: ProviderCredentialReference(profileID: UUID(), target: reference.target)) == nil)
        #expect(try credentials.read(reference: ProviderCredentialReference(profileID: id, target: "https://different.test")) == nil)
        app.removeCredential(for: id)
        #expect(try credentials.read(reference: reference) == nil)
        #expect(app.profiles.first == profile)
    }
}

@MainActor private final class NativeProviderTestCredentials: ProviderCredentials {
    var values: [ProviderCredentialReference: String] = [:]
    func read(reference: ProviderCredentialReference) throws -> String? { values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
}

private final class ProviderHTTPResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [URLRequest] = []
    let status: Int
    let body: String
    let transportError: URLError.Code?
    init(status: Int, body: String, transportError: URLError.Code? = nil) {
        self.status = status; self.body = body; self.transportError = transportError
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return received }
    func record(_ request: URLRequest) { lock.lock(); received.append(request); lock.unlock() }
    func session() -> URLSession {
        ProviderURLProtocol.response = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    static var response: ProviderHTTPResponse?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        fixture.record(request)
        if let code = fixture.transportError { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
