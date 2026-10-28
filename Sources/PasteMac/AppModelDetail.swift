import Foundation
import PasteCore

/// State of the detail window (编辑, 翻译, 智能). Presentation lives in AppDelegate.
extension AppModel {
    /// The card the detail window shows, read live so edits and deletions appear at once.
    var panelDetailItem: ClipItem? {
        guard let id = panelDetail?.itemID else { return nil }
        return snapshot.items.first { $0.id == id }
    }

    func openPanelDetail(_ page: PanelDetailPage, itemID: UUID?) {
        // Preview is a window again, not a page of the layer.
        if page == .preview {
            if let item = snapshot.items.first(where: { $0.id == itemID }) { preview(item) }
            return
        }
        panelDetail = PanelDetailState(itemID: itemID, page: page)
    }

    func closePanelDetail() { panelDetail = nil }

    /// The card the preview window shows, read live so edits and deletions appear at once.
    var previewItem: ClipItem? {
        guard let id = previewItemID else { return nil }
        return snapshot.items.first { $0.id == id }
    }

    /// Space: open the preview window for the selected card, or close it again.
    func togglePreview() {
        if previewItemID != nil { closePreview(); return }
        selectFirstIfNeeded()
        if let item = selectedItems.first { preview(item) }
    }

    /// Closes the preview window and releases its payload.
    func closePreview() {
        guard previewItemID != nil else { return }
        previewWindowClosed()
        onPreviewClose?()
    }

    /// The window closed by its own button, Esc or the title bar.
    func previewWindowClosed() {
        previewItemID = nil
        releaseHistory(for: "preview")
    }

    /// ← and → in the preview window: show the previous or next card of the list.
    /// The selection follows, so the panel shows the same card when it returns.
    func movePreview(_ delta: Int) {
        let items = visibleItems
        guard let id = previewItemID, let index = items.firstIndex(where: { $0.id == id }) else {
            // A card outside the list, such as a suggestion's source, starts from the selection.
            if previewItemID != nil { moveSelection(delta) }
            return
        }
        let next = index + delta
        guard items.indices.contains(next) else { return }
        select(items[next])
        if previewItemID != items[next].id { preview(items[next]) }
    }

    /// The preview window's 编辑, 翻译 and 智能 buttons: close it and open the page in the panel.
    func openFromPreview(_ page: PanelDetailPage, item: ClipItem) {
        guard page != .preview, page.isAvailable(for: item) else { return }
        closePreview()
        if visibleItems.contains(where: { $0.id == item.id }) { select(item) }
        showDetailPage(page, for: item)
    }

    /// Opens a page for the selected card when the page applies to it.
    func openPanelDetailForSelection(_ page: PanelDetailPage) {
        selectFirstIfNeeded()
        guard let item = selectedItems.first else { return }
        showDetailPage(page, for: item)
    }

    /// The page bar and shortcuts run the same actions as the context menu.
    func showDetailPage(_ page: PanelDetailPage, for item: ClipItem) {
        guard page.isAvailable(for: item) else { return }
        switch page {
        case .preview: preview(item)
        case .edit: edit(item)
        case .translate:
            // A card that already has a translation shows it without sending the text again.
            hostToolsInPanel {
                if item.enrichment?.translation != nil { showToolItem(item) }
                else if item.kind == .image { recognizeItem(item, translateAfter: true) }
                else { translateItem(item) }
            }
        case .intelligence: intelligence(item)
        // ⌘J: the preview window carries the suggestions; it keeps a multi-selection for its summary.
        case .suggestions: if previewItemID == nil { preview(item) }
        }
    }

    /// ← and → in the panel move the selection; an open preview window follows the selected card.
    func syncPreviewToSelection() {
        guard let current = previewItemID, selectedIDs.count == 1, let id = selectedIDs.first, id != current,
              let item = snapshot.items.first(where: { $0.id == id }) else { return }
        preview(item)
    }

    /// The panel hid, for example after an outside click or a paste.
    /// An editor with unsaved changes stays open, so reopening the panel returns to it.
    func panelDidHide() {
        // Detail pages are windows of their own and stay open while the panel hides.
    }

    // MARK: Editor page

    /// Opens the editor page, resuming an unsaved draft for the same card.
    func openPanelEditor(_ item: ClipItem?) {
        if panelEditorDrafts[item?.id] == nil { panelEditorDrafts[item?.id] = PanelEditorDraft(item: item) }
        openPanelDetail(.edit, itemID: item?.id)
    }

    var panelEditorDraft: PanelEditorDraft? {
        guard let detail = panelDetail, detail.page == .edit else { return nil }
        return panelEditorDrafts[detail.itemID]
    }

    func updatePanelEditorDraft(value: NSAttributedString, title: String) {
        guard let detail = panelDetail, detail.page == .edit, var draft = panelEditorDrafts[detail.itemID] else { return }
        draft.value = value; draft.title = title
        panelEditorDrafts[detail.itemID] = draft
    }

    /// ⌘S and the Save button. Saving is unchanged: the same rich text save as the editor window.
    @discardableResult
    func savePanelEditor() -> Bool {
        guard let detail = panelDetail, detail.page == .edit, let draft = panelEditorDrafts[detail.itemID],
              !draft.value.string.isEmpty else { return false }
        guard saveRichText(draft.value, title: draft.title, item: draft.item) else { return false }
        panelEditorDrafts[detail.itemID] = nil
        closePanelDetail()
        return true
    }

    /// Cancel throws the draft away.
    func cancelPanelEditor() {
        guard let detail = panelDetail, detail.page == .edit else { return }
        panelEditorDrafts[detail.itemID] = nil
        closePanelDetail()
    }

    // MARK: Translate page

    /// Runs a tool action started from the panel so its result shows on the translate page.
    func hostToolsInPanel(_ body: () -> Void) {
        toolsHostedInPanel = true
        defer { toolsHostedInPanel = false }
        body()
    }

    /// Ends a translation hosted in the panel, as closing the tool window did.
    func endPanelTool() {
        toolsHostedInPanel = false
        guard toolSessionActive else { return }
        toolSessionActive = false
        cancelToolOperation()
    }

    func panelDetailChanged(from old: PanelDetailState?) {
        if panelDetail?.itemID != old?.itemID {
            // Keep the full payload loaded while the layer shows it, like the old windows did.
            if let id = panelDetail?.itemID { retainHistory([id], for: "detail") }
            else { releaseHistory(for: "detail") }
        }
        if old?.page == .translate && panelDetail?.page != .translate { endPanelTool() }
        // An unchanged draft is not worth keeping once the editor closes.
        if let old, old.page == .edit, panelDetail != old, panelEditorDrafts[old.itemID]?.isDirty != true {
            panelEditorDrafts[old.itemID] = nil
        }
        onPanelDetailChange?()
    }
}
