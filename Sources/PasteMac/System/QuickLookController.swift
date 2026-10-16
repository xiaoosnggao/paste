import AppKit
import QuickLookUI

@MainActor
final class QuickLookController: NSResponder, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var urls: [URL] = []
    private weak var hostWindow: NSWindow?
    private var previousResponder: NSResponder?
    static func existingFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.prefix(1024).filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) && seen.insert($0).inserted }
    }
    @discardableResult
    func show(urls requested: [URL]) -> Bool {
        let valid = Self.existingFiles(requested)
        guard !valid.isEmpty, let window = NSApp.keyWindow, let panel = QLPreviewPanel.shared() else { return false }
        detach()
        urls = valid; hostWindow = window
        previousResponder = window.nextResponder
        nextResponder = previousResponder
        window.nextResponder = self
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; detach() }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
    private func detach() {
        if hostWindow?.nextResponder === self { hostWindow?.nextResponder = previousResponder }
        hostWindow = nil; previousResponder = nil; nextResponder = nil
    }
}
