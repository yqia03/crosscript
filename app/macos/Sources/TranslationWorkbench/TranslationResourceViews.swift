import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias ResourceState<Value> = SwiftUI.State<Value>

/// The same library and picker serve PDF and text; only their remembered
/// selections differ. A submitted request receives an immutable core snapshot.
@MainActor
struct TranslationResourcePicker: View {
    @ObservedObject var library: TranslationResourceLibrary
    @Binding var selection: TranslationResourceSelection
    let use: ProviderUse
    let manage: () -> Void
    var compact = false
    @AppStorage("interfaceLanguage") private var language = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(compact ? t("翻译风格与术语表", "Style and glossaries") : t("术语与提示词", "Terminology and instructions"), systemImage: "books.vertical")
                Spacer()
                if compact {
                    Button(action: manage) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true))
                        .help(t("管理共用库", "Manage shared library"))
                        .accessibilityLabel(t("管理共用库", "Manage shared library"))
                } else {
                    Button(t("管理共用库", "Manage shared library"), action: manage).buttonStyle(.borderless)
                }
            }
            Picker(t("提示词预设", "Instruction preset"), selection: $selection.promptID) {
                Text(t("不使用预设", "No preset")).tag(UUID?.none)
                ForEach(library.prompts) { prompt in Text(prompt.displayName(AppLanguage(preference: language))).tag(Optional(prompt.id)) }
            }
            if library.glossaries.isEmpty {
                Text(t("尚无术语表，可在共用库中创建或导入。", "Create or import a glossary in the shared library.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(library.glossaries) { glossary in
                Toggle(glossary.name, isOn: Binding(get: { selection.glossaryIDs.contains(glossary.id) }, set: { selected in
                    selection.glossaryIDs.removeAll { $0 == glossary.id }
                    if selected { selection.glossaryIDs.append(glossary.id) }
                }))
            }
            Button { _ = library.setSelection(selection, for: use) } label: {
                if compact {
                    Label(t("保存为默认选择", "Save as defaults"), systemImage: "checkmark.circle").font(.caption)
                } else {
                    Text(t("记为此模块默认选择", "Remember for this module"))
                }
            }.buttonStyle(.borderless)
                .help(t("将当前提示词预设和术语表记为此模块的默认选择", "Remember the current instruction preset and glossaries as this module's defaults"))
                .accessibilityLabel(t("记为此模块默认选择", "Remember for this module"))
            if library.error != nil { TranslationResourceErrorView(library: library) }
        }.font(.callout)
    }
}

