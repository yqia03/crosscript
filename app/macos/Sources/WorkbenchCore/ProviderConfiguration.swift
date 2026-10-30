import Foundation

public enum ProviderUse: String, Codable, Sendable { case text, pdf }

public struct ProviderCredentialReference: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let target: String
    public init(profileID: UUID, target: String) { self.profileID = profileID; self.target = target }
}

public struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: String
    public let model: String
    public let credentialReference: ProviderCredentialReference

    public init(id: UUID = UUID(), name: String, baseURL: String, model: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !model.isEmpty, model.count <= 200,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !model.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw ProviderConfigurationError.configuration
        }
        self.id = id; self.name = name; self.model = model
        self.baseURL = try ProviderEndpoint.normalized(baseURL)
        credentialReference = ProviderCredentialReference(profileID: id, target: self.baseURL)
    }

    public var snapshot: ProviderSnapshot { ProviderSnapshot(profile: self) }
}

public struct ProviderDefaults: Codable, Equatable, Sendable {
    public var textID: UUID?
    public var pdfID: UUID?
    public init(textID: UUID? = nil, pdfID: UUID? = nil) { self.textID = textID; self.pdfID = pdfID }
}

/// Freezes configuration and a target-bound reference, not the secret itself.
/// Explicitly replacing a key affects later reads of this reference; requests
/// already sent retain the key they read. Changing targets never copies a key.
public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let name: String
    public let baseURL: String
    public let model: String
    public let credentialReference: ProviderCredentialReference
    public init(profile: ProviderProfile) {
        profileID = profile.id; name = profile.name; baseURL = profile.baseURL; model = profile.model
        credentialReference = profile.credentialReference
    }
    public func chatCompletionsURL() throws -> URL { try ProviderEndpoint.url(baseURL, suffix: "/chat/completions") }
    public func modelsURL() throws -> URL { try ProviderEndpoint.url(baseURL, suffix: "/models") }
    public func validated() throws -> Self {
        let profile = try ProviderProfile(id: profileID, name: name, baseURL: baseURL, model: model)
        guard profile.snapshot == self else { throw ProviderConfigurationError.configuration }
        return self
    }
}

enum ProviderEndpoint {
    static func normalized(_ raw: String) throws -> String {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, !raw.contains("%"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty, !host.hasSuffix("."),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { throw ProviderConfigurationError.configuration }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let allowed = CharacterSet(charactersIn: "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard !path.contains("//"), path.unicodeScalars.allSatisfy(allowed.contains),
              !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else {
            throw ProviderConfigurationError.configuration
        }
        if path.hasSuffix("/chat/completions") { path.removeLast("/chat/completions".count) }
        parts.scheme = "https"; parts.host = host; parts.path = path
        if parts.port == 443 { parts.port = nil }
        guard let value = parts.url?.absoluteString else { throw ProviderConfigurationError.configuration }
        return value
    }
    static func url(_ raw: String, suffix: String) throws -> URL {
        guard let result = URL(string: try normalized(raw) + suffix) else { throw ProviderConfigurationError.configuration }
        return result
    }
}

@MainActor public protocol ProviderCredentials: AnyObject {
    func read(reference: ProviderCredentialReference) throws -> String?
    func save(_ value: String, reference: ProviderCredentialReference) throws
    func delete(reference: ProviderCredentialReference) throws
    func readAsync(reference: ProviderCredentialReference) async throws -> String?
    func saveAsync(_ value: String, reference: ProviderCredentialReference) async throws
    func deleteAsync(reference: ProviderCredentialReference) async throws
}

public extension ProviderCredentials {
    func readAsync(reference: ProviderCredentialReference) async throws -> String? { try Task.checkCancellation(); return try read(reference: reference) }
    func saveAsync(_ value: String, reference: ProviderCredentialReference) async throws { try Task.checkCancellation(); try save(value, reference: reference) }
    func deleteAsync(reference: ProviderCredentialReference) async throws { try Task.checkCancellation(); try delete(reference: reference) }
}

public enum ProviderCredentialAvailability: Sendable {
    case unchecked, available, missing, inaccessible
}

public enum ProviderConnectionReport: Equatable, Sendable {
    case directoryAvailable(modelListed: Bool, modelCount: Int)
    case directoryUnsupported(statusCode: Int)
}

public protocol ProviderConnectionChecking: Sendable {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport
}

public enum ProviderConfigurationError: String, Error, Codable, Sendable {
    case configuration, credential, modelUnavailable, rateLimited, network, processing, storage, interrupted
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .configuration: return language.text("请检查名称、HTTPS 连接地址和模型 ID。", "Check the name, HTTPS address and model ID.")
        case .credential: return language.text("此连接目标的凭据不可用，请重新配置 API Key。", "Credentials for this target are unavailable. Configure its API key again.")
        case .modelUnavailable: return language.text("服务报告模型不存在或无权访问，请核对模型 ID。", "The service reports this model is missing or inaccessible. Check its ID.")
        case .rateLimited: return language.text("服务限流或额度不足，请检查后主动重试。", "The service reports a rate or quota limit. Check it and retry manually.")
        case .network: return language.text("无法连接服务。请检查网络和服务地址后重试。", "Cannot reach the service. Check the network and address, then retry.")
        case .processing: return language.text("服务返回了无法处理的响应。配置与已有内容仍保留。", "The service returned an unusable response. Configuration and existing content are retained.")
        case .storage: return language.text("配置无法读取或保存。已有文件保留，请检查磁盘与权限后重试。", "Configuration could not be read or saved. Existing files are retained; check disk space and permissions.")
        case .interrupted: return language.text("检查已取消，未自动重试。", "The check was cancelled; it was not retried.")
        }
    }
}
