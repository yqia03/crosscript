import AppKit
import SwiftUI

@MainActor final class TextEditorActions: ObservableObject {
    weak var editor: NSTextView?
    @Published var canUndo = false
    @Published var canRedo = false
    func undo() { editor?.undoManager?.undo(); refresh() }
    func redo() { editor?.undoManager?.redo(); refresh() }
    func clear() {
        guard let editor else { return }
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); refresh()
    }
    func refresh() {
        let undo = editor?.undoManager?.canUndo ?? false, redo = editor?.undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }; if canRedo != redo { canRedo = redo }
    }
}

/// Owns a native undo context per workspace and side. External result updates
/// preserve selection and the scroll origin; marked text is never overwritten.
@MainActor struct TextWorkspaceEditor: NSViewRepresentable {
    let text: String
    let label: String
    let actions: TextEditorActions
    var monospaced = false
    var isEditable = true
    let changed: (String) -> Bool
    var submit: (() -> Void)? = nil
    var composition: (Bool) -> Void = { _ in }
    var selection: (String) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        let editor = WorkspaceNativeTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 18, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.compositionChanged = { [weak coordinator = context.coordinator] marked in coordinator?.compositionChanged(marked) }
        context.coordinator.editor = editor; actions.editor = editor
        context.coordinator.observeUndoManager(editor.undoManager)
        scroll.documentView = editor; configure(editor)
        DispatchQueue.main.async { actions.refresh() }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }; configure(editor); actions.editor = editor
        guard !context.coordinator.applying, !editor.hasMarkedText(), (editor.string as NSString).compare(text, options: .literal) != .orderedSame else { return }
        let selected = editor.selectedRanges, origin = scroll.contentView.bounds.origin
        context.coordinator.applying = true
        let old = editor.string as NSString, new = text as NSString
        var prefix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, prefix < old.length, (0xDC00...0xDFFF).contains(old.character(at: prefix)) { prefix -= 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) { suffix += 1 }
        if suffix > 0, old.length - suffix > prefix, (0xDC00...0xDFFF).contains(old.character(at: old.length - suffix)) { suffix -= 1 }
        editor.textStorage?.replaceCharacters(in: NSRange(location: prefix, length: old.length - prefix - suffix), with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
        editor.selectedRanges = selected.map { range in
            let value = range.rangeValue, start = min(value.location, new.length)
            return NSValue(range: NSRange(location: start, length: min(value.length, new.length - start)))
        }
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        // A remote replacement must not leave undo commands for an older document.
        editor.undoManager?.removeAllActions(); context.coordinator.accepted = text
        context.coordinator.applying = false
        DispatchQueue.main.async { actions.refresh() }
    }
    private func configure(_ editor: NSTextView) {
        editor.setAccessibilityLabel(label)
        if editor.isEditable != isEditable { editor.isEditable = isEditable }
        if editor.isSelectable != isEditable { editor.isSelectable = isEditable }
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: 16, weight: .regular) : .systemFont(ofSize: 19)
        if editor.font != font { editor.font = font }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextWorkspaceEditor
        weak var editor: NSTextView?
        private weak var observedUndoManager: UndoManager?
        var applying = false
        var accepted: String
        init(_ parent: TextWorkspaceEditor) { self.parent = parent; accepted = parent.text }
        deinit { NotificationCenter.default.removeObserver(self) }
        func observeUndoManager(_ manager: UndoManager?) {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                // NSTextView registers its delegate with NotificationCenter too.
                // Keep those edit/selection observations when replacing ours.
                if let previous = observedUndoManager {
                    NotificationCenter.default.removeObserver(self, name: name, object: previous)
                }
                if let manager {
                    NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoFinished(_:)), name: name, object: manager)
                }
            }
            observedUndoManager = manager
        }
        private var undoOrRedoInProgress: Bool {
            editor?.undoManager?.isUndoing == true || editor?.undoManager?.isRedoing == true
        }
        func compositionChanged(_ marked: Bool) {
            guard !undoOrRedoInProgress else { return }
            parent.composition(marked)
            if !marked { commit() }
        }
        func textDidChange(_ notification: Notification) {
            guard !applying, !undoOrRedoInProgress, let editor else { return }
            parent.composition(editor.hasMarkedText())
            if !editor.hasMarkedText() { commit() }
        }
        @objc private func undoOrRedoFinished(_ notification: Notification) {
            guard let manager = notification.object as? UndoManager, manager === observedUndoManager,
                  let editor, !editor.hasMarkedText() else { return }
            // A group may contain many storage edits without textDidChange.
            // Publish its final text synchronously, before undo/redo returns.
            commit()
            parent.actions.refresh()
        }
        private func commit() {
            guard !applying, let editor, (editor.string as NSString).compare(accepted, options: .literal) != .orderedSame else { return }
            applying = true
            if parent.changed(editor.string) { accepted = editor.string }
            else {
                let selection = editor.selectedRange(); editor.string = accepted
                editor.setSelectedRange(NSRange(location: min(selection.location, (accepted as NSString).length), length: 0))
                editor.undoManager?.removeAllActions()
            }
            applying = false
            DispatchQueue.main.async { [weak self] in self?.parent.actions.refresh() }
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let submit = parent.submit else { return false }
            // AppKit sends IME candidate confirmation through the same command.
            // Keep it in the input method, then require a separate Return to submit.
            guard !textView.hasMarkedText(), (textView as? WorkspaceNativeTextView)?.handlingMarkedKey != true else { return false }
            if (textView as? WorkspaceNativeTextView)?.handlingKeyModifiers.contains(.shift) == true || NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            commit()
            submit()
            return true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let editor, !editor.hasMarkedText() else { return }
            let value = editor.string as NSString, range = editor.selectedRange()
            guard range.location <= value.length, range.length <= value.length - range.location else { return }
            parent.selection(range.length > 0 && range.length <= 256 ? value.substring(with: range) : "")
        }
    }
}

@MainActor private final class WorkspaceNativeTextView: NSTextView {
    private let ownedUndo = UndoManager()
    private(set) var handlingMarkedKey = false
    private(set) var handlingKeyModifiers: NSEvent.ModifierFlags = []
    override func keyDown(with event: NSEvent) {
        handlingMarkedKey = hasMarkedText(); handlingKeyModifiers = event.modifierFlags
        defer { handlingMarkedKey = false; handlingKeyModifiers = [] }
        super.keyDown(with: event)
    }
    var compositionChanged: ((Bool) -> Void)?
    override var undoManager: UndoManager? { ownedUndo }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        compositionChanged?(true)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() { super.unmarkText(); compositionChanged?(false) }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if !hasMarkedText() { compositionChanged?(false) }
    }
}