@MainActor
struct TranslationResourceManagementView: View {
    @ObservedObject var library: TranslationResourceLibrary
    @AppStorage("interfaceLanguage") private var language = "system"
    @ResourceState private var glossaryDraft: GlossaryEditDraft?
    @ResourceState private var promptDraft: PromptEditDraft?
    @ResourceState private var deletion: ResourceDeletion?
    @ResourceState private var importError: String?
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("共用术语与提示词库", "Shared terminology and instruction library"), systemImage: "books.vertical").font(.headline)
            Text(t("术语表指定词语译法；提示词预设说明表达方式。PDF 与文本共用内容，各自记忆默认选择。库的修改只用于之后提交的任务。", "Glossaries specify term translations; presets describe writing instructions. PDF and Text share this library and remember separate defaults. Edits apply to later submissions.")).font(.callout).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { glossaryActions; Spacer() }
                VStack(alignment: .leading) { glossaryActions }
            }
            ForEach(library.glossaries) { glossary in
                VStack(alignment: .leading, spacing: 8) {
                    Text(glossary.name).font(.headline)
                    Text(t("\(glossary.entries.count) 个术语", "\(glossary.entries.count) terms")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(t("编辑", "Edit")) { glossaryDraft = .init(glossary: glossary) }
                        Button(t("导出 CSV", "Export CSV")) { export(glossary) }
                        Button(t("删除…", "Delete…"), role: .destructive) { deletion = .glossary(glossary) }
                    }.buttonStyle(.borderless)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Button(t("新建提示词预设", "New instruction preset")) { promptDraft = .init() }
            ForEach(library.prompts) { prompt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.displayName(AppLanguage(preference: language))).font(.headline)
                    Text(prompt.instruction).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    HStack {
                        Button(prompt.isBuiltIn ? t("复制后编辑", "Customize a copy") : t("编辑", "Edit")) {
                            promptDraft = .init(prompt: prompt, duplicate: prompt.isBuiltIn)
                        }
                        if !prompt.isBuiltIn {
                            Button(t("删除…", "Delete…"), role: .destructive) { deletion = .prompt(prompt) }
                        }
                    }.buttonStyle(.borderless)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            if library.error != nil { TranslationResourceErrorView(library: library) }
            if let importError { Text(importError).foregroundStyle(.red).font(.callout) }
        }.padding(24).glassCard()
            .sheet(item: $glossaryDraft) { draft in GlossaryEditor(library: library, draft: draft) }
            .sheet(item: $promptDraft) { draft in PromptEditor(library: library, draft: draft) }
            .alert(t("删除库中的项目？", "Delete library item?"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button(t("取消", "Cancel"), role: .cancel) { deletion = nil }
                Button(t("删除", "Delete"), role: .destructive) {
                    switch deletion {
                    case .glossary(let value): _ = library.deleteGlossary(value.id)
                    case .prompt(let value): _ = library.deletePrompt(value.id)
                    case nil: break
                    }
                    deletion = nil
                }
            } message: { Text(t("将从未来任务的默认选择中移除。已提交任务和既有结果保留当时的副本。", "This removes the item from future defaults. Submitted tasks and existing results keep their saved copies.")) }
    }
    private var glossaryActions: some View {
        Group {
            Button(t("新建术语表", "New glossary")) { glossaryDraft = .init() }
            Button(t("导入 CSV…", "Import CSV…")) { importGlossary() }
        }
    }
    private func importGlossary() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? 0) <= 10_000_000 else { throw TranslationResourceError.invalidCSV }
            let text = try String(contentsOf: url, encoding: .utf8)
            let glossary = try TranslationGlossary.importCSV(text, name: String(url.deletingPathExtension().lastPathComponent.prefix(120)))
            glossaryDraft = .init(glossary: glossary); importError = nil
        } catch { importError = t("无法导入。请使用 UTF-8 CSV，列名为 source,target，另可选 tgt_lng；每行都需有原词和译词。", "Import failed. Use UTF-8 CSV with source,target and optional tgt_lng columns; each row needs a source and translation.") }
    }
    private func export(_ glossary: TranslationGlossary) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = ExportFilename.suggested(glossary.name, extension: "csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try glossary.csv.write(to: url, atomically: true, encoding: .utf8); importError = nil }
        catch { importError = t("导出失败，术语表仍保留。请检查目标文件夹权限后重试。", "Export failed. The glossary is retained. Check destination permissions and retry.") }
    }
}

private enum ResourceDeletion { case glossary(TranslationGlossary), prompt(TranslationPromptPreset) }
private struct GlossaryEditDraft: Identifiable {
    let id: UUID
    var name: String
    var rows: [TermRow]
    init(glossary: TranslationGlossary = .init(name: "", entries: [])) {
        id = glossary.id; name = glossary.name; rows = glossary.entries.map(TermRow.init)
    }
    var value: TranslationGlossary { .init(id: id, name: name, entries: rows.map { .init(source: $0.source, target: $0.target, targetLanguage: $0.language.isEmpty ? nil : $0.language) }) }
}
private struct TermRow: Identifiable {
    let id = UUID()
    var source: String; var target: String; var language: String
    init(_ term: TranslationTerm = .init(source: "", target: "")) { source = term.source; target = term.target; language = term.targetLanguage ?? "" }
}
private struct PromptEditDraft: Identifiable {
    let id: UUID; var name: String; var instruction: String
    init(prompt: TranslationPromptPreset = .init(name: "", instruction: ""), duplicate: Bool = false) {
        id = duplicate ? UUID() : prompt.id; name = prompt.name; instruction = prompt.instruction
    }
    var value: TranslationPromptPreset { .init(id: id, name: name, instruction: instruction) }
}

