import AppKit
import SwiftUI

/// Reports user edits together with IME composition state; model-driven updates stay silent.
struct ToolSourceEditor: NSViewRepresentable {
    let text: String
    let focused: FocusState<Bool>.Binding
    let label: String
    let onEdit: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = SourceTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        editor.delegate = context.coordinator
        editor.onCompositionChange = { [weak coordinator = context.coordinator] editor in
            coordinator?.reportEdit(editor)
        }
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.focused.wrappedValue = focused
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SourceTextView else { return }
        editor.setAccessibilityLabel(label)
        if editor.string != text {
            context.coordinator.updating = true
            // User edits synchronously update the model. A mismatch therefore belongs to a
            // new card/context; discard the old IME session before replacing its source.
            if editor.hasMarkedText() { editor.unmarkText() }
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            context.coordinator.updating = false
        }
        editor.requestedFocus = focused.wrappedValue
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ToolSourceEditor
        var updating = false
        init(_ parent: ToolSourceEditor) { self.parent = parent }

        func reportEdit(_ editor: NSTextView) {
            guard !updating else { return }
            parent.onEdit(editor.string, editor.hasMarkedText())
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            reportEdit(editor)
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused.wrappedValue = false }
    }

    final class SourceTextView: NSTextView {
        var onCompositionChange: ((NSTextView) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var requestedFocus = false {
            didSet { if requestedFocus != oldValue { requestFocusIfNeeded() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocusIfNeeded()
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocusChange?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { onFocusChange?(false) }
            return accepted
        }
        private func requestFocusIfNeeded() {
            guard requestedFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestedFocus, let window = self.window else { return }
                window.makeKey()
                if window.firstResponder !== self { window.makeFirstResponder(self) }
            }
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            onCompositionChange?(self)
        }
        override func unmarkText() {
            super.unmarkText()
            // Committing a candidate can leave the string unchanged, so textDidChange is insufficient.
            onCompositionChange?(self)
        }
        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            super.insertText(insertString, replacementRange: replacementRange)
            onCompositionChange?(self)
        }
    }
}

#if DEBUG
extension ToolSourceEditor {
    @MainActor
    static func runEditorChecks() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Source editor: " + message) }
            count += 1
        }
        let editor = SourceTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        var edits: [(String, Bool)] = []
        editor.onCompositionChange = { edits.append(($0.string, $0.hasMarkedText())) }
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(edits.last?.0 == "中文" && edits.last?.1 == true, "marked text was reported as committed")
        let beforeCommit = edits.count
        editor.unmarkText()
        try check(edits.count > beforeCommit && edits.last?.0 == "中文" && edits.last?.1 == false,
                  "unchanged composition commit was not reported")
        editor.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 2))
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(edits.last?.0 == "你好" && edits.last?.1 == false, "insertText commit remained composing")
        let beforeAssignment = edits.count
        editor.string = "Programmatic OCR result"
        try check(edits.count == beforeAssignment, "programmatic text assignment emitted a user edit")
        return count
    }
}
#endif
