import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFRuntimePreparationTests {
    @Test func preparesOnceReportsActualProgressAndReusesReadyReceipt() async throws {
        let service = RuntimeControl(), session = PDFRuntimePreparationSession(preparer: RuntimeAdapter(control: service))
        session.prepare(); session.prepare()
        try await wait { await service.calls == 1 }
        await service.report(.init(phase: .downloading, completedBytes: 14, totalBytes: 100, completedFiles: 1, totalFiles: 2))
        try await wait { session.progress?.completedBytes == 14 }
        #expect(!session.isReady)
        await service.finish(.success(.init(identifier: "locked", reused: false)))
        try await wait { session.isReady }
        #expect(!session.isPreparing)
        session.prepare()
        #expect(await service.calls == 1)
    }
    @Test func failureAllowsRetryAndStaleProgressCannotOverwriteNextAttempt() async throws {
        let service = RuntimeControl(), session = PDFRuntimePreparationSession(preparer: RuntimeAdapter(control: service))
        session.prepare(); try await wait { await service.calls == 1 }
        await service.finish(.failure(.integrityMismatch("model")))
        try await wait { !session.isPreparing }
        #expect(session.error == .integrityMismatch("model")); #expect(!session.isReady)
        session.prepare(); try await wait { await service.calls == 2 }
        await service.reportOld(.init(phase: .downloading, completedBytes: 999))
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.progress?.completedBytes != 999)
        await service.finish(.success(.init(identifier: "locked", reused: true)))
        try await wait { session.isReady }
        #expect(session.receipt?.reused == true)
    }
    @Test func cancelledPreparationKeepsBusyUntilWorkerStopsAndRejectsLateSuccess() async throws {
        let service = RuntimeControl(), session = PDFRuntimePreparationSession(preparer: RuntimeAdapter(control: service))
        session.prepare(); try await wait { await service.calls == 1 }
        session.cancel(); session.prepare()
        #expect(session.isPreparing); #expect(await service.calls == 1)
        var shutdownReturned = false
        let shutdown = Task { await session.awaitShutdown(); shutdownReturned = true }
        try await Task.sleep(for: .milliseconds(10)); #expect(!shutdownReturned)
        await service.finish(.success(.init(identifier: "late", reused: false)))
        await shutdown.value
        #expect(!session.isReady); #expect(session.error == .cancelled); #expect(!session.isPreparing)
    }
    private func wait(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("runtime condition timed out")
    }
}
private struct RuntimeAdapter: PDFRuntimePreparing {
    let control: RuntimeControl
    func prepare(progress: @escaping @Sendable (PDFRuntimeProgress) -> Void) async throws -> PDFRuntimeReceipt { try await control.run(progress) }
}
private actor RuntimeControl {
    var calls = 0
    var current: (@Sendable (PDFRuntimeProgress) -> Void)?
    var old: (@Sendable (PDFRuntimeProgress) -> Void)?
    var continuation: CheckedContinuation<PDFRuntimeReceipt, Error>?
    func run(_ progress: @escaping @Sendable (PDFRuntimeProgress) -> Void) async throws -> PDFRuntimeReceipt {
        calls += 1; old = current; current = progress
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func report(_ value: PDFRuntimeProgress) { current?(value) }
    func reportOld(_ value: PDFRuntimeProgress) { old?(value) }
    func finish(_ result: Result<PDFRuntimeReceipt, PDFRuntimeError>) { continuation?.resume(with: result.mapError { $0 as Error }); continuation = nil }
}
