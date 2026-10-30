import Foundation

public enum AudioServiceProvider: String, Codable, CaseIterable, Sendable {
    case openAI, aiHubMix, gemini, compatible

    /// Legacy compatible profiles remain decodable; new file work uses documented presets.
    public static let selectableProviders: [Self] = [.aiHubMix, .openAI]

    public func title(_ language: AppLanguage) -> String {
        switch self {
        case .openAI: return language.text("OpenAI 官方", "OpenAI official")
        case .aiHubMix: return "AiHubMix"
        case .gemini: return "Gemini"
        case .compatible: return language.text("自定义兼容服务", "Custom compatible service")
        }
    }
}

/// Non-secret selection, also retained with each submitted attempt and result.
public struct AudioServiceConfiguration: Codable, Equatable, Sendable {
    public let provider: AudioServiceProvider
    public let baseURL: String
    public let model: String

    public init(provider: AudioServiceProvider = .openAI, baseURL: String? = nil, model: String? = nil) {
        self.provider = provider
        switch provider {
        case .openAI:
            self.baseURL = baseURL ?? "https://api.openai.com/v1"
            self.model = model ?? "whisper-1"
        case .aiHubMix:
            self.baseURL = baseURL ?? "https://aihubmix.com/v1"
            self.model = model ?? "whisper-large-v3"
        case .gemini:
            self.baseURL = baseURL ?? "https://generativelanguage.googleapis.com/v1beta"
            self.model = model ?? "gemini-3.5-live-translate-preview"
        case .compatible:
            self.baseURL = baseURL ?? ""
            self.model = model ?? ""
        }
    }

    public func validated() throws -> Self {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/")
        guard !model.isEmpty, model.count <= 200, model.unicodeScalars.allSatisfy(modelCharacters.contains) else {
            throw AudioProcessingError.configuration
        }
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gemini has a separately adapted official protocol. Its credential
        // target must never pass through the compatible file endpoint rules.
        if provider == .gemini {
            guard raw == Self(provider: .gemini).baseURL else { throw AudioProcessingError.configuration }
            return Self(provider: .gemini, baseURL: raw, model: model)
        }
        guard raw.count <= 2048, !raw.contains("%"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty, !host.hasSuffix("."),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { throw AudioProcessingError.configuration }
        parts.scheme = "https"
        parts.host = host
        if parts.port == 443 { parts.port = nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let transcriptionPath = "/audio/transcriptions"
        let explicitEndpoint = path.hasSuffix(transcriptionPath)
        // Versioned endpoint aliases share one credential target. An explicitly
        // supplied unversioned endpoint must keep its path, including any proxy prefix.
        if path.hasSuffix("/v1" + transcriptionPath) { path.removeLast(transcriptionPath.count) }
        if path.isEmpty { path = "/v1" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let pathCharacters = CharacterSet(charactersIn: "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard explicitEndpoint || path.hasSuffix("/v1"), !path.contains("//"),
              !segments.contains("."), !segments.contains(".."),
              !path.contains("/v1/v1"), path.unicodeScalars.allSatisfy(pathCharacters.contains) else {
            throw AudioProcessingError.configuration
        }
        parts.path = path
        guard let normalized = parts.url?.absoluteString else { throw AudioProcessingError.configuration }
        if provider != .compatible, normalized != Self(provider: provider).baseURL {
            throw AudioProcessingError.configuration
        }
        return Self(provider: provider, baseURL: normalized, model: model)
    }

    public func transcriptionURL() throws -> URL {
        let value = try validated()
        guard value.provider != .gemini else { throw AudioProcessingError.configuration }
        let path = "/audio/transcriptions"
        let endpoint = value.baseURL.hasSuffix(path) ? value.baseURL : value.baseURL + path
        guard let url = URL(string: endpoint) else { throw AudioProcessingError.configuration }
        return url
    }

    /// Model changes retain the credential; provider or connection target changes do not.
    public var credentialScope: String { provider.rawValue + "|" + baseURL }

    public static func presetModels(for provider: AudioServiceProvider) -> [String] {
        switch provider {
        case .aiHubMix: return ["whisper-large-v3", "whisper-large-v3-turbo", "whisper-1"]
        case .openAI: return ["whisper-1", "gpt-4o-transcribe-diarize"]
        case .gemini: return []
        case .compatible: return []
        }
    }

    /// Documented segment protocol only; this is not a speech-accuracy guarantee.
    /// Custom endpoints require their own capability verification even for the same model ID.
    public var supportsSegmentTimestamps: Bool {
        guard let profile = try? validated() else { return false }
        return Self.presetModels(for: profile.provider).contains(profile.model)
    }
}

struct AudioServiceSettings: Codable {
    var version = 2
    var selected: AudioServiceProvider = .openAI
    var profiles: [AudioServiceConfiguration] = [AudioServiceConfiguration()]

    func configuration(for provider: AudioServiceProvider) -> AudioServiceConfiguration {
        profiles.first(where: { $0.provider == provider }) ?? AudioServiceConfiguration(provider: provider)
    }

    mutating func select(_ configuration: AudioServiceConfiguration) {
        profiles.removeAll { $0.provider == configuration.provider }
        profiles.append(configuration)
        selected = configuration.provider
    }
}
