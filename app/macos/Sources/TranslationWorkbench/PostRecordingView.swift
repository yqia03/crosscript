import SwiftUI
import WorkbenchCore

private typealias ViewState<Value> = SwiftUI.State<Value>

extension TranscriptionAttempt {
    func title(_ language: AppLanguage) -> String {
        switch status {
        case .running: return language.text("录后转写中", "Transcribing recorded audio")
        case .completed: return language.text("转写已保存", "Transcript saved")
        case .failed: return language.text("转写失败", "Transcription failed")
        case .interrupted: return language.text("转写已中断", "Transcription interrupted")
        }
    }
}

extension PostRecordingSession {
    func statusTitle(for id: UUID, language: AppLanguage) -> String? {
        if hasUnsavedTranscript(recordingID: id) { return language.text("等待本地保存", "Awaiting local save") }
        if authorizingSubmissionID == id { return language.text("等待钥匙串授权", "Waiting for Keychain authorization") }
        if let task = backgroundTasks.last(where: { $0.recordingID == id }) {
            if task.id == authorizingTaskID && task.status == .running { return language.text("等待钥匙串授权", "Waiting for Keychain authorization") }
            return task.status.title(language)
        }
        if let attempt = materials[id]?.attempt { return attempt.title(language) }
        if let result = selectedResult(recordingID: id) {
            return result.currentDocument.missingIntervals.isEmpty
                ? language.text("已保存转写结果", "Transcript saved")
                : language.text("已保存 · 有文字待补齐", "Saved · Missing text remains")
        }
        return nil
    }
}

