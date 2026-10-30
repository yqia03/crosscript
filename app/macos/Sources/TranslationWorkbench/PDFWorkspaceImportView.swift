import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

private typealias ViewState<Value> = SwiftUI.State<Value>

/// Loading file promises is serialized so two successive drops append in the
/// order the user made them, regardless of provider callback timing.
@MainActor final class PDFDropImporter: ObservableObject {
    private var pending: Task<Void, Never>?
    func append(_ providers: [NSItemProvider], to session: PDFTranslationSession) {
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(provider) { urls.append(url) }
            }
            let scopes = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, scoped) in zip(urls, scopes) where scoped { url.stopAccessingSecurityScopedResource() } }
            _ = session.importPDFs(urls)
        }
    }
    static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }
}

@MainActor struct PDFWorkspaceImportView: View {
    @ObservedObject var session: PDFTranslationSession
    let canSubmit: Bool
    let localOnly: Bool
    let chooseFiles: () -> Void
    let submit: () -> Void
    @StateObject private var drops = PDFDropImporter()
    @ViewState private var isTargeted = false
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }
    private var materials: [PDFMaterial] { session.workspaceMaterials }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("导入 PDF", "Import PDF")).font(.headline)
            GeometryReader { geometry in
                ScrollView {
                    if materials.isEmpty {
                        addFile(empty: true).frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    } else {
                        fileRows(width: geometry.size.width)
                            .padding(10).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                    }
                }
            }
            .frame(minHeight: 150)
            .background(isTargeted ? Color.accentColor.opacity(0.13) : Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.accentColor.opacity(isTargeted ? 0.7 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [5, 4])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                drops.append(providers, to: session); return !providers.isEmpty
            }
            .accessibilityIdentifier("pdf-import-dropzone")
            Button(action: submit) {
                Label(localOnly ? t("本地生成 PDF", "Generate PDF locally") : (materials.count > 1 ? t("开始翻译（\(materials.count) 个文件）", "Translate \(materials.count) files") : t("开始翻译 PDF", "Translate PDF")), systemImage: "arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!canSubmit || !session.hasSubmittableWorkspaceMaterials)
                .accessibilityIdentifier("pdf-submit-workspace")
            if !visibleTasks.isEmpty {
                ScrollView { VStack(spacing: 6) { ForEach(visibleTasks) { entry in taskRow(entry) } } }
                    .frame(height: 76).accessibilityLabel(t("文件翻译进度", "File translation progress"))
            }
        }.padding(18).glassCard()
    }
    private func fileRows(width: CGFloat) -> some View {
        let columns = max(1, Int((width - 20 + 10) / (134 + 10)))
        let rowCount = (materials.count + 1 + columns - 1) / columns
        return LazyVStack(spacing: 10) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(Array(materials.dropFirst(row * columns).prefix(columns))) { file in
                        fileCard(file).frame(width: 134)
                    }
                    if row == materials.count / columns {
                        addFile(empty: false).frame(width: 134, height: 132)
                    }
                }.frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    private func addFile(empty: Bool) -> some View {
        Button(action: chooseFiles) {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").font(.system(size: empty ? 34 : 28, weight: .light))
                Text(empty ? t("将 PDF 拖到这里", "Drop PDFs here") : t("继续添加 PDF", "Add more PDFs")).font(empty ? .headline : .callout)
                Text(empty ? t("或点击选择文件", "Or click to choose files") : t("点击选择，或拖入新文件", "Choose or drop more files")).font(.caption).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).foregroundStyle(.tint)
            .background(.white.opacity(empty ? 0 : 0.25), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(empty ? 0 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityLabel(t("选择或拖入 PDF 文件", "Choose or drop PDF files"))
            .accessibilityIdentifier("pdf-workspace-add")
    }
    private func fileCard(_ file: PDFMaterial) -> some View {
        VStack(spacing: 0) {
            Button { session.open(file.id) } label: {
                VStack(spacing: 5) {
                    Image(systemName: "doc.richtext").font(.system(size: 25, weight: .light)).foregroundStyle(.tint)
                    Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    if let metadata = session.sourceMetadata[file.id] {
                        Text(t("\(metadata.pageCount) 页", "\(metadata.pageCount) pages") + " · " + ByteCountFormatter.string(fromByteCount: metadata.byteCount, countStyle: .file))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.horizontal, 7).padding(.top, 9).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(t("查看 ", "View ") + file.name)
                .accessibilityIdentifier("pdf-workspace-file-\(file.id)")
                .accessibilityAddTraits(session.selectedID == file.id ? .isSelected : [])
                .help(file.name)
            Button { session.removeFromWorkspace(file.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 22, height: 22)
                    .background(.secondary.opacity(0.07), in: Circle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 7)
                .accessibilityLabel(t("从导入区移除 ", "Remove from workspace: ") + file.name)
                .help(t("从导入区移除，保留历史和任务", "Remove from workspace; keep history and tasks"))
        }.frame(height: 132).frame(maxWidth: .infinity)
            .background(.white.opacity(session.selectedID == file.id ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(session.selectedID == file.id ? Color.accentColor.opacity(0.5) : .white.opacity(0.7)))
    }
    struct TaskEntry: Identifiable {
        let material: PDFMaterial
        let task: PDFBackgroundTask
        var id: UUID { task.id }
    }
    private var visibleTasks: [TaskEntry] {
        Self.taskEntries(for: materials, runningTaskID: session.runningTaskID)
    }
    static func taskEntries(for materials: [PDFMaterial], runningTaskID: UUID?) -> [TaskEntry] {
        materials.compactMap { material in
            // A cancelled worker still owns the material until its process exits.
            let task = material.tasks.first { $0.id == runningTaskID }
                ?? material.tasks.last { $0.status.occupiesMaterial }
                ?? material.tasks.last
            return task.map { TaskEntry(material: material, task: $0) }
        }
    }
    private func taskRow(_ entry: TaskEntry) -> some View {
        let task = entry.task, material = entry.material
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 48, height: 1).accessibilityHidden(true)
                VStack(spacing: 2) {
                    if materials.count > 1 { Text(material.name).font(.caption).lineLimit(1) }
                    Text(session.authorizingTaskID == task.id ? t("等待钥匙串授权…", "Waiting for Keychain authorization…") : task.statusDescription(language)).font(.caption)
                    Text(task.provider.map { $0.name + " · " + $0.model } ?? t("本地处理", "Local processing")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if [.awaitingResume, .interrupted].contains(task.status), task.options.requiresService {
                        Text(t("恢复将重新处理，可能产生费用", "Resume starts over and may incur charges")).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failure = task.failure { Text(failure.description(language)).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
                VStack {
                    if [.running, .queued, .awaitingResume, .interrupted].contains(task.status) {
                        Button(t("取消", "Cancel")) { session.cancel(materialID: material.id, taskID: task.id) }
                    } else if [.failed, .cancelled].contains(task.status) {
                        Button(t("重试", "Retry")) { _ = session.retry(materialID: material.id, taskID: task.id) }
                            .disabled(!session.pendingSaveIDs.isEmpty || session.hasQueuedOrRunningTask(material.id))
                    }
                    if [.awaitingResume, .interrupted].contains(task.status) {
                        Button(t("恢复", "Resume")) { _ = session.retry(materialID: material.id, taskID: task.id) }
                            .disabled(!session.pendingSaveIDs.isEmpty || session.hasQueuedOrRunningTask(material.id))
                    }
                }.buttonStyle(.borderless).font(.caption).frame(width: 48)
                    .help(task.options.requiresService ? t("重新提交会从头处理，并可能产生新的服务费用。", "Submitting again starts from the beginning and may incur service charges.") : t("仅在本机重新处理", "Repeat local processing only"))
            }
            if session.runningTaskID == task.id, task.status == .running, let progress = session.progress {
                ProgressView(value: progress.percent, total: 100).controlSize(.small)
                    .accessibilityLabel(progress.stage)
            }
        }.padding(.horizontal, 8).padding(.vertical, 6).background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }
}
