import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias PDFViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFTranslationView: View {
    @ObservedObject var session: PDFTranslationSession
    @ObservedObject var providers: ProviderConfigurationSession
    var openSettings: () -> Void = {}
    var resources: TranslationResourceLibrary? = nil
    var runtimeReady = true
    var runtime: PDFRuntimePreparationSession? = nil
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @StateObject private var commands = MenuCommandBarrier()
    @StateObject private var draft: PDFSubmissionDraft
    @StateObject private var outputSelection = PDFOutputSelection()
    @PDFViewState private var showsHistory = false
    @PDFViewState private var workspaceWidth: CGFloat = 900
    @PDFViewState<String?> private var resourceError = nil
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var sourcePageCount: Int? { session.selectedID.flatMap { session.sourceMetadata[$0]?.pageCount } }

    init(session: PDFTranslationSession, providers: ProviderConfigurationSession, openSettings: @escaping () -> Void = {},
         resources: TranslationResourceLibrary? = nil, runtimeReady: Bool = true, runtime: PDFRuntimePreparationSession? = nil,
         draft: PDFSubmissionDraft? = nil) {
        self.session = session; self.providers = providers; self.openSettings = openSettings
        self.resources = resources; self.runtimeReady = runtimeReady; self.runtime = runtime
        _draft = StateObject(wrappedValue: draft ?? PDFSubmissionDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !session.pendingSaveIDs.isEmpty {
                Button(t("重试保存（不再次翻译）", "Retry save (no new translation)")) { _ = session.retrySaving() }.buttonStyle(.bordered)
            }
            if let error = session.error, session.workspaceIssues.isEmpty {
                Text(error.description(language)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.workspaceIssues) { issue in
                Text(issue.name + " · " + issue.error.description(language)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resourceError { Text(resourceError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            // Keep the native controls and their scroll/disclosure state alive
            // while the history subpage covers this workspace.
            workspace
                .frame(height: showsHistory ? 0 : nil, alignment: .top).clipped()
                .opacity(showsHistory ? 0 : 1).allowsHitTesting(!showsHistory).accessibilityHidden(showsHistory)
            if showsHistory {
                PDFHistorySection(session: session) { _ in showHistory(false) }
            }
        }
        .environment(\.menuCommandBarrier, commands)
        .onDisappear { commands.deactivate() }
        .onAppear {
            commands.activate()
            draft.initializeDefaults(profileID: providers.defaults.pdfID, resourceSelection: resources?.selection(for: .pdf) ?? .init())
            draft.reconcileProviders(providers.profiles)
        }
        .onChange(of: providers.profiles) { _, profiles in draft.reconcileProviders(profiles) }
        .sheet(item: Binding(get: { session.deletionConfirmation }, set: { if $0 == nil { session.cancelDeletion() } })) { confirmation in
            deletionSheet(confirmation)
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { heading; Spacer(minLength: 12); headerActions }
            VStack(alignment: .leading, spacing: 10) { heading; headerActions }
        }
    }
    private var heading: some View {
        Text(showsHistory ? t("PDF 历史", "PDF history") : t("PDF 翻译", "PDF translation"))
            .font(.system(size: 25, weight: .semibold))
    }
    private var headerActions: some View {
        HStack(spacing: 9) {
            if showsHistory {
                Button { showHistory(false) } label: { Label(t("返回 PDF 翻译", "Back to PDF translation"), systemImage: "arrow.left") }
                    .buttonStyle(WorkbenchCompactButtonStyle())
            } else {
                Button { showHistory(true) } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true))
                    .accessibilityLabel(t("PDF 历史记录", "PDF history")).help(t("历史记录", "History"))
            }
            if let runtime { PDFRuntimeStatusView(session: runtime) }
        }
    }
    private func showHistory(_ show: Bool) {
        if show { commands.deactivate() } else { commands.activate() }
        showsHistory = show
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = workspaceWidth >= 760 ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(spacing: 16))
            layout {
                PDFWorkspaceImportView(session: session, canSubmit: runtimeReady && (!draft.contentSettings.requiresService || draft.profileID != nil) && session.pendingSaveIDs.isEmpty,
                    localOnly: !draft.contentSettings.requiresService, chooseFiles: chooseFiles, submit: submit)
                    .frame(maxWidth: .infinity).frame(height: 420)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(t("翻译设置", "Translation settings")).font(.headline)
                        Spacer(minLength: 4)
                        Button(t("服务设置", "Service settings"), action: openSettings).buttonStyle(.borderless)
                    }.padding(.horizontal, 18).padding(.vertical, 14)
                    Divider()
                    ScrollView { settingsContent.frame(maxWidth: .infinity, alignment: .leading) }
                        .accessibilityLabel(t("PDF 翻译设置", "PDF translation settings"))
                }.frame(maxWidth: .infinity).frame(height: 420).glassCard()
            }
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in workspaceWidth = width }
            })
            PDFResultSection(session: session, outputSelection: outputSelection, commands: commands, resources: resources, resourceError: $resourceError)
        }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { _ = session.importPDFs(panel.urls) }
    }
    private func submit() { commands.perform {
        do {
            let submission = try draft.snapshot(profiles: providers.profiles, resources: resources)
            resourceError = nil
            _ = session.submitWorkspace(provider: submission.provider, options: submission.options)
        } catch let error as PDFOutputSettingsError { resourceError = error.description(language) }
          catch let error as PDFContentSettingsError { resourceError = error.description(language) }
          catch let error as PDFLayoutSettingsError { resourceError = error.description(language) }
          catch let error as PDFPerformanceSettingsError { resourceError = error.description(language) }
          catch { resourceError = t("设置、术语或提示词选择无效。请检查当前选项，保存库中的修改并重新选择项目。", "Settings, terminology or instruction selection is invalid. Check options, save library edits and select available items.") }
    } }
    private func deletionSheet(_ confirmation: PDFDeletionConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("确认删除", "Confirm deletion")).font(.title2)
            Text(confirmation.material.name).font(.headline)
            if case .result(_, let resultID) = confirmation.target, let result = confirmation.material.results.first(where: { $0.id == resultID }) {
                Text(result.provider.map { $0.name + " · " + $0.model } ?? t("本地处理", "Local processing")).textSelection(.enabled)
                Text(t("仅删除此结果的 PDF 文件。原始副本和其他结果保留。", "Delete only this result's PDF files. Keep the source copy and other results."))
            } else {
                Text(t("将 App 管理的原始 PDF 副本和全部 \(confirmation.material.results.count) 份结果移入废纸篓。外部原文件不变。", "Move the managed source PDF and all \(confirmation.material.results.count) results to Trash. The external original is unchanged."))
            }
            if session.deletionError != nil { Text(t("未能删除。资料仍保留，请检查当前任务和文件权限。", "Could not delete. Material is retained; check current tasks and file permissions.")).foregroundStyle(.red) }
            HStack { Spacer(); Button(t("取消", "Cancel")) { session.cancelDeletion() }; Button(t("删除", "Delete"), role: .destructive) { _ = session.confirmDeletion() } }
        }.padding(24).frame(width: 460)
    }
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.removedProviderSelection {
                Text(t("先前选择的服务配置已删除，请检查当前服务选择。若删除的是独立术语提取服务，自动提取已关闭，可重新设置。", "A previously selected service configuration was deleted. Review the current selection. If it was the separate term extraction service, automatic extraction is now off and can be configured again."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(t("知道了", "Dismiss")) { draft.dismissProviderRemovalNotice() }.buttonStyle(.borderless)
            }
            PDFContentSettingsView(access: draft.access(\.contentSettings))
                .onChange(of: draft.contentSettings.operation) { _, operation in
                    if operation == .parseOnly { draft.outputSettings.watermark = .noWatermark }
                }
            if draft.contentSettings.requiresService {
                Text(t("服务与模型", "Service and model"))
                CommittedPicker(title: t("服务与模型", "Service and model"), selection: $draft.profileID,
                    options: [(t("选择服务", "Choose a service"), UUID?.none)] + providers.profiles.map { ($0.name + " · " + $0.model, Optional($0.id)) })
            }
            Text(t("方向", "Direction"))
            TranslationDirectionPicker(direction: $draft.direction, catalog: .pdf, language: language)
            Text(t("语言范围依据 BabelDOC 0.6.4；部分语言的连字排版支持有限。", "Languages follow BabelDOC 0.6.4; some languages have limited ligature layout support."))
                .font(.caption).foregroundStyle(.secondary)
            PDFOutputSettingsView(access: draft.access(\.outputSettings), pageCount: sourcePageCount, operation: draft.contentSettings.operation, translatedFirstRequired: draft.layoutSettings.enhanceCompatibility)
            PDFLayoutSettingsView(access: draft.access(\.layoutSettings), content: draft.contentSettings)
            PDFPerformanceSettingsView(access: draft.access(\.performanceSettings), requiresService: draft.contentSettings.requiresService, extractsTerms: draft.autoExtractGlossary)
            if draft.contentSettings.requiresService, let resources {
                TranslationResourcePicker(library: resources, selection: $draft.resourceSelection, use: .pdf, manage: openSettings)
            }
            if draft.contentSettings.requiresService { DisclosureGroup(t("术语提取", "Term extraction")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(t("自动提取术语（会调用所选服务）", "Automatically extract terms (uses the selected service)"), isOn: $draft.autoExtractGlossary)
                    if draft.autoExtractGlossary {
                        Toggle(t("保存自动提取的 CSV", "Save extracted terms as CSV"), isOn: $draft.saveExtractedGlossary)
                        Text(t("提取服务", "Extraction service"))
                        CommittedPicker(title: t("提取服务", "Extraction service"), selection: $draft.termProviderID,
                            options: [(t("使用本任务相同服务和模型", "Use this task's service and model"), UUID?.none)] + providers.profiles.map { ($0.name + " · " + $0.model, Optional($0.id)) })
                        if draft.termProviderID != nil {
                            TextField(t("推理强度（可选，由所选服务支持）", "Reasoning effort (optional; service dependent)"), text: $draft.termReasoning)
                        }
                    }
                    Text(t("自动提取会先参考选中的术语表，再将提取结果用于翻译。模型可能改写术语；若需直接使用指定术语，可关闭自动提取。独立提取服务必须有自己的凭据。", "Extraction first considers selected glossaries and then uses extracted terms for translation. The model may alter terms; disable extraction to use selected glossaries directly. A separate extraction service requires its own credentials.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            }
        }.padding(18)
    }
}
