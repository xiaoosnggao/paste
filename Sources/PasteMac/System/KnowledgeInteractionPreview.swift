#if DEBUG
import AppKit
import SwiftUI
import PasteCore

/// Isolated UI acceptance fixture: synthetic data, private pasteboard and injected operations.
/// It never opens the production database, Keychain, external AI service or target application.
@MainActor
enum KnowledgeInteractionPreview {
    private static var window: ClipboardPanel?
    private static var resultWindow: NSWindow?
    private static var sourceWindow: NSWindow?
    private static var model: AppModel?
    private static var presentationOwner: AppDelegate?

    static func show() {
        let board = NSPasteboard.withUniqueName()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-preview-\(UUID())")
        let suite = "knowledge-preview-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let suggestions = [
            ContextSuggestion(id: "compare", title: "对比报价与条件", instruction: "对比价格、交付日期与条件，不推断缺失信息。", detail: "并列整理价格与交付时间，标出不同之处，便于确认最终采用哪份方案。"),
            ContextSuggestion(id: "confirm", title: "生成确认消息", instruction: "生成一段向供应商核实报价差异的消息。", detail: "将金额和交付日期的差异整理成简短消息，逐项确认，避免遗漏约束条件。"),
            ContextSuggestion(id: "actions", title: "提取待办事项", instruction: "从所选内容提取待确认的事项，保留已知日期。", detail: "汇总需要核实的价格、交付日期与付款条件，保留原始来源，方便后续跟进。"),
            ContextSuggestion(id: "merge", title: "合并成项目记录", instruction: "合并所选内容，保留冲突并标注来源。", detail: "合并重复信息，保留报价差异与条件，生成可继续编辑和保存的项目记录。")
        ]
        let operations = ContextSuggestionOperations(suggest: { _, _ in
            try await Task.sleep(nanoseconds: 1_200_000_000); return suggestions
        }, transform: { input, _, _ in input.text }, summarize: { input, _ in
            try await Task.sleep(nanoseconds: 1_200_000_000)
            var facts = input.cards.map { "[\($0.id.uuidString)] \($0.text)" }
            let hasBothQuotes = input.cards.contains { $0.text.contains("¥5,000") } && input.cards.contains { $0.text.contains("¥6,500") }
            let sentence: String
            if hasBothQuotes {
                sentence = "同一项目收到两份不同报价：微信为 ¥5,000、10 月 22 日交付，飞书为 ¥6,500、10 月 23 日交付，需确认价格和日期差异。"
                facts.append("两份报价的金额与交付日期不同，尚未确定采用哪份方案。")
            } else {
                sentence = "已整理所选项目资料，保留报价、交付时间和验收条件，待确认信息仍需核实。"
            }
            return MultiCardContextSummary(
                sentence: sentence,
                facts: facts, suggestions: suggestions, sourceIDs: input.cards.map(\.id), processedChunks: input.cards.count)
        }, transformMultiple: { input, suggestion, _ in
            try await Task.sleep(nanoseconds: 600_000_000)
            let content = input.cards.map { "### \($0.sourceName)\n\($0.text)" }.joined(separator: "\n\n")
            return "# \(suggestion.title)\n\n\(content)\n\n待确认：报价与交付日期存在差异，暂未确定最终方案。"
        })
        let value = AppModel(isDemo: false, storageDirectory: directory,
                             bridge: ClipboardBridge(pasteboard: board), toolDefaults: defaults,
                             pasteEngine: PasteEngine(trackApplications: false, target: .init(pid: 0, name: "飞书", bundleID: "com.bytedance.lark")),
                             suggestionOperations: operations)
        let copiedAt = Date(timeIntervalSince1970: 1_792_281_600)
        let first = ClipItem(createdAt: copiedAt, lastCopiedAt: copiedAt, title: "官网改版 · 供应商报价", text: "官网改版报价 ¥5,000，2026 年 10 月 22 日交付；付款后开始制作。", kind: .text, sourceBundleID: "com.tencent.xinWeChat", sourceName: "微信")
        let second = ClipItem(createdAt: copiedAt, lastCopiedAt: copiedAt, title: "官网改版 · 更新报价", text: "官网改版报价 ¥6,500，2026 年 10 月 23 日交付；包含两轮修改。", kind: .text, sourceBundleID: "com.bytedance.lark", sourceName: "飞书")
        let third = ClipItem(createdAt: copiedAt, lastCopiedAt: copiedAt, title: "官网改版 · 验收记录", text: "项目需支持桌面和移动端；验收通过后支付尾款，比例尚未确认。", kind: .text, sourceBundleID: "com.apple.Notes", sourceName: "备忘录")
        value.snapshot = ClipboardSnapshot(items: [first, second, third], pinboards: [
            Pinboard(name: "项目资料", colorHex: "#6495ED", itemIDs: [first.id, second.id, third.id]),
            Pinboard(name: "报价", colorHex: "#E5A44A", itemIDs: [first.id, second.id])
        ])
        value.snapshot.preferences.pasteToFrontmost = false
        value.persist(); value.flushPersistence()
        value.startLocalKnowledge()
        value.toolConfiguration = .init()
        value.toolConfiguration.aiServices = [AIServiceConfig(name: "本地验收示例", vendor: .ollama)]
        value.select(first); value.select(second, extend: true)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let previewScreen = NSRect(x: screen.midX - 640, y: screen.minY + 40, width: 1280, height: screen.height - 80)
        let frame = PanelPresentation.visibleFrame(on: previewScreen)
        let panel = ClipboardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pasteboard 本地知识验收"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = PanelGlassContainer.make(content: PastePanelView(model: value), frame: NSRect(origin: .zero, size: frame.size))
        let frameAnimator = PanelFrameAnimator()
        value.onSuggestionPanelChange = { [weak panel, weak value] _ in
            guard let panel, let value else { return }
            let expanded = value.suggestionStripAvailable
            frameAnimator.animate(panel, to: PanelPresentation.visibleFrame(on: previewScreen, suggestionsVisible: expanded, additionalHeight: value.suggestionAdditionalHeight),
                                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        value.onSuggestionPreview = { [weak value] result in
            guard let value else { return }
            presentationOwner?.previewHidePanel()
            resultWindow?.close()
            let resultPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            resultPanel.title = result.title; resultPanel.isReleasedWhenClosed = false
            resultPanel.contentView = NSHostingView(rootView: ContextSuggestionResultPreview(model: value, result: result))
            resultWindow = resultPanel
            resultPanel.center(); resultPanel.makeKeyAndOrderFront(nil)
        }
        value.onHistoryManagementPreview = { preview in
            resultWindow?.close()
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "搜索操作"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HistorySearchManagementView(model: value, preview: preview))
            resultWindow = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
        }
        value.onHistoryManagementClose = { resultWindow?.close() }
        presentationOwner = AppDelegate.presentationPreview(model: value, panel: panel)
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu()
        let hideItem = applicationMenu.addItem(withTitle: "收起面板", action: #selector(AppDelegate.previewHidePanel), keyEquivalent: "w")
        hideItem.target = presentationOwner
        let showItem = applicationMenu.addItem(withTitle: "打开面板", action: #selector(AppDelegate.previewShowPanel), keyEquivalent: "o")
        showItem.target = presentationOwner
        let settingsItem = applicationMenu.addItem(withTitle: "设置…", action: #selector(AppDelegate.previewShowSettings), keyEquivalent: ",")
        settingsItem.target = presentationOwner
        let lightItem = applicationMenu.addItem(withTitle: "浅色验收", action: #selector(AppDelegate.previewLightAppearance), keyEquivalent: "l")
        lightItem.target = presentationOwner
        let darkItem = applicationMenu.addItem(withTitle: "深色验收", action: #selector(AppDelegate.previewDarkAppearance), keyEquivalent: "d")
        darkItem.target = presentationOwner
        applicationMenu.addItem(withTitle: "退出验收", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        value.onPreview = { item in
            sourceWindow?.close()
            let sourcePanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            sourcePanel.title = item.title; sourcePanel.isReleasedWhenClosed = false
            sourcePanel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                Text(item.sourceName).font(.headline)
                Text(item.text).font(.body).textSelection(.enabled)
                Spacer()
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            sourceWindow = sourcePanel
            sourcePanel.center(); sourcePanel.makeKeyAndOrderFront(nil)
        }
        model = value; window = panel
        panel.makeKeyAndOrderFront(nil)
        value.suggestionSessionActive = true
        value.scheduleContextSuggestions()
    }
}
#endif
