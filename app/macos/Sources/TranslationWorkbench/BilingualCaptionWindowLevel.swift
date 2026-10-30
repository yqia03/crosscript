import AppKit
import SwiftUI
import WorkbenchCore

/// NSWindow.Level is available at the project's macOS 14.2 deployment target.
/// The caption scene shares state with the main window and owns no capture.
struct BilingualCaptionWindowLevel: NSViewRepresentable {
    @AppStorage("interfaceLanguage") private var languageChoice = "system"
    private var title: String { AppLanguage(preference: languageChoice).text("置顶字幕", "Captions") }

    final class FloatingView: NSView {
        var captionTitle = "" {
            didSet { if captionTitle != oldValue { window?.title = captionTitle } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = .floating
            window?.collectionBehavior.insert(.fullScreenAuxiliary)
            window?.title = captionTitle
        }
    }
    func makeNSView(context: Context) -> FloatingView {
        let view = FloatingView()
        view.captionTitle = title
        return view
    }
    func updateNSView(_ nsView: FloatingView, context: Context) {
        nsView.captionTitle = title
    }
}
