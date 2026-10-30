import Foundation

/// Explicit starting points; selecting a preset does not save, copy keys or
/// make a request. Custom OpenAI-compatible configurations remain available.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public static let all: [Self] = [
        .init(id: "deepseek-flash", name: "DeepSeek · Flash", baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
        .init(id: "aihubmix-deepseek", name: "AiHubMix · DeepSeek V4.1 Flash", baseURL: "https://aihubmix.com/v1", model: "deepseek-v4.1-flash"),
        .init(id: "aihubmix-gpt-mini", name: "AiHubMix · GPT-4o mini", baseURL: "https://aihubmix.com/v1", model: "gpt-4o-mini"),
        .init(id: "aihubmix-gemini-lite", name: "AiHubMix · Gemini 2.5 Flash Lite", baseURL: "https://aihubmix.com/v1", model: "gemini-2.5-flash-lite")
    ]
}
