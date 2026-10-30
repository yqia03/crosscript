import SwiftUI
import WorkbenchCore

private typealias ProviderViewState<Value> = SwiftUI.State<Value>

@MainActor struct ProviderConfigurationView: View {
    @ObservedObject var session: ProviderConfigurationSession
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @ProviderViewState<UUID?> private var selectedID = nil
    @ProviderViewState<String> private var name = ""
    @ProviderViewState<String> private var baseURL = ""
    @ProviderViewState<String> private var model = ""
    @ProviderViewState<String> private var key = ""
    @ProviderViewState private var presetSelectionPending = false
    @ProviderViewState private var profileDeletion: ProviderSnapshot?
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var profile: ProviderProfile? { session.profiles.first { $0.id == selectedID } }
    private var validDraft: ProviderProfile? {
        try? ProviderProfile(id: selectedID ?? UUID(), name: name, baseURL: baseURL, model: model)
    }
    private var savedDraft: Bool { profile != nil && validDraft == profile && key.isEmpty }
    private var credentialState: ProviderCredentialAvailability {
        guard let profile, validDraft?.credentialReference == profile.credentialReference else { return .unchecked }
        return session.credentialAvailability(for: profile.id)
    }
    private var credentialDescription: String {
        switch credentialState {
        case .available: return t("此配置与目标已有钥匙串凭据。修改地址不会把旧密钥送到新目标。", "This configuration and target have a Keychain credential. Changing the address never transfers that key to the new target.")
        case .missing: return t("此目标尚无可用凭据。填写密钥后再主动检查或翻译。", "This target has no usable credential. Add a key before checking or translating.")
        case .inaccessible: return t("此目标的钥匙串凭据暂不可用，请重试或重新保存。", "This target's Keychain credential is unavailable. Retry or save it again.")
        case .unchecked: return t("主动保存、检查或翻译时才读取此目标的钥匙串；留空保留已有密钥。修改地址不会转移密钥。", "The Keychain is read only when you save, check or translate. Leave the key blank to retain an existing key. Changing the address never transfers it.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(t("文本与 PDF 服务", "Text and PDF services"), systemImage: "network")
                .font(.system(size: 16, weight: .semibold))
            Text(t("保存多套连接配置，为文本和 PDF 分别选择默认服务。音频服务在上方单独配置。", "Save multiple connections and choose separate defaults for text and PDF. Audio services are configured separately above."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(t("编辑服务配置", "Edit service configuration")).font(.subheadline.weight(.medium))
                Picker(t("服务配置", "Service configuration"), selection: $selectedID) {
                    Text(t("新建配置", "New configuration")).tag(UUID?.none)
                    ForEach(session.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                Menu(t("从服务与模型预设新建", "New from service and model preset")) {
                    ForEach(ProviderPreset.all) { preset in
                        Button(preset.name) { applyPreset(preset) }
                    }
                    Divider()
                    Button(t("自定义 OpenAI-compatible", "Custom OpenAI-compatible")) {
                        selectedID = nil; loadDraft()
                    }
                }
                TextField(t("配置名称", "Configuration name"), text: $name)
                    .accessibilityLabel(t("配置名称", "Configuration name"))
                TextField(t("HTTPS 服务地址", "HTTPS service address"), text: $baseURL)
                    .accessibilityLabel(t("服务地址", "Service address"))
                TextField(t("模型 ID", "Model ID"), text: $model)
                    .accessibilityLabel(t("模型 ID", "Model ID"))
                SavedCredentialField(title: t("文本与 PDF API Key", "Text and PDF API key"),
                    hasSavedKey: credentialState == .available || (validDraft.map { SavedCredentialPresence.provider($0.credentialReference) } ?? false), key: $key,
                    metadataTarget: selectedID == nil ? nil : validDraft.flatMap { try? KeychainProviderCredentials.metadataTarget(for: $0.credentialReference) })
                Text(t("输入新密钥后保存即可替换；留空保留已存密钥。已存密钥不能复制。", "Save a new key to replace it; leave blank to keep the saved key. Saved keys cannot be copied."))
                    .font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).disabled(session.isUpdatingCredentials || session.needsCredentialRecovery)
            Text(credentialDescription)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { saveButton; checkButton; removeKeyButton; deleteProfileButton }
                VStack(alignment: .leading, spacing: 10) { saveButton; checkButton; removeKeyButton; deleteProfileButton }
            }
            if savedDraft {
                Label(t("配置已保存", "Configuration saved"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let id = selectedID, session.checkingProfileID == id {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(session.authorizingProfileID == id ? t("等待钥匙串授权…", "Waiting for Keychain authorization…") : t("正在检查模型目录…", "Checking model directory…")).font(.callout)
                    Button(t("取消检查", "Cancel check")) { session.cancelConnectionCheck() }.buttonStyle(.borderless)
                }
            }
            if session.isUpdatingCredentials {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(session.needsCredentialRecovery ? t("正在恢复旧密钥，完成前请保持应用打开…", "Restoring the previous key. Keep the app open until it finishes…") : (session.isCancellingCredentialAction ? t("正在结束钥匙串操作，完成恢复前不能退出…", "Finishing the Keychain operation. Quit is available after recovery…") : t("等待钥匙串操作完成…", "Waiting for Keychain operation…"))).font(.callout)
                    Button(t("取消", "Cancel")) { session.cancelCredentialAction() }.buttonStyle(.borderless)
                        .disabled(session.isCancellingCredentialAction || session.needsCredentialRecovery)
                }
            }
            if session.needsCredentialRecovery && !session.isUpdatingCredentials {
                Text(t("旧密钥尚未恢复，暂不能退出。请重试恢复；不会调用翻译服务。", "The previous key has not been restored, so quitting is paused. Retry recovery; no translation service is called."))
                    .font(.caption).foregroundStyle(.red)
                Button(t("重试恢复旧密钥", "Retry restoring previous key")) { Task { await session.retryCredentialRecovery() } }
            }
            if let id = selectedID, let report = session.connectionReports[id] {
                Text(reportDescription(report)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(t("连接检查只读取模型目录，不发送翻译内容，也不证明模型或 PDF 翻译已通过验证。保存配置不会调用服务。", "The connection check only reads the model directory. It sends no translation content and does not verify generation or PDF translation. Saving makes no service call."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            defaultPicker(.text, title: t("文本默认服务", "Default text service"))
            defaultPicker(.pdf, title: t("PDF 默认服务", "Default PDF service"))
            Text(t("默认选择只影响之后的新任务。已提交的 PDF 和文本任务保留当时所选服务。", "Defaults apply only to new submissions. Submitted PDF and text tasks keep their selected service."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = session.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.description(language)).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if error == .storage {
                        Button(t("重新读取配置", "Reload configuration")) { session.reload() }.buttonStyle(.borderless)
                    } else {
                        Button(t("关闭提示", "Dismiss")) { session.dismissError() }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).glassCard()
        .onAppear {
            if selectedID == nil { selectedID = session.defaults.textID ?? session.profiles.first?.id }
            loadDraft()
        }
        .onChange(of: selectedID) { _, _ in
            if presetSelectionPending { presetSelectionPending = false } else { loadDraft() }
        }
        .onChange(of: session.profiles) { _, profiles in
            if let selectedID, !profiles.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil; loadDraft()
            }
        }
        .onChange(of: baseURL) { _, _ in key = "" }
        .onDisappear { key = "" }
        .alert(t("删除服务配置？", "Delete service configuration?"), isPresented: Binding(
            get: { profileDeletion != nil }, set: { if !$0 { profileDeletion = nil } }
        )) {
            Button(t("取消", "Cancel"), role: .cancel) { profileDeletion = nil }
            Button(t("删除配置", "Delete configuration"), role: .destructive) {
                guard let submitted = profileDeletion else { return }
                if session.deleteProfile(submitted.profileID, submittedSnapshot: submitted) {
                    selectedID = nil; loadDraft()
                }
                profileDeletion = nil
            }
        } message: {
            if let submitted = profileDeletion { Text(deletionDescription(submitted)) }
        }
    }

    private var saveButton: some View {
        Button(t("保存配置", "Save configuration")) {
            let id = selectedID, submittedName = name, address = baseURL, submittedModel = model, submittedKey = key
            key = ""
            Task {
                if let profile = await session.saveProfileAsync(id: id, name: submittedName, baseURL: address, model: submittedModel, apiKey: submittedKey),
                   selectedID == id, name == submittedName, baseURL == address, model == submittedModel {
                    selectedID = profile.id
                    name = profile.name; baseURL = profile.baseURL; model = profile.model
                }
            }
        }.buttonStyle(.borderedProminent).disabled(validDraft == nil || session.isUpdatingCredentials || session.needsCredentialRecovery)
    }
    private var checkButton: some View {
        Button(t("检查连接", "Check connection")) {
            guard let id = selectedID, let submitted = try? session.snapshot(for: id) else { return }
            Task { await session.checkConnection(for: id, submittedSnapshot: submitted) }
        }.buttonStyle(.bordered).disabled(!savedDraft || session.checkingProfileID != nil || session.isUpdatingCredentials || session.needsCredentialRecovery)
    }
    private var removeKeyButton: some View {
        Button(t("移除此目标密钥", "Remove target key")) {
            guard let id = selectedID, let submitted = try? session.snapshot(for: id) else { return }
            key = ""
            Task { await session.removeCredentialAsync(for: id, submittedSnapshot: submitted) }
        }.buttonStyle(.bordered).disabled(!savedDraft || credentialState == .missing || session.isUpdatingCredentials || session.needsCredentialRecovery)
    }
    private var deleteProfileButton: some View {
        Button(t("删除配置…", "Delete configuration…"), role: .destructive) {
            profileDeletion = profile?.snapshot
        }.buttonStyle(.bordered).disabled(profile == nil || session.isUpdatingCredentials || session.needsCredentialRecovery)
    }
    private func deletionDescription(_ snapshot: ProviderSnapshot) -> String {
        var lines = [t("将删除“\(snapshot.name)”的服务配置：", "Delete the service configuration “\(snapshot.name)”:"), snapshot.baseURL, snapshot.model]
        let uses = [(session.defaults.textID == snapshot.profileID, t("文本", "Text")),
                    (session.defaults.pdfID == snapshot.profileID, "PDF")].filter(\.0).map(\.1)
        if !uses.isEmpty {
            lines.append(t("\(uses.joined(separator: "、"))的默认服务将清空，新任务需重新选择服务。", "The default service for \(uses.joined(separator: " and ")) will be cleared. Choose a service before new submissions."))
        }
        lines.append(t("此配置未保存的编辑将丢弃。历史资料、既有结果与已提交任务保留。钥匙串密钥保留，供已提交任务使用；若要移除密钥，请先取消，再使用“移除此目标密钥”。", "Unsaved edits to this configuration will be discarded. History, existing results and submitted tasks are retained. Its Keychain key is retained for submitted tasks. To remove the key, cancel and use “Remove target key” first."))
        return lines.joined(separator: "\n\n")
    }
    private func defaultPicker(_ use: ProviderUse, title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium))
            Picker(title, selection: Binding<UUID?>(
                get: { use == .text ? session.defaults.textID : session.defaults.pdfID },
                set: { session.setDefault($0, for: use) }
            )) {
                Text(t("未选择", "Not selected")).tag(UUID?.none)
                ForEach(session.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func loadDraft() {
        name = profile?.name ?? ""; baseURL = profile?.baseURL ?? ""; model = profile?.model ?? ""; key = ""
    }
    private func applyPreset(_ preset: ProviderPreset) {
        // A preset always creates a fresh profile; it cannot rewrite the
        // selected profile or inherit that profile's target-bound credential.
        presetSelectionPending = selectedID != nil
        selectedID = nil
        name = preset.name; baseURL = preset.baseURL; model = preset.model; key = ""
    }
    private func reportDescription(_ report: ProviderConnectionReport) -> String {
        switch report {
        case .directoryAvailable(let listed, let count):
            return listed
                ? t("目录可读取，返回 \(count) 个模型且包含所选模型。生成能力仍待实际翻译验证。", "Directory available: \(count) models, including the selected model. Generation still needs translation validation.")
                : t("目录可读取，但未列出所选模型；仍可保存并选择此模型，实际能力待验证。", "Directory available, but the selected model is not listed. You can still save and select it; its capabilities remain unverified.")
        case .directoryUnsupported(let code):
            return t("此服务未提供可用的模型目录（HTTP \(code)）。连接能力未验证，配置仍保留；不会自动发送生成请求。", "No usable model directory (HTTP \(code)). Connection capabilities remain unverified; configuration is retained. No generation request was sent automatically.")
        }
    }
}
