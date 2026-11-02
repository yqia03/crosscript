import SwiftUI

/// The active PDF workspace supplies its retained command. Other pages keep the
/// application's existing recording-project action.
@MainActor struct NewProjectCommand {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct NewProjectCommandKey: FocusedValueKey {
    typealias Value = NewProjectCommand
}

extension FocusedValues {
    var newProjectCommand: NewProjectCommand? {
        get { self[NewProjectCommandKey.self] }
        set { self[NewProjectCommandKey.self] = newValue }
    }
}
