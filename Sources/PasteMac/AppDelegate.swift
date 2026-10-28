import AppKit
import SwiftUI
import PasteCore
import Carbon
import QuartzCore
import OSLog
import Combine

/// The 连续粘贴 capsule never becomes key, so clicking it leaves the target
/// app focused with its insertion point intact.
final class StackCapsulePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let captureLogger = Logger(subsystem: "com.gaoxs.pasteboard", category: "screenshot")
    private var menuObservations = Set<AnyCancellable>()
    private var model: AppModel!
    private var panel: ClipboardPanel!
    private var panelSurface: NSView!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var accessibilityGuide: AccessibilityGuide?
    private var suggestionResultWindow: NSWindow?
    private var historyManagementWindow: NSWindow?
    private var mcpService: MCPService!
    private var stackCapsule: StackCapsulePanel?
    /// Top-left corner the capsule keeps while its height changes.
    private var stackCapsuleTopLeft: CGPoint?
    private var positioningStackCapsule = false
    private var shortcut: GlobalShortcut!
    private var stackShortcut: GlobalShortcut!
    private var localKeyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var panelPresented = false
    private var presentationGeneration = 0
    private let panelFrameAnimator = PanelFrameAnimator()
    private var pendingSuggestionResize: Task<Void, Never>?
    private var pasteHideWaiters: [CheckedContinuation<Void, Never>] = []
    private var toolWindow: ClipboardPanel?
    private let toolWindowPosition = ToolWindowPositionStore()
    private var positioningToolWindow = false
    private let screenshotCoordinator = ScreenshotCoordinator()
    private var screenshotTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private let selectedTextCapture = SelectedTextCapture()
    private var permissionResumeTask: Task<Void, Never>?
    private var toolKeyMonitor: Any?
    private var previewWindow: NSWindow?
    private var previewKeyMonitor: Any?
    private var toolClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
        model = AppModel(isDemo: demo)
        mcpService = MCPService(model: model)
        AppIntegration.shared.model = model
        AppIntegration.shared.openPanel = { [weak self] in self?.showPanel() }
        if !demo { PasteboardShortcuts.updateAppShortcutParameters() }
        model.onClose = { [weak self] in self?.hidePanel(restoreTarget: true) }
        model.onPreparePaste = { [weak self] in
            // Pasting from the preview window closes it, as pasting closes the panel.
            self?.model.closePreview()
            await self?.hidePanelForPaste()
        }
        model.onPreviewClose = { [weak self] in self?.previewWindow?.close() }
        model.onRevealPanel = { [weak self] in
            guard let self else { return }
            if self.panelPresented { self.panel?.makeKeyAndOrderFront(nil) } else { self.showPanel(rememberTarget: false) }
        }
        model.onPasteFailure = { [weak self] in self?.showPanel(rememberTarget: false) }
        model.onSuggestionPreview = { [weak self] result in
            guard let self else { return }
            self.hidePanel()
            self.model.retainHistory(result.sourceIDs, for: "suggestion")
            self.suggestionResultWindow = self.window(title: "处理结果", size: .init(width: 700, height: 540), view: ContextSuggestionResultPreview(model: self.model, result: result))
            NSApp.activate(); self.suggestionResultWindow?.makeKeyAndOrderFront(nil)
        }
        model.onHistoryManagementClose = { [weak self] in self?.historyManagementWindow?.close() }
        model.onHistoryManagementPreview = { [weak self] preview in
            guard let self else { return }
            self.historyManagementWindow = self.window(title: "搜索操作", size: .init(width: 480, height: 340), view: HistorySearchManagementView(model: self.model, preview: preview))
            NSApp.activate(); self.historyManagementWindow?.makeKeyAndOrderFront(nil)
        }
        model.onSuggestionPanelChange = { [weak self] _ in self?.resizePanelForSuggestions() }
        model.onPanelDetailChange = { [weak self] in self?.panelDetailChanged() }
        model.pasteEngine.onTargetChange = { [weak self] in self?.model.scheduleContextSuggestions() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onAccessibilityGuide = { [weak self] in
            guard let self else { return }
            self.hidePanel()
            if self.accessibilityGuide == nil { self.accessibilityGuide = AccessibilityGuide(model: self.model) }
            self.accessibilityGuide?.show()
        }
        model.onEditor = { [weak self] item in self?.showEditor(item) }
        model.onEditorClose = { [weak self] in self?.model.cancelPanelEditor() }
        model.onPreview = { [weak self] item in self?.showPreview(item) }
        model.onIntelligence = { [weak self] item in self?.showIntelligence(item) }
        model.onStack = { [weak self] in self?.showStack() }
        model.onStackPasted = { [weak self] in self?.placeStackCapsule(followMouse: true) }
        model.onToolStart = { [weak self] in
            self?.permissionResumeTask?.cancel(); self?.permissionResumeTask = nil
            self?.accessibilityGuide?.dismiss()
        }
        model.onShowTools = { [weak self] in self?.showTools() }
        model.onSelectionTool = { [weak self] in self?.captureSelectedText() }
        model.onScreenshotTool = { [weak self] translate in self?.captureScreenshot(translate: translate) }
        model.toolShortcuts = ToolShortcutManager { [weak self] action in
            guard let self, self.selectionTask == nil, self.screenshotTask == nil, !self.screenshotCoordinator.isCapturing else { return }
            self.model.performTool(action)
        }
        makePanel()
        makeMenus()
        shortcut = GlobalShortcut()
        shortcut.onActivate = { [weak self] in
            guard let self, self.selectionTask == nil, self.screenshotTask == nil, !self.screenshotCoordinator.isCapturing else { return }; self.togglePanel()
        }
        model.onShortcut = { [weak self] key, modifiers in
            guard let self, self.model.toolShortcuts?.conflicts(keyCode: key, modifiers: modifiers) != true,
                  !self.matchesLegacyShortcut(key, modifiers, stack: true) else { return false }
            return self.shortcut.register(keyCode: key, modifiers: modifiers)
        }
        let defaults = UserDefaults.standard
        let key = defaults.object(forKey: "shortcutKeyCode") != nil ? UInt32(exactly: defaults.integer(forKey: "shortcutKeyCode")) ?? 9 : 9
        let modifiers = defaults.object(forKey: "shortcutModifiers") != nil ? UInt32(exactly: defaults.integer(forKey: "shortcutModifiers")) ?? UInt32(cmdKey | shiftKey) : UInt32(cmdKey | shiftKey)
        if shortcut.register(keyCode: key, modifiers: modifiers) {
            model.restoreShortcutDescription(defaults.string(forKey: "shortcutDescription") ?? "⇧⌘V")
        } else {
            model.restoreShortcutDescription((defaults.string(forKey: "shortcutDescription") ?? "⇧⌘V") + "（占用）")
            model.statusMessage = "打开剪贴板的快捷键已被占用。请从菜单栏打开设置并更换快捷键。"
        }
        stackShortcut = GlobalShortcut(identifier: 2)
        stackShortcut.onActivate = { [weak self] in
            guard let self, self.selectionTask == nil, self.screenshotTask == nil, !self.screenshotCoordinator.isCapturing else { return }; self.model.showStack()
        }
        model.onStackShortcut = { [weak self] key, modifiers in
            guard let self, self.model.toolShortcuts?.conflicts(keyCode: key, modifiers: modifiers) != true,
                  !self.matchesLegacyShortcut(key, modifiers, stack: false) else { return false }
            return self.stackShortcut.register(keyCode: key, modifiers: modifiers)
        }
        let stackKey = defaults.object(forKey: "stackShortcutKeyCode") != nil ? UInt32(exactly: defaults.integer(forKey: "stackShortcutKeyCode")) ?? 8 : 8
        let stackModifiers = defaults.object(forKey: "stackShortcutModifiers") != nil ? UInt32(exactly: defaults.integer(forKey: "stackShortcutModifiers")) ?? UInt32(cmdKey | shiftKey) : UInt32(cmdKey | shiftKey)
        if stackShortcut.register(keyCode: stackKey, modifiers: stackModifiers) {
            model.restoreStackShortcutDescription(defaults.string(forKey: "stackShortcutDescription") ?? "⇧⌘C")
        } else { model.restoreStackShortcutDescription("⇧⌘C（占用）") }
        installInputMonitors()
        model.startMonitoring()
        showPanel()
    }

    private func makePanel() {
        panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 330),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pasteboard 剪贴板"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = PanelGlassContainer.make(content: PastePanelView(model: model), frame: panel.contentRect(forFrameRect: panel.frame))
        panelSurface = (panel.contentView as? PanelAnimationContainer)?.surface
    }

    private func showPanel(rememberTarget: Bool = true) {
        guard !model.isPasting, screenshotTask == nil, !screenshotCoordinator.isCapturing else { return }
        cancelSuggestionResize()
        if rememberTarget { model.pasteEngine.rememberTarget() }
        model.refreshDirectPastePermission()
        model.suggestionSessionActive = true
        model.selectFirstIfNeeded()
        model.scheduleContextSuggestions()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let destination = panelDestination(on: frame)
        presentationGeneration += 1
        let wasPresented = panelPresented
        panelPresented = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(destination, display: true)
        if !wasPresented && !panel.isVisible && !reduceMotion {
            panelSurface.frame = PanelPresentation.hiddenContentFrame(size: destination.size)
            panel.alphaValue = 0.85
        }
        panel.makeKeyAndOrderFront(nil)
        if reduceMotion || wasPresented {
            panelSurface.frame = NSRect(origin: .zero, size: destination.size)
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panelSurface.animator().setFrameOrigin(.zero)
                panel.animator().alphaValue = 1
            }
        }
    }
    private func resizePanelForSuggestions() {
        pendingSuggestionResize?.cancel()
        // Summary, loading and expansion change together. Read the final layout once.
        pendingSuggestionResize = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.applySuggestionPanelSize()
        }
    }
    private func applySuggestionPanelSize() {
        guard panelPresented, model.suggestionSessionActive, !model.isPasting, let panel, let screen = panel.screen else { return }
        let destination = panelDestination(on: screen.frame)
        panelFrameAnimator.animate(panel, to: destination, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    /// One height for the panel: base deck plus either the detail layer or the suggestions bar.
    private func panelDestination(on screen: NSRect) -> NSRect {
        let detailHeight = PanelDetailLayout.contentHeight(forScreenHeight: screen.height)
        if model.panelDetailContentHeight != detailHeight { model.panelDetailContentHeight = detailHeight }
        return PanelPresentation.visibleFrame(on: screen, suggestionsVisible: model.suggestionStripAvailable,
                                              additionalHeight: model.suggestionAdditionalHeight,
                                              detailContentHeight: model.panelDetail == nil ? nil : detailHeight)
    }
    private func panelDetailChanged() {
        if panelPresented { resizePanelForSuggestions() }
        else if model.panelDetail != nil { showPanel() }
    }
    private func cancelSuggestionResize() {
        pendingSuggestionResize?.cancel(); pendingSuggestionResize = nil
        panelFrameAnimator.cancel()
    }
    private func hidePanel(restoreTarget: Bool = false) {
        panelPresented = false
        cancelSuggestionResize()
        guard panel.isVisible else { model?.suggestionSessionActive = false; model?.panelDidHide(); finishPasteHide(); return }
        presentationGeneration += 1
        let generation = presentationGeneration
        let finish = { [weak self] in
            guard let self, self.presentationGeneration == generation, !self.panelPresented else { return }
            self.panel.orderOut(nil)
            // Keep the summary intact until the surface has left the screen.
            self.model?.suggestionSessionActive = false
            self.model?.panelDidHide()
            self.panel.alphaValue = 1
            if restoreTarget { self.model.pasteEngine.restoreTarget() }
            self.finishPasteHide()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        let destination = PanelPresentation.hiddenContentFrame(size: panel.frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelSurface.animator().setFrameOrigin(destination.origin)
            panel.animator().alphaValue = 0.85
        } completionHandler: { finish() }
    }
    private func hidePanelImmediately() {
        // Captures and owned windows must not inherit a pending panel animation
        // or its completion handler's focus restoration.
        panelPresented = false
        cancelSuggestionResize()
        model?.suggestionSessionActive = false
        model?.panelDidHide()
        presentationGeneration += 1
        panel.orderOut(nil)
        panelSurface.layer?.removeAllAnimations()
        panelSurface.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.alphaValue = 1
        finishPasteHide()
    }

    private func hidePanelForPaste() async {
        guard panel.isVisible else { return }
        await withCheckedContinuation { continuation in
            pasteHideWaiters.append(continuation)
            hidePanel()
        }
    }
    private func finishPasteHide() {
        let waiters = pasteHideWaiters
        pasteHideWaiters = []
        waiters.forEach { $0.resume() }
    }
    private func togglePanel() {
        guard !model.isPasting else { return }
        if panelPresented { hidePanel(restoreTarget: true) } else { showPanel() }
    }

    private func window<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let value = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        value.title = title
        value.titlebarAppearsTransparent = true
        value.titleVisibility = .hidden
        value.styleMask.insert(.fullSizeContentView)
        value.isReleasedWhenClosed = false
        value.isOpaque = false; value.backgroundColor = .clear
        value.contentView = PanelGlassContainer.make(content: view, frame: NSRect(origin: .zero, size: size), cornerRadius: DesignTokens.Radius.window)
        place(value)
        value.delegate = self
        return value
    }
    /// Opens a secondary window above the clipboard panel instead of
    /// centering it behind the status-bar-level panel.
    private func place(_ value: NSWindow) {
        let visiblePanel = panelPresented && panel?.isVisible == true ? panel : nil
        let mouse = NSEvent.mouseLocation
        guard let screen = visiblePanel?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            value.center(); return
        }
        value.setFrameOrigin(AuxiliaryWindowPlacement.origin(size: value.frame.size, visibleFrame: screen.visibleFrame, avoiding: visiblePanel?.frame))
    }
    private func showSettings() {
        // This status-bar-level, nonactivating panel otherwise remains above
        // the settings window until the hide animation completes.
        hidePanelImmediately()
        if settingsWindow == nil { settingsWindow = window(title: "Pasteboard 设置", size: .init(width: 640, height: 592), view: SettingsView(model: model, mcp: mcpService)) }
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// Editing opens the panel's edit page; a new text opens it without a card.
    private func showEditor(_ item: ClipItem?) {
        if let item, model.selectedIDs.isEmpty, model.visibleItems.contains(where: { $0.id == item.id }) { model.select(item) }
        model.openPanelEditor(item)
    }
    /// Preview opens its own window above the panel. ← and → in it switch cards,
    /// so an open window is reused instead of reopened.
    private func showPreview(_ item: ClipItem) {
        if model.selectedIDs.isEmpty, model.visibleItems.contains(where: { $0.id == item.id }) { model.select(item) }
        let title = item.title.isEmpty ? item.kind.displayName : String(item.title.prefix(80))
        if let previewWindow, previewWindow.isVisible {
            previewWindow.title = title
        } else {
            previewWindow?.close()
            previewWindow = window(title: title, size: .init(width: 720, height: 480), view: PreviewWindowView(model: model))
        }
        NSApp.activate()
        previewWindow?.makeKeyAndOrderFront(nil)
    }
    private func showStack() {
        model.pasteEngine.rememberTarget()
        let capsule = stackCapsule ?? makeStackCapsule()
        stackCapsule = capsule
        // No NSApp.activate(): the capsule floats without taking focus.
        capsule.orderFrontRegardless()
        placeStackCapsule(followMouse: true)
    }

    private func makeStackCapsule() -> StackCapsulePanel {
        let capsule = StackCapsulePanel(contentRect: NSRect(x: 0, y: 0, width: StackCapsuleView.width, height: 52),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        capsule.isFloatingPanel = true
        capsule.level = .floating
        capsule.hidesOnDeactivate = false
        capsule.becomesKeyOnlyIfNeeded = true
        capsule.isOpaque = false
        capsule.backgroundColor = .clear
        capsule.hasShadow = true
        capsule.isMovableByWindowBackground = true
        capsule.isReleasedWhenClosed = false
        capsule.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        capsule.title = "连续粘贴"
        let host = NSHostingController(rootView: StackCapsuleView(model: model) { [weak self] in self?.closeStackCapsule() })
        host.sizingOptions = [.preferredContentSize]
        capsule.contentViewController = host
        capsule.delegate = self
        return capsule
    }

    private func closeStackCapsule() {
        stackCapsule?.orderOut(nil)
        stackCapsuleTopLeft = nil
    }

    /// Moves the capsule next to the mouse (on show and after each paste) or
    /// keeps its top-left corner (after a resize), clamped to the visible screen.
    /// The capsule stays put when the mouse is already over it, which is the case
    /// right after clicking 粘贴下一项, so the button doesn't jump away.
    private func placeStackCapsule(followMouse: Bool) {
        guard let capsule = stackCapsule, capsule.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let size = capsule.frame.size
        let frame: CGRect
        if followMouse, !capsule.frame.insetBy(dx: -StackCapsulePlacement.cursorGap, dy: -StackCapsulePlacement.cursorGap).contains(mouse) {
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? capsule.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            frame = StackCapsulePlacement.frame(size: size, mouse: mouse, visible: visible)
        } else {
            guard let visible = (capsule.screen ?? NSScreen.main)?.visibleFrame else { return }
            let topLeft = stackCapsuleTopLeft ?? CGPoint(x: capsule.frame.minX, y: capsule.frame.maxY)
            frame = StackCapsulePlacement.resized(size, topLeft: topLeft, visible: visible)
        }
        stackCapsuleTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        guard frame != capsule.frame else { return }
        positioningStackCapsule = true
        capsule.setFrame(frame, display: true)
        positioningStackCapsule = false
    }

    private func makeMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Pasteboard")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("打开剪贴板", selector: #selector(openPanel)))
        menu.addItem(item("新建文本", selector: #selector(newText)))
        menu.addItem(item("连续粘贴", selector: #selector(openStack)))
        menu.addItem(.separator())
        menu.addItem(item("截图识别", selector: #selector(openScreenshotOCR)))
        menu.addItem(item("截图翻译", selector: #selector(openScreenshotTranslation)))
        menu.addItem(item("输入翻译", selector: #selector(openInputTranslation)))
        menu.addItem(item("剪贴板翻译", selector: #selector(openClipboardTranslation)))
        menu.addItem(item("选中文字翻译", selector: #selector(openSelectionTranslation)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", selector: #selector(openSettings), key: ","))
        menu.addItem(item("恢复收集", selector: #selector(resume)))
        menu.addItem(item("暂停收集 15 分钟", selector: #selector(pause)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Pasteboard", selector: #selector(quit), key: "q"))
        statusItem.menu = menu
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(item("关于 Pasteboard", selector: #selector(about)))
        appMenu.addItem(item("打开剪贴板", selector: #selector(openPanel)))
        appMenu.addItem(item("设置…", selector: #selector(openSettings), key: ","))
        appMenu.addItem(item("截图识别", selector: #selector(openScreenshotOCR)))
        appMenu.addItem(item("截图翻译", selector: #selector(openScreenshotTranslation)))
        appMenu.addItem(item("输入翻译", selector: #selector(openInputTranslation)))
        appMenu.addItem(item("剪贴板翻译", selector: #selector(openClipboardTranslation)))
        appMenu.addItem(item("选中文字翻译", selector: #selector(openSelectionTranslation)))
        #if DEBUG
        appMenu.addItem(item("打开粘贴验收器…", selector: #selector(openPasteReceiver)))
        appMenu.addItem(item("验收系统搜索链接…", selector: #selector(openIntegrationFixture)))
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出 Pasteboard", selector: #selector(quit), key: "q"))
        let application = NSMenuItem(); application.title = "Pasteboard"; application.submenu = appMenu; main.addItem(application)
        let edit = NSMenu()
        edit.addItem(item("撤销", selector: #selector(undoAction), key: "z"))
        let redo = item("重做", selector: #selector(redoAction), key: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editing = NSMenuItem(); editing.title = "编辑"; editing.submenu = edit; main.addItem(editing)
        NSApp.mainMenu = main
        model.$hotKeyDescription.sink { [weak self] in self?.refreshShortcutMenus(clipboard: $0) }.store(in: &menuObservations)
        model.$stackHotKeyDescription.sink { [weak self] in self?.refreshShortcutMenus(stack: $0) }.store(in: &menuObservations)
        model.toolShortcuts?.$bindings.sink { [weak self] in self?.refreshShortcutMenus(bindings: $0) }.store(in: &menuObservations)
    }
    private func refreshShortcutMenus(clipboard: String? = nil, stack: String? = nil, bindings: [ToolAction: ToolShortcut]? = nil) {
        for menu in [statusItem.menu, NSApp.mainMenu?.items.first?.submenu].compactMap({ $0 }) {
            updateShortcutMenu(menu, clipboard: clipboard ?? model.hotKeyDescription, stack: stack ?? model.stackHotKeyDescription,
                               bindings: bindings ?? model.toolShortcuts?.bindings ?? [:])
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        updateShortcutMenu(menu, clipboard: model.hotKeyDescription, stack: model.stackHotKeyDescription,
                           bindings: model.toolShortcuts?.bindings ?? [:])
        // Offer only the pause action that applies right now.
        for entry in menu.items {
            if entry.action == #selector(resume) { entry.isHidden = !model.isPaused }
            else if entry.action == #selector(pause) { entry.isHidden = model.isPaused }
        }
    }
    private func updateShortcutMenu(_ menu: NSMenu, clipboard: String, stack: String, bindings: [ToolAction: ToolShortcut]) {
        let tools: [(Selector, ToolAction)] = [
            (#selector(openScreenshotOCR), .screenshotOCR), (#selector(openScreenshotTranslation), .screenshotTranslate),
            (#selector(openInputTranslation), .inputTranslate), (#selector(openClipboardTranslation), .clipboardTranslate),
            (#selector(openSelectionTranslation), .selectionTranslate)
        ]
        for entry in menu.items {
            if entry.action == #selector(openPanel) {
                MenuShortcut.apply(clipboard, to: entry)
            } else if entry.action == #selector(openStack) {
                MenuShortcut.apply(stack, to: entry)
            } else if let tool = tools.first(where: { entry.action == $0.0 }) {
                let binding = bindings[tool.1]
                MenuShortcut.apply(binding?.description, enabled: binding?.enabled == true, to: entry)
            }
        }
    }

    private func item(_ title: String, selector: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        value.target = self
        return value
    }

    private func installInputMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.panel else { return event }
            return self.handle(event) ? nil : event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
                // System translation can show language/download dialogs in another process.
                if self?.model.toolBusy == false { self?.closeUnpinnedTools() }
            }
        }
        toolClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Popup menus and settings use other windows in this process. They are
            // part of the tool interaction, not an outside click that cancels work.
            if event.window === self.panel { self.closeUnpinnedTools() }
            return event
        }
        // Preview window: ← → switch cards, Space closes like Quick Look. Esc and Return use its buttons.
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let preview = self.previewWindow, event.window === preview else { return event }
            if let text = preview.firstResponder as? NSTextView, text.hasMarkedText() || text.isEditable { return event }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 123: self.model.movePreview(-1); return nil
            case 124: self.model.movePreview(1); return nil
            case 49: if !event.isARepeat { self.model.closePreview() }; return nil
            default: return event
            }
        }
        toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.toolWindow else { return event }
            if let editor = self.toolWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.isARepeat { return event }
            if event.keyCode == 53 { self.toolWindow?.close(); return nil }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "p" { self.model.toolPinned.toggle(); return nil }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "r" { self.model.retryToolOperation(); return nil }
            if [36, 76].contains(event.keyCode), flags.isEmpty { self.model.translateToolInput(); return nil }
            return event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let textEditing = panel.firstResponder is NSTextView
        if event.isARepeat && !textEditing && ([36, 76, 49].contains(event.keyCode) || flags.contains(.command)) { return true }
        if let page = model.panelDetail?.page,
           let action = PanelDetailKey.resolve(page: page, keyCode: event.keyCode, flags: flags,
                                               key: event.charactersIgnoringModifiers?.lowercased(),
                                               textEditing: textEditing,
                                               composing: (panel.firstResponder as? NSTextView)?.hasMarkedText() == true,
                                               fieldEditor: (panel.firstResponder as? NSTextView)?.isFieldEditor == true) {
            guard !event.isARepeat else { return true }
            switch action {
            case .save: model.savePanelEditor()
            case .translate: model.translateToolInput()
            case .retry: model.retryToolOperation()
            case .ignore: break
            }
            return true
        }
        if event.keyCode == 53 {
            let editor = panel.firstResponder as? NSTextView
            switch PanelEscapeAction.resolve(detailOpen: model.panelDetail != nil, textEditing: textEditing,
                                             fieldEditor: editor?.isFieldEditor == true, composing: editor?.hasMarkedText() == true) {
            case .passToText: return false
            case .endTextEditing: panel.makeFirstResponder(nil); return true
            case .closeDetail: model.closePanelDetail(); return true
            case .hidePanel: hidePanel(restoreTarget: true); return true
            }
        }
        if flags == .option, !textEditing,
           let number = PanelKeyboard.digit(for: event.keyCode),
           (1...5).contains(number), model.displayedSuggestions.indices.contains(number - 1) {
            if !event.isARepeat { model.applyContextSuggestion(model.displayedSuggestions[number - 1]) }
            return true
        }
        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "f" { model.isSearchVisible.toggle(); return true }
            if key == "," { showSettings(); return true }
            if !textEditing {
                // Match the physical key: ⇧1 reads as "!" on US layouts.
                if let number = PanelKeyboard.digit(for: event.keyCode), model.visibleItems.count >= number {
                    model.activate(model.visibleItems[number - 1], plainText: flags.contains(.shift)); return true
                }
                if key == "c" { model.copySelected(plainText: flags.contains(.shift)); return true }
                if key == "a" { model.selectedIDs = Set(model.visibleItems.map(\.id)); return true }
                if key == "z" { flags.contains(.shift) ? model.redo() : model.undo(); return true }
                if key == "n" {
                    if flags.contains(.shift) { model.createPinboard(name: "未命名") } else { model.newText() }
                    return true
                }
                if key == "o", let item = model.selectedItems.first { model.openItem(item); return true }
                if flags == .command, let page = PanelDetailPage.forCommandKey(key) { model.openPanelDetailForSelection(page); return true }
                if event.keyCode == 124 || event.keyCode == 123 {
                    let ids: [UUID?] = [nil] + model.snapshot.pinboards.map { Optional($0.id) }
                    let index = ids.firstIndex(where: { $0 == model.selectedPinboardID }) ?? 0
                    model.selectedPinboardID = ids[(index + (event.keyCode == 124 ? 1 : ids.count - 1)) % ids.count]
                    model.selectedIDs = []; model.selectFirstIfNeeded(); return true
                }
            }
        }
        guard !textEditing else { return false }
        switch event.keyCode {
        case 123: model.moveSelection(-1); return true
        case 124: model.moveSelection(1); return true
        case 36, 76:
            model.activateSelected(plainText: flags.contains(.shift))
            return true
        case 49: model.togglePreview(); return true
        case 51, 117: model.deleteSelected(); return true
        default: return false
        }
    }

    @objc private func openPanel() { showPanel() }
    /// Smart actions open the panel's smart page.
    private func showIntelligence(_ item: ClipItem) {
        if model.selectedIDs.isEmpty, model.visibleItems.contains(where: { $0.id == item.id }) { model.select(item) }
        model.openPanelDetail(.intelligence, itemID: item.id)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppIntegration.shared.receive(url) }
    }
    #if DEBUG
    @objc private func openIntegrationFixture() {
        guard let url = URL(string: "pasteboard://search?query=__Pasteboard_local_check__") else { return }
        if !NSWorkspace.shared.open(url) { model.statusMessage = "系统未注册 Pasteboard 链接。" }
    }
    @objc private func openPasteReceiver() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PasteReceiver.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        hidePanel()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { self.model.statusMessage = error.localizedDescription } }
        }
    }
    #endif
    @objc private func newText() { showEditor(nil) }
    @objc private func openSettings() { showSettings() }
    @objc private func openStack() { model.showStack() }
    @objc private func resume() { model.resume() }
    @objc private func pause() { model.pause(minutes: 15) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func undoAction() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { model.undo() }
    }
    @objc private func redoAction() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { model.redo() }
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Pasteboard", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "剪贴板管理、文字识别与翻译")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        selectionTask?.cancel(); screenshotTask?.cancel(); screenshotCoordinator.cancel(); model.cancelToolOperation()
        model.stopMonitoring(); mcpService.stop(); model.flushPersistence()
    }
    func windowDidResize(_ notification: Notification) {
        guard let capsule = stackCapsule, notification.object as? NSWindow === capsule, !positioningStackCapsule else { return }
        placeStackCapsule(followMouse: false)
    }

    func windowDidMove(_ notification: Notification) {
        if let capsule = stackCapsule, notification.object as? NSWindow === capsule, !positioningStackCapsule {
            // Dragged by hand: keep the new spot until the next show or paste.
            stackCapsuleTopLeft = CGPoint(x: capsule.frame.minX, y: capsule.frame.maxY)
            return
        }
        guard let toolWindow, notification.object as? NSWindow === toolWindow,
              toolWindow.isVisible, !positioningToolWindow else { return }
        toolWindowPosition.save(toolWindow.frame.origin)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === suggestionResultWindow { model.releaseHistory(for: "suggestion") }
        if notification.object as? NSWindow === toolWindow { model.toolSessionActive = false; model.cancelToolOperation() }
        if notification.object as? NSWindow === previewWindow {
            model.previewWindowClosed()
            // Keys go back to the panel so ← → and Space keep working there.
            if panelPresented, panel?.isVisible == true { panel?.makeKey() }
        }
    }
    private func matchesLegacyShortcut(_ key: UInt32, _ flags: UInt32, stack: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let keyName = stack ? "stackShortcutKeyCode" : "shortcutKeyCode"
        let flagsName = stack ? "stackShortcutModifiers" : "shortcutModifiers"
        let savedKey = defaults.object(forKey: keyName).flatMap { ($0 as? NSNumber)?.uint32Value } ?? (stack ? 8 : 9)
        let savedFlags = defaults.object(forKey: flagsName).flatMap { ($0 as? NSNumber)?.uint32Value } ?? UInt32(cmdKey | shiftKey)
        return key == savedKey && flags == savedFlags
    }
    private func showTools() {
        guard !screenshotCoordinator.isCapturing else { return }
        model.toolSessionActive = true
        // Started from the panel (or while its translate page is open): stay in the panel.
        if panelPresented, model.toolsHostedInPanel || model.panelDetail?.page == .translate {
            model.toolsHostedInPanel = false
            model.openPanelDetail(.translate, itemID: model.toolItemID)
            return
        }
        hidePanel()
        if toolWindow == nil {
            let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            let value = ClipboardPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            value.title = "Pasteboard 识别与翻译"; value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
            value.isReleasedWhenClosed = false; value.hidesOnDeactivate = false; value.level = .floating
            value.isMovableByWindowBackground = true
            value.isOpaque = false; value.backgroundColor = .clear
            value.minSize = NSSize(width: 560, height: 480)
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            value.contentView = PanelGlassContainer.make(content: QuickToolView(model: model), frame: frame, cornerRadius: DesignTokens.Radius.window)
            value.delegate = self; toolWindow = value
        }
        guard let toolWindow else { return }
        if !toolWindow.isVisible {
            let mouse = NSEvent.mouseLocation
            let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = ToolWindowPlacement.origin(size: toolWindow.frame.size, saved: toolWindowPosition.load(),
                                                    screens: NSScreen.screens.map(\.visibleFrame), defaultScreen: visible)
            positioningToolWindow = true
            toolWindow.setFrameOrigin(origin)
            positioningToolWindow = false
        }
        NSApp.activate(); toolWindow.makeKeyAndOrderFront(nil)
    }
    private func closeUnpinnedTools() {
        if !model.toolPinned, toolWindow?.isVisible == true { toolWindow?.close() }
    }
    private func captureScreenshot(translate: Bool) {
        guard selectionTask == nil, screenshotTask == nil, !screenshotCoordinator.isCapturing, !model.isPasting else { return }
        model.toolSessionActive = false
        model.cancelToolOperation(); model.toolItemID = nil; model.toolInputText = ""; model.toolError = nil; model.toolStatus = nil
        toolWindow?.orderOut(nil); previewWindow?.orderOut(nil); settingsWindow?.orderOut(nil)
        screenshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.screenshotTask = nil }
            self.captureLogger.notice("capture requested")
            self.hidePanelImmediately()
            do {
                try Task.checkCancellation()
                let data = try await self.screenshotCoordinator.captureRegion()
                self.captureLogger.notice("region captured")
                try Task.checkCancellation()
                if self.model.addScreenshot(data, translateAfter: translate) == nil { self.showTools() }
            } catch is CancellationError { }
            catch ScreenshotCoordinator.Failure.cancelled {
                self.captureLogger.notice("capture cancelled")
                self.model.toolError = nil; self.model.toolStatus = "截图已取消。"; self.showTools()
            }
            catch {
                self.captureLogger.error("capture failed: \(String(describing: type(of: error)), privacy: .public)")
                if PermissionGuideKind.forError(error) == .screenCapture || !ScreenshotCoordinator.isPermissionGranted {
                    self.showToolPermissionGuide(.screenCapture) { [weak self] in self?.captureScreenshot(translate: translate) }
                } else { self.model.toolError = error.localizedDescription; self.showTools() }
            }
        }
    }
    private func captureSelectedText() {
        guard selectionTask == nil, screenshotTask == nil, !screenshotCoordinator.isCapturing, !model.isPasting else { return }
        // Remember the original app before presenting any permission UI.
        let originalApp = NSWorkspace.shared.frontmostApplication
        model.cancelToolOperation()
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.selectionTask = nil }
            do {
                let text = try await self.selectedTextCapture.capture()
                try Task.checkCancellation()
                self.model.beginSelectedTextTranslation(text)
            } catch is CancellationError { }
            catch {
                if PermissionGuideKind.forError(error) == .selectionTranslation {
                    self.showToolPermissionGuide(.selectionTranslation) { [weak self, originalApp] in
                        guard let self else { return }
                        guard let originalApp, originalApp.processIdentifier != getpid(), !originalApp.isTerminated else {
                            self.model.toolStatus = "辅助功能权限已开启。请返回目标应用，选中文字后重新翻译。"
                            self.showTools(); return
                        }
                        guard originalApp.activate() else {
                            self.model.toolStatus = "辅助功能权限已开启。请返回目标应用，选中文字后重新翻译。"
                            self.showTools(); return
                        }
                        self.permissionResumeTask?.cancel()
                        self.permissionResumeTask = Task { @MainActor [weak self] in
                            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                            guard !Task.isCancelled, let self,
                                  NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp.processIdentifier else { return }
                            self.permissionResumeTask = nil
                            self.captureSelectedText()
                        }
                    }
                } else {
                    self.model.toolError = error.localizedDescription
                    self.model.toolStatus = nil
                    self.showTools()
                }
            }
        }
    }
    private func showToolPermissionGuide(_ kind: PermissionGuideKind, onAuthorized: @escaping () -> Void) {
        model.toolSessionActive = false
        hidePanel(); toolWindow?.orderOut(nil); previewWindow?.orderOut(nil)
        if accessibilityGuide == nil { accessibilityGuide = AccessibilityGuide(model: model) }
        accessibilityGuide?.show(kind: kind, onAuthorized: onAuthorized)
    }
    @objc private func openSelectionTranslation() { model.performTool(.selectionTranslate) }
    @objc private func openScreenshotOCR() { model.performTool(.screenshotOCR) }
    @objc private func openScreenshotTranslation() { model.performTool(.screenshotTranslate) }
    @objc private func openInputTranslation() { model.performTool(.inputTranslate) }
    @objc private func openClipboardTranslation() { model.performTool(.clipboardTranslate) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }
}

#if DEBUG
extension AppDelegate {
    /// Adopts a synthetic fixture without launching production services or reading user history.
    @MainActor
    static func presentationPreview(model: AppModel, panel: ClipboardPanel) -> AppDelegate {
        guard let container = panel.contentView as? PanelAnimationContainer else {
            preconditionFailure("Presentation preview requires the production glass container")
        }
        let owner = AppDelegate()
        owner.model = model
        owner.panel = panel
        owner.panelSurface = container.surface
        owner.panelPresented = true
        model.onSuggestionPanelChange = { [weak owner] _ in owner?.resizePanelForSuggestions() }
        model.onClose = { [weak owner] in owner?.hidePanel() }
        model.onSettings = { [weak owner] in owner?.showSettings() }
        return owner
    }

    @objc func previewLightAppearance() { panel.appearance = NSAppearance(named: .aqua) }
    @objc func previewDarkAppearance() { panel.appearance = NSAppearance(named: .darkAqua) }

    @objc func previewShowSettings() { showSettings() }
    @objc func previewHidePanel() { hidePanel() }
    @objc func previewShowPanel() { showPanel(rememberTarget: false) }

    /// Exercises the immediate handoff used by capture and settings with hidden test windows.
    /// No screen access or clipboard writes.
    @MainActor
    static func checkCapturePanelHandoff() async throws -> Int {
        let owner = AppDelegate()
        owner.panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        owner.panel.isReleasedWhenClosed = false
        defer { owner.panel.close() }
        owner.panelSurface = NSView(frame: NSRect(x: 0, y: -104, width: 300, height: 100))
        owner.panel.alphaValue = 0.85
        owner.panelPresented = true
        owner.presentationGeneration = 2 // A reopen invalidated the original hide callback.
        var resumed = 0
        let first = Task { @MainActor in
            await withCheckedContinuation { owner.pasteHideWaiters.append($0) }
            resumed += 1
        }
        let second = Task { @MainActor in
            await withCheckedContinuation { owner.pasteHideWaiters.append($0) }
            resumed += 1
        }
        for _ in 0..<1000 where owner.pasteHideWaiters.count < 2 { await Task.yield() }
        guard owner.pasteHideWaiters.count == 2 else { throw SystemChecks.Failure(message: "Capture handoff fixture did not register waiters") }
        owner.hidePanelImmediately()
        guard owner.pasteHideWaiters.isEmpty else { throw SystemChecks.Failure(message: "Capture handoff left interrupted hide waiters suspended") }
        guard !owner.panelPresented, !owner.panel.isVisible, owner.presentationGeneration == 3,
              owner.panel.alphaValue == 1, owner.panelSurface.frame.origin == .zero else {
            throw SystemChecks.Failure(message: "Capture handoff retained stale panel presentation")
        }
        await first.value; await second.value
        owner.hidePanelImmediately()
        guard resumed == 2, owner.pasteHideWaiters.isEmpty else {
            throw SystemChecks.Failure(message: "Capture handoff resumed a waiter more than once")
        }
        // An owned-window handoff must also invalidate a previous animated hide,
        // so its completion cannot restore focus over the newly opened window.
        owner.panelPresented = true
        owner.panelSurface.frame.origin.y = -40
        owner.panel.alphaValue = 0.9
        let previousGeneration = owner.presentationGeneration
        owner.hidePanelImmediately()
        guard owner.presentationGeneration == previousGeneration + 1,
              !owner.panelPresented, owner.panelSurface.frame.origin == .zero,
              owner.panel.alphaValue == 1 else {
            throw SystemChecks.Failure(message: "Owned-window handoff retained a stale animation or focus callback")
        }
        return 5
    }
}
#endif
