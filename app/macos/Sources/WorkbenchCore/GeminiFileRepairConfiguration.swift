import Foundation

/// Explicit file-only target. Live and file requests share Google's official
/// credential scope, but selecting a Live model never selects this capability.
public enum GeminiFileRepairConfiguration {
    public static let configuration = AudioServiceConfiguration(provider: .gemini, model: "gemini-3.5-flash-lite")
    public static let maximumIntervalFrames: Int64 = 60 * 24_000
}
