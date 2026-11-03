import AppKit
import SwiftUI

/// Shared contrast and focus treatment for every editable surface.
struct PasteboardInputSurface: ViewModifier {
    let focused: Bool
    var cornerRadius: CGFloat = DesignTokens.Radius.sm

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

struct PasteboardTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .modifier(PasteboardInputSurface(focused: focused))
    }
}

/// Native fields explicitly acquire the panel's key window before its field editor.
/// SwiftUI FocusState alone cannot reliably do this inside a nonactivating panel.
struct PanelInputField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusableTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
        field.requestedFocus = focused
    }

    final class FocusableTextField: NSTextField {
        var requestedFocus = false {
            didSet { if requestedFocus != oldValue { requestFocusIfNeeded() } }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocusIfNeeded()
        }
        private func requestFocusIfNeeded() {
            guard requestedFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestedFocus, let window = self.window else { return }
                window.makeKey()
                if self.currentEditor() == nil { window.makeFirstResponder(self) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelInputField
        init(_ parent: PanelInputField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}

/// Wait until attachment before focusing newly presented SwiftUI editors.
struct InputFocusOnAppear: NSViewRepresentable {
    let onReady: () -> Void
    func makeNSView(context: Context) -> FocusView { FocusView(onReady: onReady) }
    func updateNSView(_ view: FocusView, context: Context) {}

    final class FocusView: NSView {
        private let onReady: () -> Void
        private var didFocus = false
        init(onReady: @escaping () -> Void) { self.onReady = onReady; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFocus, window != nil else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                self.onReady()
            }
        }
    }
}
