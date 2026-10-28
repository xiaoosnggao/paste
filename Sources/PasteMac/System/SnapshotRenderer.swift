#if DEBUG
import AppKit
import SwiftUI
import PasteCore

/// `--render-snapshots <dir>`: renders the main surfaces with demo data at real sizes,
/// light and dark, so layout can be reviewed without a Mac screen.
@MainActor
enum SnapshotRenderer {
    static func run(into directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var count = 0
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            func render<V: View>(_ name: String, _ size: NSSize, radius: CGFloat = DesignTokens.Radius.window, _ view: V) async throws {
                try await snapshot(view, size: size, radius: radius, appearance: appearance,
                                   to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                count += 1
            }
            for screen in [NSSize(width: 1280, height: 720), NSSize(width: 1440, height: 900)] {
                let tag = "\(Int(screen.width))x\(Int(screen.height))"
                let model = makeModel()
                model.select(model.visibleItems[0])
                try await render("panel-\(tag)", NSSize(width: screen.width, height: PanelPresentation.baseHeight), radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.selectedPinboardID = model.snapshot.pinboards.first?.id
                try await render("panel-board-\(tag)", NSSize(width: screen.width, height: PanelPresentation.baseHeight), radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.selectedPinboardID = nil
                model.isSearchVisible = true
                try await render("panel-search-\(tag)", NSSize(width: screen.width, height: PanelPresentation.baseHeight), radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.isSearchVisible = false
                let detailHeight = PanelDetailLayout.contentHeight(forScreenHeight: screen.height)
                model.panelDetailContentHeight = detailHeight
                let grown = NSSize(width: screen.width, height: PanelPresentation.baseHeight + PanelDetailLayout.spacing + detailHeight)
                let text = model.visibleItems.first { $0.kind == .text }!
                model.select(text)
                model.openPanelEditor(text)
                try await render("detail-edit-\(tag)", grown, radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.closePanelDetail()
                model.toolInputText = text.text
                model.openPanelDetail(.translate, itemID: text.id)
                try await render("detail-translate-\(tag)", grown, radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.closePanelDetail()
                model.openPanelDetail(.intelligence, itemID: text.id)
                try await render("detail-intelligence-\(tag)", grown, radius: DesignTokens.Radius.panel, PastePanelView(model: model))
                model.closePanelDetail()
            }
            let model = makeModel()
            for kind in [ClipKind.text, .image, .file, .link] {
                guard let item = model.visibleItems.first(where: { $0.kind == kind }) else { continue }
                try await render("preview-\(kind.rawValue)", NSSize(width: 720, height: 480), PreviewView(model: model, itemID: item.id))
            }
            if let long = model.visibleItems.first(where: { $0.title.hasPrefix("超长") }) {
                try await render("preview-long", NSSize(width: 720, height: 480), PreviewView(model: model, itemID: long.id))
            }
            model.setStack(Array(model.visibleItems.prefix(4)))
            try await render("capsule-collapsed", NSSize(width: StackCapsuleView.width, height: 60), radius: DesignTokens.Radius.xl, StackCapsuleView(model: model) {})
            try await render("capsule-expanded", NSSize(width: StackCapsuleView.width, height: 60 + StackCapsuleView.listHeight(rows: 4) + 8), radius: DesignTokens.Radius.lg, StackCapsuleView(model: model, expanded: true) {})
            if let board = model.snapshot.pinboards.first {
                try await render("classify-popover", NSSize(width: 360, height: 420), radius: DesignTokens.Radius.lg, CategoryClassificationSettings(model: model, board: board) {})
            }
            try await render("settings", NSSize(width: 640, height: 592), SettingsView(model: model))
        }
        return count
    }

    static func makeModel() -> AppModel {
        let model = AppModel(isDemo: true, storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snapshots-\(UUID().uuidString)"))
        let long = "超长标题：这是一段非常长的中文与 English mixed 文本，用来检查截断、换行和按钮是否被挤压 — The quick brown fox jumps over the lazy dog again and again"
        let item = ClipItem(title: long, text: String(repeating: long + "\n", count: 6), kind: .text,
                            sourceBundleID: "com.example.verylongapplicationname", sourceName: "一个名字特别长的应用程序 Very Long Application Name")
        model.snapshot.items.insert(item, at: 2)
        return model
    }

    private static func snapshot<V: View>(_ view: V, size: NSSize, radius: CGFloat, appearance: NSAppearance, to url: URL) async throws {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.backgroundColor = appearance.name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let content = PanelGlassContainer.make(content: view.environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light),
                                               frame: frame, cornerRadius: radius, reduceTransparency: true)
        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = window.backgroundColor.cgColor
        content.frame = frame
        root.addSubview(content)
        window.contentView = root
        window.orderFrontRegardless()
        for _ in 0..<4 {
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        root.displayIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: frame) else { throw SystemChecks.Failure(message: "snapshot bitmap failed") }
        root.cacheDisplay(in: frame, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SystemChecks.Failure(message: "snapshot PNG failed") }
        try png.write(to: url)
        window.orderOut(nil)
        window.close()
    }
}
#endif
