import Foundation

/// Limits within one PDF engine process; these never grant additional App jobs.
public struct PDFPerformanceSettings: Codable, Equatable, Sendable {
    public enum Thinking: String, Codable, CaseIterable, Sendable { case automatic, enabled, disabled }
    public var requestsPerSecond = 4
    /// nil follows QPS; the term pool follows the resolved translation pool.
    public var translationWorkers: Int?
    public var termWorkers: Int?
    public var ignoreCache = false
    public var progressInterval = 0.1
    public var sameTextFallback = true
    public var jsonModeWhenRequested = false
    public var dashScopeHeader = false
    public var sendTemperature = true
    public var reasoning = ""
    public var thinking: Thinking = .automatic
    public var diagnosticPDF = false
    public var characterBoxes = false
    public init() {}
    public var effectiveTranslationWorkers: Int { translationWorkers ?? requestsPerSecond }
    public var effectiveTermWorkers: Int { termWorkers ?? effectiveTranslationWorkers }
    public func validate(requiresService: Bool = true, extractsTerms: Bool = true) throws {
        guard progressInterval.isFinite, (0.05...60).contains(progressInterval) else { throw PDFPerformanceSettingsError.invalidInterval }
        guard requiresService else { return }
        guard (1...100).contains(requestsPerSecond), translationWorkers.map({ (1...100).contains($0) }) ?? true,
              (!extractsTerms || (termWorkers.map({ (1...100).contains($0) }) ?? true)) else { throw PDFPerformanceSettingsError.invalidLimit }
        guard reasoning.utf8.count <= 200, !reasoning.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PDFPerformanceSettingsError.invalidReasoning }
    }
    public var engineSettings: [String: Any] {
        var values: [String: Any] = ["qps": requestsPerSecond, "ignore_cache": ignoreCache, "report_interval": progressInterval,
            "disable_same_text_fallback": !sameTextFallback, "enable_json_mode_if_requested": jsonModeWhenRequested,
            "send_dashscope_header": dashScopeHeader, "send_temperature": sendTemperature,
            "debug": diagnosticPDF, "show_char_box": diagnosticPDF && characterBoxes]
        if let translationWorkers { values["pool_max_workers"] = translationWorkers }
        if let termWorkers { values["term_pool_max_workers"] = termWorkers }
        if !reasoning.isEmpty { values["openai_reasoning"] = reasoning }
        if thinking != .automatic { values["openai_thinking"] = thinking.rawValue }
        return values
    }
    public func snapshotLines(_ language: AppLanguage) -> [String] {
        func flag(_ zh: String, _ en: String, _ value: Bool) -> String { language.text(zh, en) + ": " + (value ? language.text("开", "On") : language.text("关", "Off")) }
        return [summary(language), flag("相同原文回退", "Same-text fallback", sameTextFallback),
            flag("按需 JSON 模式", "JSON mode when requested", jsonModeWhenRequested), flag("DashScope 检查头", "DashScope inspection header", dashScopeHeader),
            flag("发送温度 0", "Send temperature 0", sendTemperature), language.text("推理强度：", "Reasoning: ") + (reasoning.isEmpty ? language.text("服务默认", "Service default") : reasoning),
            language.text("思考模式：", "Thinking: ") + thinking.rawValue, flag("诊断 PDF", "Diagnostic PDF", diagnosticPDF), flag("字符框", "Character boxes", diagnosticPDF && characterBoxes)]
    }
    public func summary(_ language: AppLanguage) -> String {
        language.text("每秒请求 \(requestsPerSecond) · 翻译线程 \(effectiveTranslationWorkers) · 提取线程 \(effectiveTermWorkers)", "QPS \(requestsPerSecond) · Translation workers \(effectiveTranslationWorkers) · Term workers \(effectiveTermWorkers)") + "\n" +
        (ignoreCache ? language.text("绕过缓存读写", "Bypass cache reads and writes") : language.text("复用本机翻译缓存", "Reuse local translation cache")) +
        language.text(" · 进度间隔 \(progressInterval) 秒", " · Progress interval \(progressInterval) s")
    }
}
public enum PDFPerformanceSettingsError: Error, Equatable, Sendable {
    case invalidLimit, invalidInterval, invalidReasoning
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .invalidLimit: return language.text("请求速率与线程数必须是 1–100 的整数。此为 App 资源上限，实际服务可能更低。", "QPS and worker counts must be integers from 1 to 100. This App resource limit does not override lower service limits.")
        case .invalidInterval: return language.text("进度间隔必须在 0.05–60 秒之间。", "Progress interval must be between 0.05 and 60 seconds.")
        case .invalidReasoning: return language.text("推理强度最多 200 字节，不能包含控制字符。", "Reasoning effort must be at most 200 bytes with no control characters.")
        }
    }
}

/// Safe numeric metadata only. No text, endpoints, model response or credentials.
/// Token sums cover only responses that actually supplied both usage values.
public struct PDFRunDiagnostics: Codable, Equatable, Sendable {
    public var requestCount: Int
    public var translationRequests: Int
    public var termRequests: Int
    public var translationCacheHits: Int
    public var termCacheHits: Int
    public var responsesWithUsage: Int
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var elapsedSeconds: Double
    public init(requestCount: Int, translationRequests: Int, termRequests: Int, translationCacheHits: Int = 0, termCacheHits: Int = 0,
                responsesWithUsage: Int = 0, promptTokens: Int? = nil, completionTokens: Int? = nil, elapsedSeconds: Double) {
        self.requestCount = requestCount; self.translationRequests = translationRequests; self.termRequests = termRequests
        self.translationCacheHits = translationCacheHits; self.termCacheHits = termCacheHits; self.responsesWithUsage = responsesWithUsage
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.elapsedSeconds = elapsedSeconds
    }
    public func validate() throws {
        guard (0...10_000).contains(requestCount), (0...requestCount).contains(translationRequests), (0...requestCount).contains(termRequests),
              translationRequests + termRequests == requestCount, (0...requestCount).contains(responsesWithUsage),
              translationCacheHits >= 0, termCacheHits >= 0, elapsedSeconds.isFinite, elapsedSeconds >= 0,
              promptTokens.map({ $0 >= 0 }) ?? true, completionTokens.map({ $0 >= 0 }) ?? true,
              (responsesWithUsage == 0 ? promptTokens == nil && completionTokens == nil : promptTokens != nil && completionTokens != nil)
        else { throw PDFTranslationError.invalidOutput }
    }
    public func summary(_ language: AppLanguage) -> String {
        var lines = [language.text("实际请求：\(requestCount)（翻译 \(translationRequests)，术语 \(termRequests)）", "Actual requests: \(requestCount) (translation \(translationRequests), terms \(termRequests))"),
            language.text("缓存命中：翻译 \(translationCacheHits)，术语 \(termCacheHits)", "Cache hits: translation \(translationCacheHits), terms \(termCacheHits)"),
            language.text("引擎用时：", "Engine duration: ") + String(format: "%.2f s", elapsedSeconds)]
        if let promptTokens, let completionTokens {
            lines.append(language.text("已报告用量：输入 \(promptTokens)，输出 \(completionTokens) token（\(responsesWithUsage)/\(requestCount) 请求）", "Reported usage: \(promptTokens) input, \(completionTokens) output tokens (\(responsesWithUsage)/\(requestCount) requests)"))
        } else { lines.append(language.text("Token 用量：未报告，不估算", "Token usage: not reported; no estimate")) }
        return lines.joined(separator: "\n")
    }
}
