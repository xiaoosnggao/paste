import AppKit
import PasteCore

/// A page of the detail layer that opens above the card deck.
///
/// Preview, editing, translation and smart processing used to open separate
/// windows. They now share one layer inside the clipboard panel.
enum PanelDetailPage: String, CaseIterable, Identifiable, Sendable {
    case preview, edit, translate, intelligence

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: "预览"
        case .edit: "编辑"
        case .translate: "翻译"
        case .intelligence: "智能"
        }
    }
    var systemImage: String {
        switch self {
        case .preview: "eye"
        case .edit: "pencil"
        case .translate: "character.bubble"
        case .intelligence: "sparkles"
        }
    }
    /// The shortcut shown next to the page name.
    var shortcutLabel: String {
        switch self {
        case .preview: "空格"
        case .edit: "⌘E"
        case .translate: "⌘T"
        case .intelligence: "⌘I"
        }
    }
    /// The page a plain ⌘ letter opens while no text field has focus.
    /// ⌘I and ⌘T stay italic and fonts inside text views; callers check that.
    static func forCommandKey(_ key: String) -> PanelDetailPage? {
        switch key {
        case "e": .edit
        case "t": .translate
        case "i": .intelligence
        default: nil
        }
    }

    /// Whether the page applies to a card. The rules match the context menu.
    func isAvailable(for item: ClipItem) -> Bool {
        switch self {
        case .preview: true
        case .edit: item.kind != .image && item.kind != .file
        case .translate: item.kind == .image || !item.text.isEmpty
        case .intelligence: item.kind == .text || item.kind == .link
        }
    }
}

/// What the detail layer shows. A nil item is a new text in the editor.
struct PanelDetailState: Hashable, Sendable {
    var itemID: UUID?
    var page: PanelDetailPage
}

/// Sizes of the detail layer.
enum PanelDetailLayout {
    /// The detail card's height on a normal screen.
    static let contentHeight: CGFloat = 340
    /// Gap between the detail card and the toolbar.
    static let spacing: CGFloat = 12
    /// The smallest useful card; shorter screens clip the panel instead.
    static let minimumContentHeight: CGFloat = 200
    /// Wide monitors keep the card readable instead of stretching text lines.
    static let maxContentWidth: CGFloat = 1040
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 48

    /// The card height that keeps the whole panel on a screen of this height.
    static func contentHeight(forScreenHeight height: CGFloat) -> CGFloat {
        let available = height - 16 - PanelPresentation.baseHeight - spacing
        return max(minimumContentHeight, min(contentHeight, available.rounded(.down)))
    }
}

/// Which layer Esc closes, innermost first.
enum PanelEscapeAction: Equatable {
    /// An input method is composing, or a one-line field handles Esc itself.
    case passToText
    /// Leave a multi-line text view. Its text stays as typed.
    case endTextEditing
    case closeDetail
    case hidePanel

    static func resolve(detailOpen: Bool, textEditing: Bool, fieldEditor: Bool, composing: Bool) -> PanelEscapeAction {
        if composing { return .passToText }
        if textEditing { return fieldEditor ? .passToText : .endTextEditing }
        return detailOpen ? .closeDetail : .hidePanel
    }
}

/// The editor page's text, kept until it is saved or cancelled.
struct PanelEditorDraft {
    /// The card as loaded when editing began; saving checks it was not deleted meanwhile.
    let item: ClipItem?
    var value: NSAttributedString
    var title: String
    let originalValue: NSAttributedString
    let originalTitle: String

    init(item: ClipItem?) {
        self.item = item
        let rich = item?.representations.first(where: { $0.type == "public.rtf" }).flatMap {
            try? NSAttributedString(data: $0.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        let value = rich ?? NSAttributedString(string: item?.text ?? "", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        self.value = value
        self.originalValue = value
        let title = item?.title ?? ""
        self.title = title
        self.originalTitle = title
    }

    var isDirty: Bool { !value.isEqual(to: originalValue) || title != originalTitle }
}

/// Keys a detail page handles before the panel's own shortcuts.
/// - Edit: ⌘S saves; Return stays a newline in the editor and does nothing outside it,
///   so it never pastes another card while a draft is open.
/// - Translate: Return translates (⇧Return is a newline) and ⌘R retries, as in the tool window.
/// Nothing is handled while an input method is composing.
enum PanelDetailKey: Equatable {
    case save, translate, retry, ignore

    static func resolve(page: PanelDetailPage, keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String?,
                        textEditing: Bool, composing: Bool, fieldEditor: Bool) -> PanelDetailKey? {
        guard !composing else { return nil }
        let returnKey = keyCode == 36 || keyCode == 76
        switch page {
        case .edit:
            if flags == .command, key == "s" { return .save }
            // Outside any text view (after Esc), Return must not paste the selected card.
            if returnKey, !textEditing { return .ignore }
            return nil
        case .translate:
            if flags == .command, key == "r" { return .retry }
            if returnKey, flags.isEmpty, !fieldEditor { return .translate }
            return nil
        case .preview, .intelligence:
            return nil
        }
    }
}
