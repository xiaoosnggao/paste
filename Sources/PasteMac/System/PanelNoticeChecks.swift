#if DEBUG
import AppKit

/// Checks for the panel's typed notices and the legacy `statusMessage` shim.
@MainActor
enum PanelNoticeChecks {
    static func run() async throws -> Int {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: message) }
        }
        try check(PanelNotice(legacyMessage: "已复制") == .copied, "legacy copy text did not map to .copied")
        try check(PanelNotice(legacyMessage: "保存失败") == .error("保存失败"), "legacy message did not map to .error")
        try check(PanelNotice.copied.autoDismissDelay != nil && PanelNotice.info("x").autoDismissDelay != nil,
                  "confirmations must clear themselves")
        try check(PanelNotice.error("x").autoDismissDelay == nil, "errors must wait for the user")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-notice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let model = AppModel(isDemo: true, storageDirectory: directory, bridge: ClipboardBridge(pasteboard: board))
        model.statusMessage = "写入失败"
        try check(model.notice == .error("写入失败") && model.statusMessage == "写入失败", "statusMessage shim lost the message")
        model.statusMessage = nil
        try check(model.notice == nil, "clearing statusMessage did not clear the notice")
        model.copySelected()
        try check(model.notice == .copied && model.statusMessage == "已复制", "copy did not confirm")
        let deadline = Date().addingTimeInterval(5)
        while model.notice != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try check(model.notice == nil, "copy confirmation never dismissed itself")
        return 7
    }
}
#endif
