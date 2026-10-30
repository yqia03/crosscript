import Foundation
import WorkbenchCore

private final class ProviderDirectoryRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ProviderModelDirectoryChecker: ProviderConnectionChecking {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config, delegate: ProviderDirectoryRedirectPolicy(), delegateQueue: nil)
        }
    }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        let snapshot = try snapshot.validated()
        var request = URLRequest(url: try snapshot.modelsURL())
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ProviderConfigurationError.processing }
        guard response.url == request.url else { throw ProviderConfigurationError.configuration }
        if [404, 405, 501].contains(response.statusCode) { return .directoryUnsupported(statusCode: response.statusCode) }
        if !(200..<300).contains(response.statusCode) {
            switch response.statusCode {
            case 300..<400: throw ProviderConfigurationError.configuration
            case 401, 403: throw ProviderConfigurationError.credential
            case 429: throw ProviderConfigurationError.rateLimited
            case 400, 422:
                struct Failure: Decodable { struct Detail: Decodable { let code: String? }; let error: Detail? }
                let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.code
                if ["model_not_found", "model_not_available", "invalid_model", "model_not_supported"].contains(code ?? "") {
                    throw ProviderConfigurationError.modelUnavailable
                }
                throw ProviderConfigurationError.configuration
            default: throw ProviderConfigurationError.processing
            }
        }
        struct Model: Decodable { let id: String }
        struct Directory: Decodable { let data: [Model] }
        guard let directory = try? JSONDecoder().decode(Directory.self, from: data) else { throw ProviderConfigurationError.processing }
        return .directoryAvailable(modelListed: directory.data.contains(where: { $0.id == snapshot.model }), modelCount: directory.data.count)
    }
}
