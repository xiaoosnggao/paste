import AppKit
import ApplicationServices

/// Reads only an explicit user selection. Does not ask for or change system permissions.
@MainActor
final class SelectedTextCapture {
    enum CaptureError: LocalizedError {
        case permission, noTarget, changedTarget, secureField, noSelection, clipboardUnavailable, tooLarge, dispatch
        var errorDescription: String? {
            switch self {
            case .permission: return "选中文字翻译需要辅助功能权限，请在系统设置中为 Pasteboard 开启权限。"
            case .noTarget: return "请先在其他应用中选中文字，再按选中文字翻译快捷键。"
            case .changedTarget: return "当前应用已切换。请重新选中文字并翻译。"
            case .secureField: return "不支持翻译密码输入框中的内容。"
            case .noSelection: return "未读取到所选文字。请重新选择，或复制后使用剪贴板翻译。"
            case .clipboardUnavailable: return "无法保留当前剪贴板内容。请复制所选文字后使用剪贴板翻译。"
            case .tooLarge: return "选中文字过长，请缩小选择范围后重试。"
            case .dispatch: return "无法复制所选文字。请手动复制后使用剪贴板翻译。"
            }
        }
    }
    enum AXSelection: Sendable { case text(String), unavailable, secureField }
    struct ClipboardState {
        let count: Int
        let items: [[String: Data]]
    }
    struct Dependencies {
        var trusted: () -> Bool
        var ownPID: pid_t
        var frontmostPID: () -> pid_t?
        var selectedText: (pid_t) async -> AXSelection
        var snapshot: () throws -> ClipboardState
        var changeCount: () -> Int
        var text: () -> String?
        var restore: (ClipboardState, Int) -> Void
        var copy: (pid_t) -> Bool
        var pause: () async throws -> Void
    }
    private let dependencies: Dependencies
    init(dependencies: Dependencies? = nil) { self.dependencies = dependencies ?? Self.liveDependencies() }

    func capture() async throws -> String {
        let env = dependencies
        guard env.trusted() else { throw CaptureError.permission }
        guard let pid = env.frontmostPID(), pid != env.ownPID else { throw CaptureError.noTarget }
        try Task.checkCancellation()
        let selection = await env.selectedText(pid)
        try Task.checkCancellation()
        guard env.frontmostPID() == pid else { throw CaptureError.changedTarget }
        switch selection {
        case .secureField: throw CaptureError.secureField
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try Self.validated(text) }
        case .unavailable: break
        }
        // Some web views and chat apps do not expose AXSelectedText. Copy only after
        // preserving every current pasteboard representation, and never replace a newer copy.
        let saved = try env.snapshot()
        guard env.frontmostPID() == pid else { throw CaptureError.changedTarget }
        guard env.copy(pid) else { throw CaptureError.dispatch }
        var observedCopy: Int?
        defer { if let observedCopy { env.restore(saved, observedCopy) } }
        for _ in 0..<30 {
            try await env.pause()
            try Task.checkCancellation()
            guard env.frontmostPID() == pid else { throw CaptureError.changedTarget }
            let count = env.changeCount()
            guard count != saved.count else { continue }
            observedCopy = count
            // Let promised pasteboard representations settle. If another copy occurs,
            // do not restore or translate its content as if it belonged to our action.
            try await env.pause()
            try Task.checkCancellation()
            guard env.frontmostPID() == pid else { throw CaptureError.changedTarget }
            guard env.changeCount() == count else { throw CaptureError.noSelection }
            guard let text = env.text(), env.changeCount() == count else { throw CaptureError.noSelection }
            return try Self.validated(text)
        }
        throw CaptureError.noSelection
    }
    static func validated(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.noSelection }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw CaptureError.tooLarge }
        return text
    }
    private static func liveDependencies() -> Dependencies {
        let board = NSPasteboard.general
        return Dependencies(trusted: { AXIsProcessTrusted() }, ownPID: getpid(),
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            selectedText: { pid in
                await Task.detached(priority: .userInitiated) { readSelection(pid: pid) }.value
            }, snapshot: { try snapshot(board) }, changeCount: { board.changeCount },
            text: { board.string(forType: .string) }, restore: { saved, expected in restore(saved, to: board, expectedCount: expected) },
            copy: { pid in
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return false }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.postToPid(pid); up.postToPid(pid)
                return true
            }, pause: { try await Task.sleep(nanoseconds: 30_000_000) })
    }
    nonisolated private static func readSelection(pid: pid_t) -> AXSelection {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == "AXSecureTextField" { return .secureField }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return .unavailable }
        return .text(text)
    }
    static func snapshot(_ board: NSPasteboard) throws -> ClipboardState {
        let count = board.changeCount
        var size = 0
        var values: [[String: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw CaptureError.clipboardUnavailable }
                size += data.count
                guard size <= 16 * 1024 * 1024 else { throw CaptureError.clipboardUnavailable }
                representations[type.rawValue] = data
            }
            values.append(representations)
        }
        guard board.changeCount == count else { throw CaptureError.clipboardUnavailable }
        return ClipboardState(count: count, items: values)
    }
    static func restore(_ saved: ClipboardState, to board: NSPasteboard, expectedCount: Int) {
        guard board.changeCount == expectedCount else { return }
        let items = saved.items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: .init(type)) }
            return item
        }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}
