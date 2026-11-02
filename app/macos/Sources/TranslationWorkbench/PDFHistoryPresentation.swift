import SwiftUI

/// Keep workspace commands suspended until the sheet has actually finished
/// dismissing. A page exit invalidates pending intentions and cannot reactivate
/// them through a late sheet callback.
@MainActor final class PDFHistoryPresentation: ObservableObject {
    private enum Phase { case inactive, workspace, history, dismissing }
    @Published private var phase: Phase = .inactive
    let commands = MenuCommandBarrier()
    var isPresented: Bool { phase == .history }
    var canPerformWorkspaceCommands: Bool { phase == .workspace }

    func activateWorkspace() {
        guard phase == .inactive else { return }
        phase = .workspace; commands.activate()
    }
    func deactivateWorkspace() { phase = .inactive; commands.deactivate() }
    func present() {
        guard phase == .workspace else { return }
        commands.deactivate(); phase = .history
    }
    func dismiss() {
        guard phase == .history else { return }
        phase = .dismissing
    }
    func didDismiss() {
        guard phase == .history || phase == .dismissing else { return }
        phase = .workspace; commands.activate()
    }
}
