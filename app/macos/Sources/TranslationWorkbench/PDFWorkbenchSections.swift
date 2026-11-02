import SwiftUI
import WorkbenchCore

/// Shared by the PDF sheet and global history; opening only changes the current
/// import list and selection, never the retained files or processing tasks.
@MainActor struct PDFHistorySection: View {
    @ObservedObject var session: PDFTranslationSession
    let open: (UUID) -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text(language.text("\(session.materials.count) 份 PDF", "\(session.materials.count) PDF materials")).font(.caption).foregroundStyle(.secondary)
            if session.materials.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(language.text("还没有 PDF 历史", "No PDF history yet")).font(.headline)
                    Text(language.text("导入的 PDF 和翻译结果会保存在这里。", "Imported PDFs and translation results will appear here."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(36).glassCard()
                    .modifier(HistoryGeometryObservation(name: "pdf.empty"))
            }
            ForEach(session.materials.sorted { $0.updatedAt > $1.updatedAt }) { material in
                HStack(spacing: 15) {
                    Image(systemName: "doc.richtext").font(.system(size: 20)).foregroundStyle(.tint)
                        .frame(width: 43, height: 48).background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(material.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).help(material.name)
                        Text(language.text("\(material.results.count) 份独立 PDF 结果", "\(material.results.count) independent PDF results")).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pdf-history-results-" + material.id.uuidString)
                        if let metadata = session.sourceMetadata[material.id] {
                            Text(language.text("\(metadata.pageCount) 页", "\(metadata.pageCount) pages") + " · " + ByteCountFormatter.string(fromByteCount: metadata.byteCount, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("pdf-history-metadata-" + material.id.uuidString)
                        }
                        if session.pendingSaveIDs.contains(material.id) {
                            Text(language.text("结果待本地保存", "Result needs local save")).font(.caption).foregroundStyle(.orange)
                                .accessibilityIdentifier("pdf-history-pending-" + material.id.uuidString)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.open(material.id); open(material.id) } label: {
                        Label(language.text("打开", "Open"), systemImage: "arrow.up.forward")
                    }.buttonStyle(WorkbenchCompactButtonStyle())
                        .accessibilityIdentifier("pdf-history-open-" + material.id.uuidString)
                        .accessibilityLabel(language.text("打开 PDF：", "Open PDF: ") + material.name)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                    .modifier(HistoryGeometryObservation(name: "pdf." + material.id.uuidString))
            }
        }.historyScrollGutter()
            .onChange(of: session.materials.map(\.id), initial: true) { _, _ in session.prepareHistoryMetadata() }
    }
}

@MainActor struct PDFHistoryView: View {
    @ObservedObject var session: PDFTranslationSession
    let close: () -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("PDF 历史记录", "PDF history")).font(.title2)
                Spacer(minLength: 12)
                Button(language.text("完成", "Done"), action: close)
                    .buttonStyle(WorkbenchCompactButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pdf-history-done")
            }
            ScrollView { PDFHistorySection(session: session) { _ in close() }.padding(2) }
        }.padding(24).frame(minWidth: 460, idealWidth: 700, minHeight: 420, idealHeight: 640)
    }
}

@MainActor struct PDFQueueSection: View {
    @ObservedObject var session: PDFTranslationSession
    let open: (UUID) -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    private var language: AppLanguage { AppLanguage(preference: preference) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("PDF 后台任务", "PDF background tasks")).font(.headline)
            Text(language.text("PDF 与录后转写共用一个后台执行名额；实时采集和文本翻译独立运行。", "PDF and post-recording transcription share one background slot. Live capture and text translation run independently.")).font(.caption).foregroundStyle(.secondary)
            ForEach(session.materials) { material in
                ForEach(material.tasks.reversed()) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Button(material.name) { session.open(material.id); open(material.id) }.buttonStyle(.borderless)
                        Text(task.provider.map { $0.name + " · " + $0.model } ?? language.text("本地处理 · 未翻译", "Local processing · Untranslated")).font(.caption).foregroundStyle(.secondary)
                        Text(task.statusDescription(language)).font(.callout)
                        if session.runningTaskID == task.id, let progress = session.progress {
                            ProgressView(value: progress.percent, total: 100)
                            Text(progress.stage).font(.caption)
                        }
                        HStack {
                            if [.queued, .running, .awaitingResume, .interrupted].contains(task.status) {
                                Button(language.text("取消", "Cancel")) { session.cancel(materialID: material.id, taskID: task.id) }
                            }
                            if [.failed, .cancelled, .interrupted, .awaitingResume].contains(task.status), session.runningTaskID != task.id {
                                Button(language.text("重新提交", "Submit again")) { _ = session.retry(materialID: material.id, taskID: task.id) }
                                    .disabled(!session.pendingSaveIDs.isEmpty || session.hasQueuedOrRunningTask(material.id))
                            }
                        }.buttonStyle(.borderless)
                        if [.failed, .cancelled, .interrupted, .awaitingResume].contains(task.status) {
                            Text(task.options.requiresService ? language.text("重新提交会从头处理，并可能产生新的服务费用。", "Submitting again starts from the beginning and may incur new service charges.") : language.text("重新提交会从头进行本地处理，不调用翻译服务。", "Submitting again repeats local processing without calling a translation service.")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = task.failure { Text(failure.description(language)).font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                }
            }
            if !session.pendingSaveIDs.isEmpty {
                Button(language.text("重试 PDF 本地保存", "Retry local PDF save")) { _ = session.retrySaving() }
            }
        }
    }
}

@MainActor struct PDFActivityStrip: View {
    @ObservedObject var session: PDFTranslationSession
    let open: (UUID) -> Void
    @AppStorage("interfaceLanguage") private var preference = "system"
    var body: some View {
        if let material = session.materials.first(where: { session.pendingSaveIDs.contains($0.id) || $0.tasks.contains { $0.id == session.runningTaskID } }) {
            Button { session.open(material.id); open(material.id) } label: {
                Label {
                    if session.pendingSaveIDs.contains(material.id) {
                        Text(AppLanguage(preference: preference).text("PDF 结果待保存 · ", "PDF result needs saving · ") + material.name)
                    } else if let task = material.tasks.first(where: { $0.id == session.runningTaskID }) {
                        Text("PDF · " + task.statusDescription(AppLanguage(preference: preference)) + " · " + material.name)
                    }
                } icon: { Image(systemName: "doc.richtext") }
                .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).padding(12).glassCard()
        }
    }
}
