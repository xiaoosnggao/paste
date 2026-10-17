import AppKit
import SwiftUI
import PasteCore

struct EditorView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem?
    @State private var value: NSAttributedString
    @State private var title: String
    @StateObject private var editor = RichTextEditorController()

    init(model: AppModel, item: ClipItem?) {
        self.model = model; self.item = item
        let richValue = item?.representations.first(where: { $0.type == "public.rtf" }).flatMap {
            try? NSAttributedString(data: $0.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        _value = State(initialValue: richValue ?? NSAttributedString(string: item?.text ?? "", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]))
        _title = State(initialValue: item?.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item == nil ? "新建文本" : "编辑文本").font(.title2.bold())
            TextField("标题（可选）", text: $title).textFieldStyle(PasteboardTextFieldStyle())
            HStack(spacing: 6) {
                Button { editor.toggleFontTrait(.boldFontMask) } label: { Image(systemName: "bold").frame(width: 23) }.help("粗体")
                Button { editor.toggleFontTrait(.italicFontMask) } label: { Image(systemName: "italic").frame(width: 23) }.help("斜体")
                Button { editor.toggleUnderline() } label: { Image(systemName: "underline").frame(width: 23) }.help("下划线")
                Spacer()
                Text("富文本").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.borderless)
            RichTextEditor(value: $value, controller: editor)
                .padding(8).modifier(PasteboardInputSurface(focused: editor.focused, cornerRadius: 10))
                .background(InputFocusOnAppear {
                    guard let view = editor.textView else { return }
                    view.window?.makeFirstResponder(view)
                }.frame(width: 0, height: 0))
            HStack {
                Text("\(value.string.count) 个字符").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.closeEditor() }.keyboardShortcut(.cancelAction)
                Button("保存") { if model.saveRichText(value, title: title, item: item) { model.closeEditor() } }
                    .keyboardShortcut(.defaultAction).disabled(value.string.isEmpty)
            }
        }.padding(24).frame(minWidth: 520, minHeight: 380)
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
