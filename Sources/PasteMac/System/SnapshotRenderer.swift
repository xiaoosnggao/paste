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
            }
            let model = makeModel()
            // 编辑, 翻译 and 智能 are standalone windows above the panel.
            let windowSize = NSSize(width: 760, height: 480)
            if let text = model.visibleItems.first(where: { $0.kind == .text }) {
                model.select(text)
                model.openPanelEditor(text)
                try await render("window-edit", windowSize, PanelDetailWindowView(model: model))
                model.closePanelDetail()
                model.toolInputText = text.text
                model.toolItemID = text.id
                model.openPanelDetail(.translate, itemID: text.id)
                try await render("window-translate", windowSize, PanelDetailWindowView(model: model))
                model.closePanelDetail()
                model.openPanelDetail(.intelligence, itemID: text.id)
                try await render("window-intelligence", windowSize, PanelDetailWindowView(model: model))
                model.closePanelDetail()
            }
            for kind in [ClipKind.text, .image, .file, .link] {
                guard let item = model.visibleItems.first(where: { $0.kind == kind }) else { continue }
                try await render("preview-\(kind.rawValue)", NSSize(width: 720, height: 480), PreviewView(model: model, itemID: item.id))
            }
            if let long = model.visibleItems.first(where: { $0.title.hasPrefix("超长") }) {
                try await render("preview-long", NSSize(width: 720, height: 480), PreviewView(model: model, itemID: long.id))
            }
            model.setStack(Array(model.visibleItems.prefix(4)))
            let collapsed = StackCapsuleView(model: model) {}
            try await render("capsule-collapsed", fit(collapsed, width: StackCapsuleView.width), radius: DesignTokens.Radius.xl, collapsed)
            let expanded = StackCapsuleView(model: model, expanded: true) {}
            try await render("capsule-expanded", fit(expanded, width: StackCapsuleView.width), radius: DesignTokens.Radius.lg, expanded)
            if let board = model.snapshot.pinboards.first {
                let popover = CategoryClassificationSettings(model: model, board: board) {}
                try await render("classify-popover", fit(popover, width: CategoryClassificationSettings.popoverWidth), radius: DesignTokens.Radius.lg, popover)
            }
            try await render("settings", NSSize(width: 640, height: 592), SettingsView(model: model))
        }
        return count
    }

    /// The height the view asks for at a fixed width, as its real window sizes it.
    static func fit<V: View>(_ view: V, width: CGFloat) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return NSSize(width: width, height: max(40, ceil(host.fittingSize.height)))
    }

    /// Key, so controls draw in their active state as in the real windows.
    private final class SnapshotWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static func makeModel() -> AppModel {
        let model = AppModel(isDemo: true, storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snapshots-\(UUID().uuidString)"))
        let long = "超长标题：这是一段非常长的中文与 English mixed 文本，用来检查截断、换行和按钮是否被挤压 — The quick brown fox jumps over the lazy dog again and again"
        let item = ClipItem(title: long, text: String(repeating: long + "\n", count: 6), kind: .text,
                            sourceBundleID: "com.example.verylongapplicationname", sourceName: "一个名字特别长的应用程序 Very Long Application Name")
        model.snapshot.items.insert(item, at: 2)
        return model
    }

    private static func snapshot<V: View>(_ view: V, size: NSSize, radius: CGFloat, appearance: NSAppearance, to url: URL,
                                          startHeight: CGFloat? = nil, reduceTransparency: Bool = true) async throws {
        let frame = NSRect(origin: .zero, size: size)
        let initial = NSRect(origin: .zero, size: NSSize(width: size.width, height: startHeight ?? size.height))
        let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.backgroundColor = appearance.name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let content = PanelGlassContainer.make(content: view.environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light),
                                               frame: initial, cornerRadius: radius, reduceTransparency: reduceTransparency)
        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = window.backgroundColor.cgColor
        content.frame = initial
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        window.contentView = root
        if startHeight != nil {
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            content.frame = frame
        }
        window.orderFrontRegardless()
        window.makeKey()
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
