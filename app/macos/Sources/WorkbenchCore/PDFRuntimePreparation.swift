import Combine
import Foundation

public struct PDFRuntimeProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case checking, downloading, installing, verifying }
    public var phase: Phase
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedFiles: Int
    public var totalFiles: Int
    public init(phase: Phase, completedBytes: Int64 = 0, totalBytes: Int64 = 0, completedFiles: Int = 0, totalFiles: Int = 0) {
        self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.completedFiles = completedFiles; self.totalFiles = totalFiles
    }
}
public struct PDFRuntimeReceipt: Equatable, Sendable {
    public let identifier: String
    public let reused: Bool
    public init(identifier: String, reused: Bool) { self.identifier = identifier; self.reused = reused }
}
public enum PDFRuntimeError: Error, Equatable, Sendable {
    case unsupportedPlatform, invalidManifest, downloadFailed(String), integrityMismatch(String), installationFailed, storageUnavailable, cancelled
    public func description(_ language: AppLanguage) -> String {
        switch self {
        case .unsupportedPlatform: return language.text("PDF 组件需要 Apple Silicon 和 macOS 14.2 或更新版本。", "PDF components require Apple Silicon and macOS 14.2 or later.")
        case .invalidManifest: return language.text("运行组件清单版本不匹配。请使用完整的 App 安装包。", "The component manifest is incompatible. Use a complete app package.")
        case .downloadFailed(let name): return language.text("无法下载 \(name)。请检查网络后重试。已导入资料仍保留。", "Could not download \(name). Check the network and retry. Imported material is retained.")
        case .integrityMismatch(let name): return language.text("\(name) 完整性校验失败，未启用不完整组件。请重试。", "Integrity check failed for \(name). Incomplete components were not activated. Retry preparation.")
        case .installationFailed: return language.text("PDF 运行组件安装或兼容性验证失败。已验证的下载仍保留，可重试。", "PDF component installation or compatibility verification failed. Verified downloads are retained for retry.")
        case .storageUnavailable: return language.text("无法保存 PDF 运行组件。请检查可用空间和资料目录权限后重试。", "Could not save PDF components. Check available space and library permissions, then retry.")
        case .cancelled: return language.text("已停止准备。已验证的下载会在重试时复用。", "Preparation stopped. Verified downloads will be reused on retry.")
        }
    }
}
public protocol PDFRuntimePreparing: Sendable {
    /// Return only after preparation subprocesses have stopped, including cancellation.
    func prepare(progress: @escaping @Sendable (PDFRuntimeProgress) -> Void) async throws -> PDFRuntimeReceipt
}
@MainActor public final class PDFRuntimePreparationSession: ObservableObject {
    @Published public private(set) var progress: PDFRuntimeProgress?
    @Published public private(set) var receipt: PDFRuntimeReceipt?
    @Published public private(set) var error: PDFRuntimeError?
    @Published public private(set) var isPreparing = false
    public var isReady: Bool { receipt != nil }
    private let preparer: any PDFRuntimePreparing
    private var worker: Task<Void, Never>?
    private var attempt: UUID?
    public init(preparer: any PDFRuntimePreparing) { self.preparer = preparer }
    public func prepare() {
        guard !isPreparing, !isReady else { return }
        let id = UUID(); attempt = id; error = nil; isPreparing = true; progress = .init(phase: .checking)
        worker = Task { [weak self, preparer] in
            do {
                let result = try await preparer.prepare { [weak self] value in
                    Task { @MainActor [weak self] in guard let self, self.attempt == id, self.isPreparing else { return }; self.progress = value }
                }
                guard let self, self.attempt == id else { return }
                if Task.isCancelled { self.error = .cancelled } else { self.receipt = result }
            } catch {
                guard let self, self.attempt == id else { return }
                self.error = Task.isCancelled ? .cancelled : (error as? PDFRuntimeError ?? .installationFailed)
            }
            guard let self, self.attempt == id else { return }
            self.attempt = nil; self.isPreparing = false; self.worker = nil
        }
    }
    public func cancel() { worker?.cancel() }
    public func awaitShutdown() async { worker?.cancel(); await worker?.value }
}
