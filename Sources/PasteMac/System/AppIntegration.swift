import AppKit
import AppIntents
import PasteCore

@MainActor
final class AppIntegration {
    static let shared = AppIntegration()
    weak var model: AppModel?
    var openPanel: (() -> Void)?
    enum Failure: LocalizedError {
        case unavailable, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "请打开 Pasteboard 后重试。"
            case .rejected(let message): return message
            }
        }
    }
    func run(_ command: DeepLinkCommand) throws {
        guard let model else { throw Failure.unavailable }
        switch command {
        case .open: openPanel?()
        case .search(let query): model.queryString = query; model.isSearchVisible = true; model.selectedPinboardID = nil; model.selectFirstIfNeeded(); openPanel?()
        case .add(let text, let title):
            guard !model.isPasting else { throw Failure.rejected("正在粘贴，请稍后重试。") }
            guard model.saveText(text, title: title, item: nil) else { throw Failure.rejected(model.statusMessage ?? "保存失败。") }
        case .copy(let id):
            guard !model.isPasting else { throw Failure.rejected("正在粘贴，请稍后重试。") }
            guard let item = model.snapshot.items.first(where: { $0.id == id }) else { throw Failure.rejected("此项目已删除或过期。") }
            try model.bridge.write([item], plainText: false)
            model.statusMessage = "项目已复制"
        }
    }
    func receive(_ url: URL) {
        do {
            let command = try DeepLinkParser.parse(url)
            switch command {
            case .add, .copy:
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = command.isAdd ? "允许通过外部链接添加文本？" : "允许通过外部链接复制此项目？"
                alert.informativeText = "此操作来自外部链接，内容不会自动粘贴到其他应用。"
                alert.addButton(withTitle: "允许"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            default: break
            }
            try run(command)
        } catch { model?.statusMessage = error.localizedDescription; openPanel?() }
    }
}
private extension DeepLinkCommand {
    var isAdd: Bool { if case .add = self { return true }; return false }
}

struct OpenClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "打开剪贴板"
    static var description = IntentDescription("打开 Pasteboard 剪贴板面板。")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { try AppIntegration.shared.run(.open); return .result() }
}
struct SearchClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索剪贴板"
    static var description = IntentDescription("搜索剪贴板历史并显示结果。")
    static var openAppWhenRun = true
    @Parameter(title: "搜索内容") var query: String
    @MainActor func perform() async throws -> some IntentResult {
        guard query.utf8.count <= 1024 else { throw AppIntegration.Failure.rejected("搜索内容过长。") }
        try AppIntegration.shared.run(.search(query)); return .result()
    }
}
struct AddClipboardTextIntent: AppIntent {
    static var title: LocalizedStringResource = "添加文本到剪贴板历史"
    static var description = IntentDescription("将文本保存到剪贴板历史。")
    static var openAppWhenRun = true
    @Parameter(title: "文本") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        try AppIntegration.shared.run(.add(text: text, title: "来自快捷指令")); return .result()
    }
}
struct CopyLatestClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "复制最新剪贴板项目"
    static var description = IntentDescription("将最新的历史记录复制到剪贴板。")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let id = AppIntegration.shared.model?.snapshot.items.first?.id else { throw AppIntegration.Failure.rejected("历史记录为空。") }
        try AppIntegration.shared.run(.copy(id)); return .result()
    }
}
struct PasteboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenClipboardIntent(), phrases: ["打开 \(.applicationName) 剪贴板"], shortTitle: "打开剪贴板", systemImageName: "square.stack")
        AppShortcut(intent: SearchClipboardIntent(), phrases: ["在 \(.applicationName) 搜索剪贴板"], shortTitle: "搜索剪贴板", systemImageName: "magnifyingglass")
        AppShortcut(intent: AddClipboardTextIntent(), phrases: ["使用 \(.applicationName) 添加文本"], shortTitle: "添加文本", systemImageName: "plus.square")
        AppShortcut(intent: CopyLatestClipboardIntent(), phrases: ["复制 \(.applicationName) 最新项目"], shortTitle: "复制最新项目", systemImageName: "doc.on.doc")
    }
}
