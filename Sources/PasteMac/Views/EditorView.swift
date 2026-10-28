import AppKit
import SwiftUI
import PasteCore

/// The detail layer's edit page. Text lives in a draft on the model, so it survives
/// Esc, page switches and the panel hiding until it is saved or cancelled.
/// ⌘S saves (routed by AppDelegate); Return inserts a newline.
struct EditorView: View {
    @ObservedObject var model: AppModel
    let itemID: UUID?
    @State private var value: NSAttributedString
    @State private var title: String
    @StateObject private var editor = RichTextEditorController()
    private let draft: PanelEditorDraft

    init(model: AppModel, itemID: UUID?) {
        self.model = model; self.itemID = itemID
        let draft = model.panelEditorDrafts[itemID] ?? PanelEditorDraft(item: nil)
        self.draft = draft
        _value = State(initialValue: draft.value)
        _title = State(initialValue: draft.title)
    }

    private var item: ClipItem? { draft.item }
    private var dirty: Bool { !value.isEqual(to: draft.originalValue) || title != draft.originalTitle }

    var body: some View {
        PanelDetailScaffold(model: model, item: item.flatMap { value in model.snapshot.items.first { $0.id == value.id } },
                            page: .edit, title: item == nil ? "新建文本" : "编辑文本", subtitle: item?.sourceName) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                TextField("标题（可选）", text: $title).textFieldStyle(PasteboardTextFieldStyle())
                VStack(spacing: 0) {
                    formatBar
                    Divider().opacity(0.6)
                    RichTextEditor(value: $value, controller: editor)
                        .padding(DesignTokens.Space.xs)
                        .frame(maxHeight: .infinity)
                        .background(InputFocusOnAppear {
                            guard let view = editor.textView else { return }
                            view.window?.makeFirstResponder(view)
                        }.frame(width: 0, height: 0))
                }
                .modifier(PasteboardInputSurface(focused: editor.focused, cornerRadius: DesignTokens.Radius.md))
            }
        } footer: {
            WindowFooterNote("\(value.string.count) 个字符")
            if dirty {
                Text("未保存").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                    .accessibilityLabel("有未保存的修改")
            }
            Spacer()
            Text("⌘S 保存 · ↩ 换行 · Esc 收起").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            Button("取消") { model.cancelPanelEditor() }
            Button("保存") { model.savePanelEditor() }
                .buttonStyle(.borderedProminent).tint(PanelPalette.accent).foregroundStyle(PanelPalette.onAccent)
                .disabled(value.string.isEmpty)
                .help("保存 (⌘S)")
        }
        .onChange(of: value) { _, next in model.updatePanelEditorDraft(value: next, title: title) }
        .onChange(of: title) { _, next in model.updatePanelEditorDraft(value: value, title: next) }
    }

    private var formatBar: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            FormatButton(symbol: "bold", label: "粗体") { editor.toggleFontTrait(.boldFontMask) }
            FormatButton(symbol: "italic", label: "斜体") { editor.toggleFontTrait(.italicFontMask) }
            FormatButton(symbol: "underline", label: "下划线") { editor.toggleUnderline() }
            Spacer()
            Text("富文本").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
        }
        .padding(.horizontal, DesignTokens.Space.sm)
        .frame(height: 32)
    }
}

private struct FormatButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(.label, weight: .medium)).frame(width: 26, height: 24)
        }
        .buttonStyle(PanelControlStyle())
        .help(label).accessibilityLabel(label)
    }
}

@MainActor final class RichTextEditorController: ObservableObject {
    @Published var focused = false
    weak var textView: NSTextView?

    func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let view = textView else { return }
        let manager = NSFontManager.shared
        let range = view.selectedRange()
        let font = (range.length == 0 ? view.typingAttributes[.font] : view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil)) as? NSFont ?? NSFont.systemFont(ofSize: 15)
        let remove = manager.traits(of: font).contains(trait)
        if range.length == 0 {
            var attributes = view.typingAttributes
            attributes[.font] = remove ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            view.typingAttributes = attributes
        } else if view.shouldChangeText(in: range, replacementString: nil), let storage = view.textStorage {
            let existing = NSAttributedString(attributedString: storage)
            storage.beginEditing()
            existing.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = value as? NSFont ?? NSFont.systemFont(ofSize: 15)
                let updated = remove ? manager.convert(current, toNotHaveTrait: trait) : manager.convert(current, toHaveTrait: trait)
                storage.addAttribute(.font, value: updated, range: subrange)
            }
            storage.endEditing()
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }

    func toggleUnderline() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let current = (range.length == 0 ? view.typingAttributes[.underlineStyle] : view.textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil)) as? Int ?? 0
        let updated = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        if range.length == 0 {
            var attributes = view.typingAttributes
            attributes[.underlineStyle] = updated
            view.typingAttributes = attributes
        } else if view.shouldChangeText(in: range, replacementString: nil) {
            view.textStorage?.addAttribute(.underlineStyle, value: updated, range: range)
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var value: NSAttributedString
    let controller: RichTextEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = FocusTrackingTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        view.onFocusChange = { [weak controller] in controller?.focused = $0 }
        scroll.documentView = view
        view.isRichText = true
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.drawsBackground = false
        view.textStorage?.setAttributedString(value)
        view.delegate = context.coordinator
        controller.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.textView = view
        if !view.attributedString().isEqual(to: value) {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(value)
            view.setSelectedRange(NSRange(location: min(selection.location, value.length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.value = NSAttributedString(attributedString: view.attributedString())
        }
    }
}

/// NSTextView editing notifications begin on the first edit, so track responder
/// transitions to show the focus border before the user starts typing.
private final class FocusTrackingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
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
}
