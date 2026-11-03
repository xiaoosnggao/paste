#if DEBUG
import AppKit
import PasteCore

/// Pure checks for the in-panel detail layer: height, Esc layering and shortcuts.
enum PanelDetailChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Panel detail: \(message)") }
            count += 1
        }
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let base = PanelPresentation.visibleFrame(on: screen)
        let suggestions = PanelPresentation.visibleFrame(on: screen, suggestionsVisible: true, additionalHeight: 40)
        let content = PanelDetailLayout.contentHeight(forScreenHeight: screen.height)
        let detail = PanelPresentation.visibleFrame(on: screen, suggestionsVisible: true, additionalHeight: 40, detailContentHeight: content)
        try check(content == PanelDetailLayout.contentHeight, "a normal screen shrank the detail card")
        try check(detail.height == base.height + content + PanelDetailLayout.spacing,
                  "detail height added the suggestions bar instead of replacing it")
        try check(detail.height != suggestions.height + content, "detail and suggestions heights were stacked")
        try check(detail.minY == base.minY && detail.minX == base.minX && detail.width == base.width,
                  "opening detail moved the deck's bottom edge or width")
        try check(detail.maxY <= screen.maxY - 8, "detail panel left the screen")

        let short = NSRect(x: 0, y: 0, width: 1280, height: 600)
        let shortContent = PanelDetailLayout.contentHeight(forScreenHeight: short.height)
        let shortFrame = PanelPresentation.visibleFrame(on: short, detailContentHeight: shortContent)
        try check(shortContent < PanelDetailLayout.contentHeight && shortContent >= PanelDetailLayout.minimumContentHeight,
                  "short screen did not shrink the detail card within bounds")
        try check(shortFrame.maxY <= short.maxY - 8, "short screen detail panel left the screen")
        let tiny = NSRect(x: 0, y: 0, width: 1024, height: 420)
        let tinyFrame = PanelPresentation.visibleFrame(on: tiny, detailContentHeight: PanelDetailLayout.contentHeight(forScreenHeight: tiny.height))
        try check(tinyFrame.height <= tiny.height - 16, "tiny screen detail panel was not clamped")

        typealias E = PanelEscapeAction
        try check(E.resolve(detailOpen: true, textEditing: true, fieldEditor: false, composing: true) == .passToText,
                  "Esc cancelled an input method composition")
        try check(E.resolve(detailOpen: false, textEditing: true, fieldEditor: true, composing: true) == .passToText,
                  "Esc in a composing search field reached the panel")
        try check(E.resolve(detailOpen: true, textEditing: true, fieldEditor: true, composing: false) == .passToText,
                  "Esc in the search or rename field changed behavior")
        try check(E.resolve(detailOpen: true, textEditing: true, fieldEditor: false, composing: false) == .endTextEditing,
                  "first Esc in a text view skipped ending editing")
        try check(E.resolve(detailOpen: true, textEditing: false, fieldEditor: false, composing: false) == .closeDetail,
                  "Esc with detail open hid the whole panel")
        try check(E.resolve(detailOpen: false, textEditing: false, fieldEditor: false, composing: false) == .hidePanel,
                  "Esc without detail stopped hiding the panel")

        try check(PanelDetailPage.forCommandKey("e") == .edit && PanelDetailPage.forCommandKey("t") == .translate
                  && PanelDetailPage.forCommandKey("i") == .intelligence, "page shortcuts changed")
        for key in ["c", "a", "z", "n", "o", "f", ","] {
            try check(PanelDetailPage.forCommandKey(key) == nil, "page shortcut took over ⌘\(key)")
        }
        try check(Set(PanelDetailPage.allCases.map(\.shortcutLabel)).count == PanelDetailPage.allCases.count,
                  "two pages share a shortcut label")

        let image = ClipItem(text: "", kind: .image)
        let file = ClipItem(text: "/tmp/a.txt", kind: .file)
        let text = ClipItem(text: "hello", kind: .text)
        let empty = ClipItem(text: "", kind: .text)
        try check(!PanelDetailPage.edit.isAvailable(for: image) && !PanelDetailPage.edit.isAvailable(for: file)
                  && PanelDetailPage.edit.isAvailable(for: text), "edit availability differs from the context menu")
        try check(PanelDetailPage.translate.isAvailable(for: image) && PanelDetailPage.translate.isAvailable(for: text)
                  && !PanelDetailPage.translate.isAvailable(for: empty), "translate availability differs from the context menu")
        try check(PanelDetailPage.intelligence.isAvailable(for: text) && !PanelDetailPage.intelligence.isAvailable(for: image),
                  "smart page availability differs from the preview button")
        try check([image, file, text, empty].allSatisfy { PanelDetailPage.preview.isAvailable(for: $0) }, "preview was unavailable for a card")

        typealias K = PanelDetailKey
        func key(_ page: PanelDetailPage, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String? = nil,
                 editing: Bool = false, composing: Bool = false, field: Bool = false) -> K? {
            K.resolve(page: page, keyCode: code, flags: flags, key: chars, textEditing: editing, composing: composing, fieldEditor: field)
        }
        try check(key(.edit, 1, .command, "s", editing: true) == .save, "⌘S did not save from the editor")
        try check(key(.edit, 1, .command, "s", editing: true, field: true) == .save, "⌘S did not save from the title field")
        try check(key(.edit, 1, .command, "s", editing: true, composing: true) == nil, "⌘S interrupted an input method")
        try check(key(.edit, 36, editing: true) == nil, "Return in the editor did not insert a newline")
        try check(key(.edit, 36, .shift, editing: true) == nil, "⇧Return in the editor was taken")
        try check(key(.edit, 36) == .ignore, "Return outside the editor pasted a card while editing")
        try check(key(.preview, 1, .command, "s") == nil && key(.translate, 1, .command, "s") == nil, "⌘S was taken outside the edit page")
        try check(key(.translate, 36, editing: true) == .translate, "Return in the translate page did not translate")
        try check(key(.translate, 36, .shift, editing: true) == nil, "⇧Return in the translate page was not a newline")
        try check(key(.translate, 36, editing: true, composing: true) == nil, "Return confirmed a composition and translated")
        try check(key(.translate, 36, editing: true, field: true) == nil, "Return in the search field translated")
        try check(key(.translate, 15, .command, "r") == .retry, "⌘R did not retry on the translate page")
        try check(key(.preview, 36) == nil && key(.intelligence, 36) == nil, "Return changed on the preview or smart page")
        return count
    }
}
#endif
