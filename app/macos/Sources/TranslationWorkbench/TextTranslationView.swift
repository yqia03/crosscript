import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias TextViewState<Value> = SwiftUI.State<Value>

@MainActor struct TextTranslationView: View {
    @ObservedObject var session: TextTranslationSession
    @ObservedObject var providers: ProviderConfigurationSession
    let resources: TranslationResourceLibrary?
    var openSettings: () -> Void
    var workspaceHeight: CGFloat
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    @TextViewState private var toolsVisible = true
    @TextViewState private var showsHistory = false
    @TextViewState private var availableWidth: CGFloat = 1_000
    @TextViewState private var markdownMode: String
    @TextViewState private var sourceRendered: Bool
    @StateObject private var sourceActions = TextEditorActions()
    @StateObject private var targetActions = TextEditorActions()
    @StateObject private var systemTools = TextSystemTools()
    @Environment(\.textFooterGeometryObserver) private var footerGeometryObserver
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: languageChoice).text(zh, en) }
    init(session: TextTranslationSession, providers: ProviderConfigurationSession, resources: TranslationResourceLibrary? = nil, openSettings: @escaping () -> Void = {}, initialMarkdownMode: String = "edit", initialSourceRendered: Bool = false, initialToolsVisible: Bool = true, workspaceHeight: CGFloat = 780) {
        self.session = session; self.providers = providers; self.resources = resources; self.openSettings = openSettings; self.workspaceHeight = workspaceHeight
        _markdownMode = State(initialValue: initialMarkdownMode); _sourceRendered = State(initialValue: initialSourceRendered); _toolsVisible = State(initialValue: initialToolsVisible)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if session.hasPendingSave {
                HStack {
                    Label(t("本地保存失败，当前编辑仍保留。", "Local save failed. Your edits are retained."), systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(t("重试保存", "Retry save")) { _ = session.retrySaving() }
                }.font(.callout).padding(12).glassCard()
            }
            if let error = session.error, error != .storage || !session.hasPendingSave {
                Text(errorText(error)).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            let value = session.workspace
            Group {
                let inlineTools = !toolsVisible || availableWidth >= 734
                let layout = inlineTools ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
                // Size-fitting alternatives construct temporary native editors
                // while measuring. Keep one subtree and change only its layout.
                layout {
                    workspace(value, width: availableWidth - (toolsVisible && inlineTools ? 244 : 0)).frame(maxWidth: .infinity)
                    if toolsVisible { tools(value).frame(width: inlineTools ? 230 : nil) }
                }
                dictionary
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "TextTranslationFooter")
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                if width > 0 { availableWidth = width }
            }
        })
        .onAppear { session.observeDefaultProvider(providers, resources: resources) }
        .onDisappear { systemTools.stop() }
        .sheet(isPresented: $showsHistory) {
            TextTranslationHistoryView(session: session) {
                systemTools.reset(); sourceRendered = false; markdownMode = "edit"
                showsHistory = false
            }
        }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(t("文本翻译", "Text translation")).font(.system(size: 25, weight: .semibold))
            Spacer(minLength: 12)
            icon(t("文本历史记录", "Text translation history"), "clock.arrow.circlepath") { showsHistory = true }
        }
    }
    private func workspace(_ value: TextWorkspace, width: CGFloat) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let languageSideWidth = max(30, (geometry.size.width - 54) / 2)
                HStack(spacing: 10) {
                TranslationLanguagePicker(title: t("原文语言", "Source language"), selection: Binding(
                    get: { session.workspace.direction.sourceLanguage }, set: { _ = session.setSourceLanguage($0) }),
                    catalog: .text, language: language, compact: true, alignsCompactTrailing: true,
                    detectsSourceAutomatically: value.automaticallyDetectsSourceLanguage,
                    automaticSourceLabel: automaticSourceLabel,
                    selectAutomaticSource: { _ = session.setSourceLanguage(nil) })
                    .frame(width: languageSideWidth)
                icon(t("交换语言和文本", "Swap languages and text"), "arrow.left.arrow.right") { _ = session.swapLanguages() }
                TranslationLanguagePicker(title: t("译文语言", "Target language"), selection: Binding(
                    get: { session.workspace.direction.targetLanguage }, set: { _ = session.setTargetLanguage($0) }),
                    catalog: .text, language: language, compact: true)
                    .frame(width: max(30, languageSideWidth - (toolsVisible ? 0 : 44)))
                    .frame(width: languageSideWidth, alignment: .leading)
                }
            }.frame(height: 34).padding(10).glassCard().overlay(alignment: .trailing) {
                if !toolsVisible { icon(t("显示翻译工具", "Show translation tools"), "sidebar.right") { toolsVisible = true }.padding(.trailing, 10) }
            }
            let layout = width >= 490 ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
            layout {
                source(value)
                target(value)
            }
        }
    }
    private var editorHeight: CGFloat { max(340, workspaceHeight - 280) }
    private func source(_ value: TextWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("原文", "Source")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if value.isMarkdown {
                    Toggle(t("阅读", "Reading"), isOn: $sourceRendered).toggleStyle(.button).font(.caption)
                }
                icon(t("清空文本", "Clear text"), "xmark") { sourceActions.clear(); _ = session.clear() }
                    .disabled(value.inputDraft.isEmpty && value.translation.isEmpty)
            }.padding(.horizontal, 12).padding(.top, 8)
            if sourceRendered && value.isMarkdown {
                MarkdownReadingView(text: value.inputDraft).frame(height: editorHeight)
            } else {
                TextWorkspaceEditor(text: value.inputDraft, label: t("输入原文", "Source text"), actions: sourceActions, monospaced: value.isMarkdown,
                    changed: { session.updateInput(text: $0) },
                    submit: { translate(session.workspace) }, composition: { if $0 { session.compositionBegan() } }, selection: systemTools.lookup)
                    .id(session.workspaceRevision.uuidString + "source").frame(height: editorHeight)
            }
            HStack(spacing: 3) {
                icon(t("撤销原文", "Undo source"), "arrow.uturn.backward", action: sourceActions.undo).disabled((value.isMarkdown && sourceRendered) || !sourceActions.canUndo)
                icon(t("重做原文", "Redo source"), "arrow.uturn.forward", action: sourceActions.redo).disabled((value.isMarkdown && sourceRendered) || !sourceActions.canRedo)
                icon(t("复制原文", "Copy source"), "doc.on.doc") { copy(session.workspace.inputDraft) }.disabled(value.inputDraft.isEmpty)
                icon(t("打开文本文件", "Open text file"), "folder") { importText() }
                    .modifier(TextFooterGeometryObservation(name: "source.previous", observer: footerGeometryObserver))
                TextActionMenu(label: t("更多原文操作", "More source actions"), symbol: "ellipsis", actions: [
                    .init(title: t("导出原文", "Export source"), perform: { export(value, kind: "source") })
                ])
                .modifier(TextFooterGeometryObservation(name: "source.menu", observer: footerGeometryObserver))
                Spacer(minLength: 0)
                Text("\(value.inputDraft.count)").font(.caption2).foregroundStyle(.secondary).accessibilityLabel(t("字符数", "Character count"))
            }.padding(8)
        }.frame(maxWidth: .infinity).glassCard()
    }
    private func target(_ value: TextWorkspace) -> some View {
        let resultMatches = value.currentResultMatchesWorkspace
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("译文", "Translation")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.isRunning {
                    Button(t("停止", "Stop")) { session.stop() }.buttonStyle(.borderless)
                } else if let result = value.currentResult, result.direction != value.direction {
                    Text(t("方向已修改", "Direction changed")).font(.caption).foregroundStyle(.secondary)
                } else if let result = value.currentResult, (result.markdown != nil) != value.isMarkdown {
                    Text(t("输入格式已修改", "Input format changed")).font(.caption).foregroundStyle(.secondary)
                } else if let result = value.currentResult, !result.input.utf8.elementsEqual(value.inputDraft.utf8) {
                    Text(t("原文已修改", "Source changed")).font(.caption).foregroundStyle(.secondary)
                } else if value.currentResult?.status == .failed {
                    Text(t("翻译失败", "Translation failed")).font(.caption).foregroundStyle(.red)
                }
                if value.isMarkdown {
                    Menu {
                        Button(t("编辑源码", "Edit source")) { markdownMode = "edit" }
                        Button(t("阅读", "Reading")) { markdownMode = "reading" }
                        Button(t("双语预览", "Bilingual preview")) { markdownMode = "bilingual" }.disabled(!resultMatches)
                        if let result = value.currentResult, let document = result.markdown {
                            Menu(t("合并段落", "Merge paragraphs")) {
                                ForEach(document.groups.filter { document.canMerge($0.id) }) { group in
                                    Button(String(document.source(for: group).trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))) {
                                        _ = session.mergeMarkdownGroup(resultID: result.id, groupID: group.id)
                                    }
                                }
                            }.disabled(session.isRunning || !resultMatches || !document.groups.contains(where: { document.canMerge($0.id) }))
                        }
                    } label: { Image(systemName: "text.badge.checkmark") }.menuStyle(.borderlessButton).frame(width: 25).help(t("译文视图", "Translation view")).disabled(session.isRunning)
                }
            }.padding(.horizontal, 12).padding(.top, 8).frame(height: 42)
            Group {
                if value.isMarkdown && ["reading", "bilingual"].contains(markdownMode) {
                    if markdownMode == "bilingual", !resultMatches {
                        Text(t("原文、方向或输入格式已修改。重新翻译后可查看当前双语内容。", "Source, direction or input format changed. Translate again to view current bilingual content.")).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).frame(height: editorHeight)
                    } else {
                        MarkdownReadingView(text: markdownMode == "bilingual" ? value.currentResult?.markdown?.bilingual ?? value.translation : value.translation).frame(height: editorHeight)
                    }
                } else {
                    TextWorkspaceEditor(text: value.translation, label: t("编辑译文", "Editable translation"), actions: targetActions, monospaced: value.isMarkdown, isEditable: !session.isRunning,
                        changed: { session.updateTranslation(text: $0) },
                        composition: { if $0 && session.isRunning { session.stop() } }, selection: systemTools.lookup)
                        .id(session.workspaceRevision.uuidString + "target").frame(height: editorHeight)
                }
            }
            .opacity(session.isRunning ? 0 : 1)
            .allowsHitTesting(!session.isRunning)
            .accessibilityHidden(session.isRunning)
            .overlay(alignment: .topLeading) {
                if session.isRunning {
                    TextTranslationLoadingView(label: t("正在翻译…", "Translating…"))
                }
            }
            HStack(spacing: 3) {
                icon(t("撤销译文", "Undo translation"), "arrow.uturn.backward", action: targetActions.undo).disabled(session.isRunning || (value.isMarkdown && markdownMode != "edit") || !targetActions.canUndo)
                icon(t("重做译文", "Redo translation"), "arrow.uturn.forward", action: targetActions.redo).disabled(session.isRunning || (value.isMarkdown && markdownMode != "edit") || !targetActions.canRedo)
                icon(systemTools.speaking ? t("停止朗读", "Stop reading") : t("朗读译文", "Read translation"), systemTools.speaking ? "stop.fill" : "speaker.wave.2") { systemTools.toggleSpeech(value.translation, languageCode: (value.currentResult?.direction ?? value.direction).targetLanguage.rawValue) }.disabled(!systemTools.speaking && (session.isRunning || value.translation.isEmpty))
                icon(t("复制译文", "Copy translation"), "doc.on.doc") { copy(session.workspace.translation) }.disabled(session.isRunning || value.translation.isEmpty)
                    .modifier(TextFooterGeometryObservation(name: "target.previous", observer: footerGeometryObserver))
                TextActionMenu(label: t("导出译文", "Export translation"), symbol: "square.and.arrow.up", actions: exportActions(value))
                    .disabled(session.isRunning || value.translation.isEmpty)
                    .modifier(TextFooterGeometryObservation(name: "target.menu", observer: footerGeometryObserver))
                Spacer(minLength: 0)
                Button(t("翻译", "Translate")) { translate(value) }.buttonStyle(.borderedProminent)
                    .disabled(value.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || defaultProvider == nil || session.isRunning || session.hasPendingSave)
            }.padding(8)
        }.frame(maxWidth: .infinity).glassCard()
    }
    private func tools(_ value: TextWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(t("翻译工具", "Translation tools")).font(.callout.weight(.semibold)); Spacer(); icon(t("收起翻译工具", "Hide translation tools"), "sidebar.right") { toolsVisible = false } }
            Picker(t("输入格式", "Input format"), selection: Binding(get: { value.isMarkdown }, set: { _ = session.setMarkdown(enabled: $0) })) {
                Text(t("文本", "Text")).tag(false); Text("Markdown").tag(true)
            }.pickerStyle(.segmented)
            if let resources {
                TranslationResourcePicker(library: resources, selection: Binding(get: { value.resourceSelection ?? resources.selection(for: .text) }, set: { _ = session.selectResources(selection: $0) }), use: .text, manage: openSettings, compact: true)
            }
            Divider()
            Text(t("使用设置中的文本默认服务。按回车翻译，Shift + 回车换行。", "Uses the default text service in Settings. Enter translates; Shift + Enter adds a line break."))
                .font(.caption).foregroundStyle(.secondary)
            if defaultProvider == nil {
                Text(t("请先在设置中选择文本默认服务。", "Choose a default text service in Settings first."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(t("服务设置", "Service settings"), action: openSettings).buttonStyle(.link)
            if let result = value.currentResult, let failure = result.failure { Text(errorText(failure)).font(.caption).foregroundStyle(.red) }
            if let result = value.currentResult, result.markdown != nil, !value.currentResultMatchesWorkspace {
                Text(t("重新翻译后可导出符合当前原文、方向和输入格式的双语 Markdown。", "Translate again to export bilingual Markdown for the current source, direction and input format.")).font(.caption).foregroundStyle(.secondary)
            }
            if systemTools.speechUnavailable { Text(t("本机没有适用的朗读声音。可在系统设置中安装。", "No suitable speech voice is installed. Add one in System Settings.")).font(.caption).foregroundStyle(.secondary) }

        }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(t("词典", "Dictionary")).font(.callout.weight(.semibold)); Spacer(); Text(t("系统本地词典", "Local system dictionary")).font(.caption2).foregroundStyle(.secondary) }
            if systemTools.dictionaryTerm.isEmpty { Text(t("选择原文或译文中的词语以查询。", "Select a word in either editor to look it up.")).font(.callout).foregroundStyle(.secondary) }
            else {
                Text(systemTools.dictionaryTerm).font(.headline)
                if systemTools.lookupPending { ProgressView().controlSize(.small) }
                else { Text(systemTools.formattedDefinition ?? t("已启用的本地词典没有可用释义。可在“词典”App 中检查词典。", "No definition is available in the enabled local dictionaries. Check Dictionary.app.")).font(.callout).textSelection(.enabled) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
    private var automaticSourceLabel: String {
        let base = t("自动检测", "Detect language")
        if session.isDetectingSourceLanguage { return base + t(" · 识别中", " · Detecting") }
        if let detected = session.detectedSourceLanguage { return base + " · " + detected.title(language) }
        return session.workspace.inputDraft.isEmpty ? base : base + t(" · 未确定", " · Unknown")
    }
    private func exportActions(_ value: TextWorkspace) -> [TextActionMenu.Action] {
        var actions: [TextActionMenu.Action] = [
            .init(title: t("导出 TXT", "Export TXT"), perform: { export(value, kind: "txt") }),
            .init(title: t("导出 Markdown", "Export Markdown"), perform: { export(value, kind: "md") })
        ]
        if value.currentResult?.markdown != nil {
            actions.append(.init(title: t("导出双语 Markdown", "Export bilingual Markdown"), enabled: value.currentResultMatchesWorkspace, perform: { export(value, kind: "bilingual") }))
        }
        return actions
    }
    private func icon(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 17, height: 17) }.buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true)).help(label).accessibilityLabel(label)
    }
    private func translate(_ value: TextWorkspace) {
        guard let provider = defaultProvider, !session.isRunning, !session.hasPendingSave,
              !value.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await session.submit(provider: provider, direction: value.direction, resources: resources) }
    }
    private var defaultProvider: ProviderSnapshot? {
        guard let id = providers.defaults.textID else { return nil }
        return try? providers.snapshot(for: id)
    }
    private func importText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if session.importText(from: url) { sourceRendered = false; markdownMode = "edit" }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func export(_ value: TextWorkspace, kind: String) {
        let panel = NSSavePanel(); let markdown = ["md", "bilingual"].contains(kind)
        panel.allowedContentTypes = [markdown ? UTType(filenameExtension: "md") ?? .plainText : .plainText]
        panel.nameFieldStringValue = ExportFilename.record(bilingual: kind == "bilingual", extension: markdown ? "md" : "txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == "source" { _ = session.exportInput(to: url) }
        else if kind == "bilingual", let result = value.currentResult { _ = session.exportBilingual(resultID: result.id, to: url) }
        else { _ = session.exportTranslation(to: url) }
    }
    private func errorText(_ error: TextTranslationError) -> String {
        switch error {
        case .configuration: return t("请检查所选服务的地址与模型。", "Check the selected service address and model.")
        case .credential: return t("无法读取 API Key。请在服务设置中检查。", "Cannot read the API key. Check Service settings.")
        case .modelUnavailable: return t("此服务的模型不可用。", "The selected model is unavailable.")
        case .rateLimited: return t("服务已限流，请稍后手动重试。", "The service rate limit was reached. Retry manually later.")
        case .network: return t("连接中断，已收到的译文仍保留。", "Connection interrupted. Received text is retained.")
        case .processing: return t("翻译未完成，当前内容仍保留。", "Translation did not finish. Current contents are retained.")
        case .storage: return t("部分文本历史无法保存或读取，当前编辑仍保留。", "Some text history could not be saved or read. Current edits are retained.")
        case .interrupted: return t("上次翻译已中断；可手动重新翻译。", "The previous translation was interrupted. Translate again manually.")
        case .emptyInput: return t("请输入原文。", "Enter source text.")
        case .structure:
            if !session.workspace.isMarkdown {
                return t("译文没有保留原文的逐行对应，请重新翻译。", "The translation did not preserve the source lines. Translate again.")
            }
            return t("此修改会破坏 Markdown 的代码、链接、公式或段落对应。请只编辑一个正文片段。", "This edit would break protected Markdown or paragraph correspondence. Edit within one text passage.")
        case .languageUndetermined: return t("无法确定原文语言。请选择原文语言后翻译。", "Could not determine the source language. Select it manually before translating.")
        case .resources: return t("术语表或提示词选择已失效，请重新选择。", "A glossary or instruction selection is unavailable. Select it again.")
        }
    }
}

/// Optional observation at the real footer call sites; the normal view installs
/// no geometry readers. Native control regressions need both layout and AppKit
/// bounds from the same hosted production view.
private struct TextFooterGeometryObserverKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var textFooterGeometryObserver: ((String, CGRect) -> Void)? {
        get { self[TextFooterGeometryObserverKey.self] }
        set { self[TextFooterGeometryObserverKey.self] = newValue }
    }
}
private struct TextFooterGeometryObservation: ViewModifier {
    let name: String
    let observer: ((String, CGRect) -> Void)?
    func body(content: Content) -> some View {
        content.background {
            if let observer {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.frame(in: .named("TextTranslationFooter")), initial: true) { _, frame in
                        observer(name, frame)
                    }
                }
            }
        }
    }
}
