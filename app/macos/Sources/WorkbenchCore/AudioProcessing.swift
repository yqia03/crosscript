import Foundation

public enum AudioImportFormats {
    // Native decoding is required as well; a matching extension alone is insufficient.
    public static let extensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
}

public protocol AudioImporting: Sendable {
    func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval
}

/// Numeric request diagnostics deliberately exclude response bodies, credentials and file paths.
public struct AudioFailureDiagnostics: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case transport, http }
    public let origin: Origin
    public let code: Int
    public let failedChunk: Int
    public let elapsedSeconds: Double

    public init(origin: Origin, code: Int, failedChunk: Int, elapsedSeconds: Double) {
        self.origin = origin
        self.code = code
        self.failedChunk = failedChunk
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct AudioRequestFailure: Error, Sendable {
    public let category: AudioProcessingError
    public let diagnostics: AudioFailureDiagnostics

    public init(category: AudioProcessingError, diagnostics: AudioFailureDiagnostics) {
        self.category = category
        self.diagnostics = diagnostics
    }
}

public enum AudioProcessingError: String, Error, Codable, LocalizedError, Sendable {
    case configuration, credential, unavailable, rateLimited, processing, storage, unsupportedAudio, interrupted
    case quotaExceeded, requestLimited, modelUnavailable, unsupportedConfiguration

    public var errorDescription: String? {
        switch self {
        case .configuration: return coreMessage("请检查音频服务的 HTTPS 地址、模型和此目标的 API Key。", "Check the audio service's HTTPS address, model and API key for this target.")
        case .unsupportedConfiguration: return coreMessage("当前旧配置不支持本版带时间的转写。请在音频服务设置中选择预设模型；旧配置、文字和音频保留，不会自动上传。", "This legacy configuration is not supported for timed transcription. Choose a preset in Audio service settings. Existing configuration, text and audio are retained; nothing is uploaded automatically.")
        case .credential: return coreMessage("凭据不可用。请检查钥匙串访问和 API Key 的项目权限。", "Credentials unavailable. Check Keychain access and the API key's project permissions.")
        case .unavailable: return coreMessage("网络、服务或所选模型不可用。请检查连接及模型访问权限后重试。", "The network, service or selected model is unavailable. Check connectivity and model access, then retry.")
        case .rateLimited: return coreMessage("请求受限或额度不足。请检查项目限额及计费后手动重试。", "Rate limit or quota reached. Check project limits and billing before retrying manually.")
        case .quotaExceeded: return coreMessage("此服务余额或可用额度不足。请检查计费和额度后手动重试。", "This service reports insufficient credit or quota. Check billing and limits before retrying manually.")
        case .requestLimited: return coreMessage("此服务请求过于频繁。请稍后手动重试。", "This service reports a request rate limit. Retry manually later.")
        case .modelUnavailable: return coreMessage("请求的模型不存在或无权访问。请核对此服务的模型 ID 和权限。", "The requested model was not found or is not accessible. Check this service's model ID and permissions.")
        case .processing: return coreMessage("转写失败或返回了无效结果。音频已保留，可手动重试。", "Transcription failed or returned an invalid result. Audio is retained; you can retry manually.")
        case .storage: return coreMessage("无法保存资料。请检查磁盘空间与文件权限后重试。", "Material could not be saved. Check disk space and file permissions, then retry.")
        case .unsupportedAudio: return coreMessage("无法读取此音频，或文件包含视频。请选择支持的纯音频文件。", "This audio cannot be read, or it contains video. Choose a supported audio-only file.")
        case .interrupted: return coreMessage("上次转写已中断。音频已保留；重试会重新提交整份音频，可能再次计费。", "The previous transcription was interrupted. Audio is retained. Retrying resubmits all audio and may incur another charge.")
        }
    }
}
