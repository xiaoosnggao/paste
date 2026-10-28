import Foundation
import PasteCore

/// State of the in-panel detail layer. Presentation lives in AppDelegate.
extension AppModel {
    /// The card the detail layer shows, read live so edits and deletions appear at once.
    var panelDetailItem: ClipItem? {
        guard let id = panelDetail?.itemID else { return nil }
        return snapshot.items.first { $0.id == id }
    }

    func openPanelDetail(_ page: PanelDetailPage, itemID: UUID?) {
        panelDetail = PanelDetailState(itemID: itemID, page: page)
    }

    func closePanelDetail() { panelDetail = nil }

    /// Space: open the preview of the selected card, or close it again.
    func togglePreviewDetail() {
        if panelDetail?.page == .preview { closePanelDetail(); return }
        selectFirstIfNeeded()
        if let item = selectedItems.first { preview(item) }
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
            if item.kind == .image { recognizeItem(item, translateAfter: true) } else { translateItem(item) }
        case .intelligence: intelligence(item)
        }
    }

    /// ← and → move the selection; the preview follows the selected card.
    func syncPanelDetailToSelection() {
        guard let detail = panelDetail, detail.page == .preview, selectedIDs.count == 1,
              let id = selectedIDs.first, id != detail.itemID else { return }
        panelDetail?.itemID = id
    }

    /// The panel hid, for example after an outside click or a paste.
    func panelDidHide() {
        closePanelDetail()
    }

    func panelDetailChanged(from old: PanelDetailState?) {
        if panelDetail?.itemID != old?.itemID {
            // Keep the full payload loaded while the layer shows it, like the old windows did.
            if let id = panelDetail?.itemID { retainHistory([id], for: "detail") }
            else { releaseHistory(for: "detail") }
        }
        // Opening the layer hides the suggestions bar; closing it brings the bar back.
        if (panelDetail == nil) != (old == nil) { scheduleContextSuggestions() }
        onPanelDetailChange?()
    }
}
