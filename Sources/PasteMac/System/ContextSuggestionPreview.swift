#if DEBUG
import AppKit
import PasteCore

/// Manual UI acceptance fixture. Uses a private pasteboard and no network or native paste events.
@MainActor
enum ContextSuggestionPreview {
    private static var window: ClipboardPanel?
    private static var model: AppModel?
    private static var scrollMonitor: Any?
    private static var scrollEvents: [String] = []
    static func show() {
        let board = NSPasteboard.withUniqueName()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-suggestion-preview-\(UUID())")
        let suite = "context-suggestion-preview-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let options = [
            ContextSuggestion(id: "format", title: "整理 JSON", instruction: "将 JSON 按两空格缩进，保留字段和值。", detail: "整理层级与缩进，保留全部字段和值，方便阅读并继续编辑这份配置。"),
            ContextSuggestion(id: "types", title: "生成类型定义", instruction: "从 JSON 推导 TypeScript 类型。", detail: "根据现有字段生成 TypeScript 类型，便于在项目中接入并检查数据。"),
            ContextSuggestion(id: "table", title: "转为字段表格", instruction: "将 JSON 转为易读的 Markdown 表格。", detail: "将字段、类型和值整理为表格，适合发到飞书讨论或补充项目文档。"),
            ContextSuggestion(id: "explain", title: "解释配置内容", instruction: "用中文简要说明字段用途，不推测未知值。", detail: "用简洁中文逐项说明已知配置，保留原始信息，帮助接收者理解内容。"),
            ContextSuggestion(id: "compact", title: "压缩 JSON", instruction: "压缩 JSON，不修改字段和值。", detail: "移除多余空格和换行，保留原有数据，方便粘贴到参数或消息中。")
        ]
        let operations = ContextSuggestionOperations(suggest: { _, _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return options
        }, transform: { input, action, _ in
            try await Task.sleep(nanoseconds: 600_000_000)
            return action.id == "format" ? "{\n  \"name\": \"Clipflow\",\n  \"enabled\": true\n}" : "Processed fixture: \(input.text)"
        })
        let value = AppModel(isDemo: true, storageDirectory: root, bridge: ClipboardBridge(pasteboard: board),
                             toolDefaults: defaults,
                             pasteEngine: PasteEngine(trackApplications: false, target: .init(pid: 0, name: "Lark", bundleID: "com.bytedance.lark")),
                             suggestionOperations: operations)
        let source = ClipItem(title: "应用配置", text: "{\"name\":\"Clipflow\",\"enabled\":true}", kind: .text,
                              sourceBundleID: "com.microsoft.VSCode", sourceName: "Visual Studio Code")
        value.snapshot.items.insert(source, at: 0)
        value.snapshot.preferences.pasteToFrontmost = false
        value.toolConfiguration = .init()
        value.toolConfiguration.aiServices = [AIServiceConfig(name: "验收 Fixture", vendor: .ollama)]
        value.select(source)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let previewScreen = NSRect(x: screen.midX - 640, y: screen.minY + 40, width: 1280, height: screen.height - 80)
        let frame = PanelPresentation.visibleFrame(on: previewScreen)
        let panel = ClipboardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pasteboard 场景建议验收"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = PanelGlassContainer.make(content: PastePanelView(model: value), frame: NSRect(origin: .zero, size: frame.size))
        value.onSuggestionPanelChange = { [weak panel] expanded in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                panel.animator().setFrame(PanelPresentation.visibleFrame(on: previewScreen, suggestionsVisible: expanded), display: true)
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Fixture-only input diagnostics contain deltas, never clipboard or window text.
            scrollEvents.append("x=\(event.scrollingDeltaX) y=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas)")
            scrollEvents = Array(scrollEvents.suffix(100))
            try? scrollEvents.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-preview-scroll.log"), atomically: true, encoding: .utf8)
            return event
        }
        value.onClose = { [weak panel] in
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            panel?.orderOut(nil)
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            NSApplication.shared.terminate(nil)
        }
        model = value; window = panel
        panel.makeKeyAndOrderFront(nil)
        value.suggestionSessionActive = true
        value.scheduleContextSuggestions()
    }
}
#endif