@MainActor private struct GlossaryEditor: View {
    @ObservedObject var library: TranslationResourceLibrary
    @ResourceState var draft: GlossaryEditDraft
    @Environment(\.dismiss) private var dismiss
    @AppStorage("interfaceLanguage") private var language = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("编辑术语表", "Edit glossary")).font(.title2)
            TextField(t("名称", "Name"), text: $draft.name)
            Text(t("目标语言留空适用于所有方向，或填写 zh、en 等语言代码。", "Leave target language empty for every direction, or enter a language code such as zh or en.")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($draft.rows) { $row in
                        VStack(alignment: .leading, spacing: 7) {
                            TextField(t("原词", "Source term"), text: $row.source, axis: .vertical)
                            TextField(t("译词", "Translated term"), text: $row.target, axis: .vertical)
                            HStack {
                                TextField(t("目标语言（可选）", "Target language (optional)"), text: $row.language)
                                Button(t("移除此行", "Remove row"), role: .destructive) { draft.rows.removeAll { $0.id == row.id } }
                            }
                        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 220, maxHeight: 420)
            Button(t("添加术语", "Add term")) { draft.rows.append(.init()) }.disabled(draft.rows.count >= 10_000)
            if library.error != nil { TranslationResourceErrorView(library: library) }
            HStack {
                Button(t("取消编辑", "Cancel editing")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("保存术语表", "Save glossary")) { if library.saveGlossary(draft.value) { dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(minWidth: 440, idealWidth: 560).interactiveDismissDisabled()
    }
}

@MainActor private struct PromptEditor: View {
    @ObservedObject var library: TranslationResourceLibrary
    @ResourceState var draft: PromptEditDraft
    @Environment(\.dismiss) private var dismiss
    @AppStorage("interfaceLanguage") private var language = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("编辑提示词预设", "Edit instruction preset")).font(.title2)
            TextField(t("名称", "Name"), text: $draft.name).textFieldStyle(.roundedBorder)
            Text(t("描述译文风格与要求。实际模型可能不完全遵循。", "Describe translation style and requirements. Model adherence can vary.")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.instruction).frame(minHeight: 220, maxHeight: 420).border(.quaternary)
                .accessibilityLabel(t("提示词内容", "Instruction text"))
            if library.error != nil { TranslationResourceErrorView(library: library) }
            HStack {
                Button(t("取消编辑", "Cancel editing")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("保存预设", "Save preset")) { if library.savePrompt(draft.value) { dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 440, idealWidth: 560).interactiveDismissDisabled()
    }
}

@MainActor private struct TranslationResourceErrorView: View {
    @ObservedObject var library: TranslationResourceLibrary
    @AppStorage("interfaceLanguage") private var language = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: language).text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout).foregroundStyle(.red)
            if library.needsSave { Button(t("重试本地保存", "Retry local save")) { _ = library.retrySaving() } }
        }
    }
    private var message: String {
        switch library.error {
        case .invalidInput, .invalidCSV: return t("请检查名称和内容：名称不能为空且最多 120 字，术语两侧不能为空，提示词最多 20,000 字。", "Check names and contents: names need 1–120 characters, terms need both sides, and instructions allow up to 20,000 characters.")
        case .storage: return t("库未能保存或读取。已保留原文件与当前草稿，请检查磁盘空间和权限后重试。", "The library could not be saved or read. Original files and current drafts are retained. Check disk space and permissions, then retry.")
        case .unavailable: return t("选择已失效或库尚未保存。请重新选择，或先保存库中的修改。", "A selection is unavailable or library edits are unsaved. Select again or save the library first.")
        case nil: return ""
        }
    }
}

@MainActor struct TranslationResourceSnapshotView: View {
    let snapshot: TranslationResourceSnapshot
    @AppStorage("interfaceLanguage") private var preference = "system"
    private func t(_ zh: String, _ en: String) -> String { AppLanguage(preference: preference).text(zh, en) }
    var body: some View {
        DisclosureGroup(t("提交时的术语与提示词", "Submitted terminology and instructions")) {
            VStack(alignment: .leading, spacing: 10) {
                if let prompt = snapshot.prompt { Text(prompt.displayName(AppLanguage(preference: preference))).font(.headline); Text(prompt.instruction).textSelection(.enabled) }
                else { Text(t("未使用提示词预设", "No instruction preset")) }
                if snapshot.glossaries.isEmpty { Text(t("未使用术语表", "No glossary selected")) }
                ForEach(snapshot.glossaries) { glossary in
                    DisclosureGroup(glossary.name + " (\(glossary.entries.count))") {
                        ForEach(Array(glossary.entries.enumerated()), id: \.offset) { _, term in
                            Text(term.source + " → " + term.target + (term.targetLanguage.map { " [\($0)]" } ?? ""))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                }
            }.font(.caption).padding(.top, 8)
        }.font(.callout)
    }
}
