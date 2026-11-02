import SwiftUI
import WorkbenchCore

private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor struct PDFRuntimeStatusView: View {
    @ObservedObject var session: PDFRuntimePreparationSession
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var language: AppLanguage { AppLanguage(preference: languageChoice) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh,en) }
    @ViewState private var showsDetails = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(session.isReady ? Color.green : (session.error != nil ? Color.red : Color.orange)).frame(width: 6, height: 6)
            Button { showsDetails.toggle() } label: {
                HStack(spacing: 5) { Text(statusLabel).modifier(HistoryGeometryObservation(name: "pdf.header.status.label")); Image(systemName: "info.circle") }.font(.caption)
            }.buttonStyle(.plain).help(t("查看 PDF 组件状态", "Show PDF component status"))
                .accessibilityLabel(t("PDF 组件状态：", "PDF component status: ") + statusLabel)
            if session.isPreparing {
                Button(t("停止", "Stop")) { session.cancel() }.buttonStyle(.borderless).font(.caption)
            } else if !session.isReady {
                Button(t("重试", "Retry")) { session.prepare() }.buttonStyle(.borderless).font(.caption)
            }
        }.padding(.horizontal, 12).frame(minHeight: 34)
            .background(.white.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.9)))
            .modifier(HistoryGeometryObservation(name: "pdf.header.status"))
            .popover(isPresented: $showsDetails) { details.frame(width: 350) }
    }
    private var statusLabel: String {
        if session.isReady { return t("PDF 已就绪", "PDF ready") }
        if session.isPreparing {
            let base = t("PDF 组件准备中", "Preparing PDF components")
            guard let progress = session.progress else { return base }
            if progress.phase == .downloading, progress.totalBytes > 0 {
                return base + " · \(Int(100 * Double(progress.completedBytes) / Double(progress.totalBytes)))%"
            }
            return base
        }
        return session.error != nil ? t("PDF 组件未就绪", "PDF components unavailable") : t("PDF 组件待准备", "PDF components needed")
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("PDF 运行组件", "PDF components")).font(.headline)
            if session.isReady {
                Label(t("已验证，可翻译 PDF", "Verified and ready to translate"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if session.isPreparing {
                if let progress = session.progress {
                    Text(title(progress.phase))
                    if progress.phase == .downloading, progress.totalBytes > 0 {
                        ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)) · \(progress.completedFiles)/\(progress.totalFiles)").font(.caption).monospacedDigit()
                    } else if progress.totalFiles > 0 {
                        ProgressView(value: Double(progress.completedFiles), total: Double(progress.totalFiles))
                    } else { ProgressView().controlSize(.small) }
                }
                Button(t("停止准备", "Stop preparation")) { session.cancel() }
            } else if let error = session.error {
                Text(error.description(language)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button(t("重试准备", "Retry preparation")) { session.prepare() }.buttonStyle(.borderedProminent)
            } else {
                Text(t("首次准备约需下载 592 MB。已下载并校验的组件会复用，资料导入和其他功能可继续使用。", "First preparation downloads about 592 MB. Verified components are reused. Import and other workflows remain available."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
    private func title(_ phase: PDFRuntimeProgress.Phase) -> String {
        switch phase {
        case .checking: return t("正在检查已保存组件…", "Checking saved components…")
        case .downloading: return t("正在下载并校验组件…", "Downloading and verifying components…")
        case .installing: return t("正在安装运行环境…", "Installing the runtime…")
        case .verifying: return t("正在验证引擎、字体和模型…", "Verifying the engine, fonts and model…")
        }
    }
}
