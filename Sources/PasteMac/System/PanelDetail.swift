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
struct PanelDetailState: Equatable, Sendable {
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