@MainActor struct PostRecordingView: View {
    @ObservedObject var processing: PostRecordingSession
    let recording: Recording
    let canProcess: Bool
    var repair: TranscriptRepairSession? = nil
    let openSettings: () -> Void
    var playFrom: (TimeInterval) -> Void = { _ in }
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @ViewState private var showsTimedConfirmation = false
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var material: TranscriptionMaterial { processing.materials[recording.id] ?? TranscriptionMaterial() }
    private var selectedResult: TranscriptResult? {
        processing.selectedResult(recordingID: recording.id)
    }
    private var canSubmit: Bool { canProcess && processing.canEnqueueTranscription }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("录后转写 · 源语言文字", "Post-recording · Original language"), systemImage: "text.alignleft")
                .font(.system(size: 14, weight: .semibold))
            if processing.authorizingSubmissionID == recording.id {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(t("等待钥匙串授权，尚未提交转写。", "Waiting for Keychain authorization; transcription has not been queued."))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(t("取消提交", "Cancel submission")) { processing.cancelPendingSubmission() }
                }
            }
            if let attempt = material.attempt {
                Text(processing.statusTitle(for: recording.id, language: language) ?? "").font(.headline)
                if processing.runningID == recording.id {
                    serviceDetails(attempt.configuration)
                    ProgressView().controlSize(.small)
                    Text(t("已处理 \(attempt.completedChunks) 个音频分块", "Processed \(attempt.completedChunks) audio chunks"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = attempt.failure {
                    Text(t("失败请求使用", "Failed request used")).font(.caption)
                    serviceDetails(attempt.configuration)
                    Text(failure.localizedDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let diagnostics = attempt.diagnostics {
                        failureDetails(diagnostics)
                    }
                }
            }
            if processing.backgroundTasks.contains(where: { $0.recordingID == recording.id }) {
                AudioQueueView(processing: processing, recordingID: recording.id)
            }
            if let repair {
                TranscriptRepairView(repair: repair, recordingID: recording.id, result: selectedResult,
                    configuration: processing.configuration, recordingIsActive: !canProcess, openSettings: openSettings)
            }
            if let result = selectedResult {
                if material.results.count > 1 {
                    Picker(t("已保存的结果", "Saved result"), selection: Binding(get: { result.id }, set: { processing.selectResult(recordingID: recording.id, resultID: $0) })) {
                        ForEach(material.results) { item in
                            Text(resultTitle(item))
                                .tag(item.id)
                        }
                    }.pickerStyle(.menu).disabled(processing.hasUnsavedTranscript(recordingID: recording.id))
                }
                Text(t("当前结果：", "Current result: ") + resultTitle(result))
                    .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(t("共 \(material.results.count) 份独立结果 · 共用录音名称与原始音频", "\(material.results.count) independent results · Shared recording name and audio"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                serviceDetails(result.configuration)
                TranscriptEditorView(processing: processing, recording: recording, result: result, playFrom: playFrom)
                    .id(result.id)
                if !result.paragraphs.contains(where: { $0.playbackStart != nil }) {
                    Divider()
                    Text(t("当前结果没有可靠时间信息，仍可编辑和导出。若需段落定位，可主动重新转写；旧结果保留，会再次计费。", "This result has no reliable timing, but remains editable and exportable. To obtain timing, explicitly transcribe again. The old result is retained and the service charges again."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) {
                    processing.requestDeletion(.result(recordingID: recording.id, resultID: result.id))
                } label: { Label(t("删除当前结果…", "Delete current result…"), systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(processing.deletionBlockReason(for: .result(recordingID: recording.id, resultID: result.id)) != nil)
                if let reason = processing.deletionBlockReason(for: .result(recordingID: recording.id, resultID: result.id)) {
                    Text(reason.description(language)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                timedSubmission
            } else {
                Text(canProcess ? t("手动提交会把音频发送给下方所选服务，并产生该服务的费用。文字与音频保存在同一份历史资料中。", "Submitting sends audio to the selected service below and incurs its charges. The transcript is saved with this audio in History.") : t("停止并保存录音后，可手动发起转写。", "Stop and save the recording to transcribe it."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if material.attempt?.status == .failed {
                    Text(t("重试将重新提交整份音频，已处理部分可能再次计费。", "Retry resubmits the full audio; previously processed parts may be charged again."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if processing.hasUnsavedTranscript(recordingID: recording.id) {
                    Text(t("结果等待本地保存；重试保存不会再次上传。", "Result awaiting local save. Retrying the save does not upload again.")).font(.callout)
                    Button(t("重试保存结果", "Retry saving result")) { processing.retrySaving() }.buttonStyle(.borderedProminent)
                } else if !processing.configuration.supportsSegmentTimestamps {
                    serviceDetails(processing.configuration)
                    Text(t("当前是旧模型配置，请选择支持段落时间的预设。旧结果与密钥保持保留。", "This legacy configuration needs a supported preset before another transcription. Existing results and keys are retained."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(t("配置音频服务", "Configure audio service"), action: openSettings).buttonStyle(.bordered)
                } else {
                    Text(t("下次提交到", "Next submission to")).font(.caption)
                    serviceDetails(processing.configuration)
                    Button(t("更改服务", "Change service"), action: openSettings).buttonStyle(.bordered)
                    Button(material.attempt == nil ? t("开始转写", "Transcribe audio") : t("重新转写", "Transcribe again")) {
                        showsTimedConfirmation = true
                    }.buttonStyle(.borderedProminent).disabled(!canSubmit)
                    Text(t("一次生成全文和段落时间，可直接编辑与回听，无需为两个视图分别转写。", "One transcription provides full text and paragraph timing for editing and playback."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let running = processing.runningID, running != recording.id {
                        Text(t("另一份音频正在转写；本次提交会排队，录音仍可继续。", "Another audio file is running. This submission will queue; recording remains available.")).font(.caption)
                    }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .topLeading).glassCard()
        .sheet(isPresented: $showsTimedConfirmation) { timedConfirmation }
    }

    private func failureDetails(_ diagnostics: AudioFailureDiagnostics) -> some View {
        let duration = String(format: "%.1f", diagnostics.elapsedSeconds)
        let source: String
        switch diagnostics.origin {
        case .http:
            source = t("服务返回 HTTP \(diagnostics.code)", "Service returned HTTP \(diagnostics.code)")
        case .transport:
            source = diagnostics.code == URLError.timedOut.rawValue
                ? t("客户端请求超时（网络码 \(diagnostics.code)）", "Client request timed out (network code \(diagnostics.code))")
                : t("客户端网络错误（代码 \(diagnostics.code)）", "Client network error (code \(diagnostics.code))")
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(source)
            Text(t("第 \(diagnostics.failedChunk) 个音频分块 · 本次请求耗时 \(duration) 秒", "Audio chunk \(diagnostics.failedChunk) · Request took \(duration) seconds"))
            Text(t("服务可能已处理并计费。请先核对服务记录；重新提交会从头处理，已完成部分可能再次计费。", "The service may have processed and charged for this request. Check its records first; resubmitting starts from the beginning and completed chunks may be charged again."))
        }.font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private var timedSubmission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("新结果将使用", "New result will use")).font(.caption)
            Text(t("主动重新转写会再次计费；旧结果及用户修改保留。切换结果或视图不调用模型。", "Transcribing again incurs another charge and preserves existing results and edits. Switching results or views makes no model call."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            serviceDetails(processing.configuration)
            if processing.configuration.supportsSegmentTimestamps {
                Button(t("重新转写并保存新结果…", "Transcribe again as a new result…")) { showsTimedConfirmation = true }
                    .buttonStyle(.bordered).disabled(!canSubmit)
            } else {
                Text(t("请在设置中选择支持段落时间的服务和预设模型，并保存此服务密钥。", "Choose a supported service and preset model in Settings, and save its service key."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(t("音频服务设置", "Audio service settings"), action: openSettings).buttonStyle(.borderless)
            if processing.pendingSaveID != nil {
                Text(t("请先重试并完成待保存结果的本地保存，再发起新的转写。", "Retry and finish saving pending results locally before transcribing again."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if processing.runningID != nil {
                Text(t("当前后台名额已占用；新任务会排队，录音仍可继续。", "The background slot is busy. New tasks will queue while recording remains available."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resultTitle(_ result: TranscriptResult) -> String {
        let number = (material.results.firstIndex { $0.id == result.id } ?? 0) + 1
        return t("结果 \(number) · ", "Result \(number) · ") + result.createdAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(Locale(identifier: language.isChinese ? "zh_Hans" : "en")))
            + " · " + result.configuration.provider.title(language) + " · " + result.model

    }

    private var timedConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("转写音频", "Transcribe audio")).font(.title2.weight(.semibold))
            serviceDetails(processing.configuration)
            Text(t("按提交时显示的服务和模型排队；轮到本任务时会上传整份原始音频并计费，长音频可能分为多次请求。旧结果及其编辑保留；失败或重启后不会自动重试。", "Queues with the displayed service and model. When its turn begins, the full audio is uploaded and charged; long audio may need multiple requests. Existing results and edits are retained. Failures and restarts do not retry automatically."))
                .fixedSize(horizontal: false, vertical: true)
            Text(t("本次同时生成全文与段落时间。约两秒是回听定位目标，无法可靠定位的片段会保留文字并注明。", "This creates full text and paragraph timing together. About two seconds is the playback target; text without reliable timing is retained and marked."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(t("取消", "Cancel")) { showsTimedConfirmation = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("提交并生成新结果", "Submit and create result")) {
                    showsTimedConfirmation = false
                    let id = recording.id, target = processing.configuration
                    Task { await processing.enqueueTranscriptionAsync(id, submittedConfiguration: target) }
                }.buttonStyle(.borderedProminent).disabled(!canSubmit || !processing.configuration.supportsSegmentTimestamps)
            }
        }.padding(26).frame(width: 460)
    }

    private func serviceDetails(_ configuration: AudioServiceConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(configuration.provider.title(language) + " · " + t("请求模型：", "Requested model: ") + configuration.model)
            Text(configuration.baseURL).textSelection(.enabled)
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct AudioConfigurationView: View {
    @ObservedObject var processing: PostRecordingSession
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @ViewState<String> private var model = ""
    @ViewState<AudioServiceProvider> private var provider = .openAI
    @ViewState<String> private var baseURL = ""
    @ViewState<String> private var key = ""
    @ViewState<Bool> private var saved = false
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var matchesSavedTarget: Bool {
        let draft = try? AudioServiceConfiguration(provider: provider, baseURL: baseURL, model: model).validated()
        return draft?.credentialScope == processing.configuration.credentialScope
    }
    private var credentialDescription: String {
        guard matchesSavedTarget else {
            return t("密钥按服务和地址隔离；保存选择后检查此目标的已存密钥。", "Keys are isolated by service and address. Save this selection to check its stored key.")
        }
        switch processing.credentialAvailability {
        case .unchecked:
            return t("尚未检查此服务密钥；保存配置或主动提交时可能请求系统授权。", "This service's key has not been checked. Saving or submitting may request system authorization.")
        case .available:
            return t("此服务的 API Key 已存入系统钥匙串", "This service's API key is stored in Keychain")
        case .missing:
            return t("未找到此服务密钥；请输入并保存 API Key。", "No key was found for this service. Enter and save an API key.")
        case .inaccessible:
            return t("暂时无法读取此服务密钥；可再次保存或主动提交以重试授权。", "This service's key could not be accessed. Save or submit again to retry authorization.")
        }
    }
    private var timingValidationDescription: String {
        if provider == .aiHubMix && model == "whisper-large-v3" {
            return t("已有本项目真实转写与回听验收证据。", "This project has real transcription and playback acceptance evidence.")
        }
        if provider == .aiHubMix && model == "whisper-large-v3-turbo" {
            return t("已通过 1 分钟全文与段时间返回验证；真实定位精度仍待验证。", "Full text and segment timing were verified with a 1-minute sample; playback accuracy still needs validation.")
        }
        return t("文档支持段落时间；本项目尚未完成此组合的真实回听验证。", "Segment timing is documented; this combination has not completed real playback validation in this project.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("录后转写服务", "Post-recording transcription service"), systemImage: "cloud")
                .font(.system(size: 16, weight: .semibold))
            Picker(t("音频服务", "Audio service"), selection: $provider) {
                ForEach(AudioServiceProvider.selectableProviders, id: \.self) { value in
                    Text(value.title(language)).tag(value)
                }
            }
            .disabled(processing.isUpdatingCredentials || processing.needsCredentialRecovery)
            Text(baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(t("这里选择生成全文与段落时间的录后转写模型。保存配置不会调用服务。", "Choose a file transcription model for full text and paragraph timing. Saving makes no service call."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !processing.configuration.supportsSegmentTimestamps {
                Text(t("已保存的旧配置：", "Saved legacy configuration: ") + processing.configuration.provider.title(language) + " · " + processing.configuration.model)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(t("请明确选择并保存预设后再转写；旧结果、音频与原服务密钥不受影响。", "Choose and save a preset before transcribing. Existing results, audio and original service keys remain available."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker(t("音频模型", "Audio model"), selection: $model) {
                Text(t("请选择预设模型", "Choose a preset model")).tag("")
                ForEach(AudioServiceConfiguration.presetModels(for: provider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }.accessibilityLabel(t("音频模型", "Audio model")).disabled(processing.isUpdatingCredentials || processing.needsCredentialRecovery)
            Text(timingValidationDescription)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if provider == .openAI {
                Text(t("OpenAI 官方成功验证仍因支付问题暂缓。", "OpenAI success validation remains deferred due to billing."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SavedCredentialField(title: provider.title(language) + " API Key",
                hasSavedKey: (matchesSavedTarget && processing.credentialAvailability == .available) || SavedCredentialPresence.audio(AudioServiceConfiguration(provider: provider, baseURL: baseURL, model: model)),
                key: $key,
                metadataTarget: try? KeychainAudioCredentials.metadataTarget(for: AudioServiceConfiguration(provider: provider, baseURL: baseURL, model: model)))
            Text(t("输入新密钥后保存即可替换；留空保留已存密钥。已存密钥不能复制。", "Save a new key to replace it; leave blank to keep the saved key. Saved keys cannot be copied."))
                .font(.caption).foregroundStyle(.secondary)
                .disabled(processing.isUpdatingCredentials || processing.needsCredentialRecovery)
            Text(credentialDescription)
                .font(.caption).foregroundStyle(.secondary)
            if processing.isUpdatingCredentials {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(processing.needsCredentialRecovery ? t("正在恢复旧密钥，完成前请保持应用打开…", "Restoring the previous key. Keep the app open until it finishes…") : (processing.isCancellingCredentialAction ? t("正在结束钥匙串操作，完成恢复前不能退出…", "Finishing the Keychain operation. Quit is available after recovery…") : t("等待钥匙串授权…", "Waiting for Keychain authorization…"))).font(.caption)
                    Button(t("取消授权等待", "Cancel authorization wait")) { processing.cancelCredentialAction() }
                        .disabled(processing.isCancellingCredentialAction || processing.needsCredentialRecovery)
                }
            }
            if processing.needsCredentialRecovery && !processing.isUpdatingCredentials {
                Text(t("旧密钥尚未恢复，暂不能退出。请重试恢复；不会调用翻译服务。", "The previous key has not been restored, so quitting is paused. Retry recovery; no translation service is called."))
                    .font(.caption).foregroundStyle(.red)
                Button(t("重试恢复旧密钥", "Retry restoring previous key")) { Task { await processing.retryCredentialRecovery() } }
            }
            if provider == .aiHubMix {
                Text(t("AiHubMix 是第三方服务。验收建议使用未配置模型映射或回退的专用 Key；此处仅配置文件转写。", "AiHubMix is a third-party service. For validation, use a dedicated key without model mapping or fallback. This configures file transcription only."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { saveButton; removeButton }
                VStack(alignment: .leading) { saveButton; removeButton }
            }
            if saved { Text(t("配置已保存", "Configuration saved")).font(.caption).foregroundStyle(.secondary) }
            Text(t("正在执行的任务继续使用提交时的配置。删除密钥只影响后续调用。", "Running work keeps its submitted configuration. Removing the key affects later submissions."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).glassCard()
            .onAppear { provider = processing.configuration.provider == .compatible ? .aiHubMix : processing.configuration.provider; loadDraft() }
            .onDisappear { key = "" }
            .onChange(of: provider) { _, _ in loadDraft() }
            .onChange(of: baseURL) { _, _ in key = ""; saved = false }
            .onChange(of: model) { _, _ in saved = false }
            .onChange(of: key) { _, _ in saved = false }
    }
    private var saveButton: some View {
        Button(t("保存音频配置", "Save audio configuration")) {
            let targetProvider = provider, targetURL = baseURL, targetModel = model, submittedKey = key
            key = ""; saved = false
            Task { saved = await processing.saveConfigurationAsync(provider: targetProvider, baseURL: targetURL, model: targetModel, apiKey: submittedKey) }
        }.buttonStyle(.borderedProminent).disabled(processing.isUpdatingCredentials || processing.needsCredentialRecovery || !AudioServiceConfiguration.presetModels(for: provider).contains(model))
    }
    private var removeButton: some View {
        Button(t("移除此服务密钥", "Remove this service's key")) {
            key = ""; saved = false
            let target = processing.configuration
            Task { await processing.removeCredentialAsync(submittedConfiguration: target) }
        }.buttonStyle(.bordered).disabled(processing.isUpdatingCredentials || processing.needsCredentialRecovery || !matchesSavedTarget || processing.credentialAvailability == .missing)
    }
    private func loadDraft() {
        let profile = processing.configuration(for: provider)
        model = profile.supportsSegmentTimestamps ? profile.model : ""
        baseURL = AudioServiceConfiguration(provider: provider).baseURL
        key = ""
        saved = false
    }
}
