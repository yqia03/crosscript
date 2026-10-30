import SwiftUI
import WorkbenchCore

private typealias GeminiSettingsState<Value> = SwiftUI.State<Value>

@MainActor struct GeminiLiveSettingsView: View {
    @ObservedObject var settings: GeminiLiveSettings
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @GeminiSettingsState private var key = ""
    @GeminiSettingsState private var saved = false
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(t("Gemini 同声传译服务", "Gemini live translation service"), systemImage: "waveform")
                .font(.system(size: 16, weight: .semibold))
            Text("Google AI Studio · " + settings.configuration.model)
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(t("保存此服务的 API Key，供主动发起实时双语验证或同声传译时使用。保存本身不会采集音频或调用服务。", "Save this service's API key for explicit bilingual verification or live translation. Saving does not capture audio or call the service."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SavedCredentialField(title: "Gemini API Key",
                hasSavedKey: settings.credentialAvailability == .available || SavedCredentialPresence.audio(settings.configuration), key: $key,
                metadataTarget: try? KeychainAudioCredentials.metadataTarget(for: settings.configuration))
            Text(t("输入新密钥后保存即可替换；留空保留已存密钥。已存密钥不能复制。", "Save a new key to replace it; leave blank to keep the saved key. Saved keys cannot be copied."))
                .font(.caption).foregroundStyle(.secondary)
            Text(credentialDescription).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { saveButton; removeButton }
                VStack(alignment: .leading) { saveButton; removeButton }
            }
            if settings.isUpdating {
                ProgressView(t("等待钥匙串授权…", "Waiting for Keychain authorization…")).controlSize(.small)
            }
            if settings.error != nil {
                Text(t("无法保存或读取 Gemini 密钥，请检查钥匙串访问后重试。", "The Gemini key could not be saved or read. Check Keychain access and retry."))
                    .font(.caption).foregroundStyle(.orange)
            } else if saved {
                Text(t("Gemini 密钥已保存", "Gemini key saved")).font(.caption).foregroundStyle(.secondary)
            }
            Text(t("此配置独立于录后转写、文本和 PDF 服务。实时翻译模型会生成计费音频，应用只显示双语文字。", "This configuration is separate from file transcription, text and PDF services. The live translation model generates billable audio; the app displays bilingual text."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).glassCard()
            .onDisappear { key = "" }
            .onChange(of: key) { _, value in if !value.isEmpty { saved = false } }
    }

    private var saveButton: some View {
        Button(t("保存 Gemini 密钥", "Save Gemini key")) {
            let submitted = key; key = ""
            Task {
                let success = await settings.saveCredential(submitted)
                saved = success && settings.credentialAvailability == .available
            }
        }.buttonStyle(.borderedProminent).disabled(settings.isUpdating)
    }
    private var removeButton: some View {
        Button(t("移除 Gemini 密钥", "Remove Gemini key")) {
            key = ""; saved = false
            Task { _ = await settings.removeCredential() }
        }.buttonStyle(.bordered).disabled(settings.isUpdating || settings.credentialAvailability == .missing)
    }
    private var credentialDescription: String {
        switch settings.credentialAvailability {
        case .unchecked: return t("尚未读取 Gemini 密钥。保存或主动提交时可能需要系统授权。", "The Gemini key has not been read. Saving or submitting may require system authorization.")
        case .available: return t("Gemini 密钥已保存在系统钥匙串。", "The Gemini key is stored in Keychain.")
        case .missing: return t("尚未保存 Gemini 密钥。", "No Gemini key has been saved.")
        case .inaccessible: return t("暂时无法访问 Gemini 密钥，可再次保存以重试。", "The Gemini key is inaccessible. Save again to retry.")
        }
    }
}
