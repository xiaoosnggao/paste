import AppKit
import ApplicationServices

// Dispatch reasons stay distinct; callers treat missing destinations as copy-only.
enum PasteIssue: Equatable, Error {
    case accessibilityPermissionRequired, noTarget, targetUnavailable, focusNotRestored, eventUnavailable
    case focusQueryUnavailable, capturedFocusQueryUnavailable, noEditableTarget, pasteActionUncertain
    var usesCopyOnlyFallback: Bool { self == .noTarget || self == .noEditableTarget }
    var message: String {
        switch self {
        case .accessibilityPermissionRequired: return "内容已复制。请开启辅助功能权限以使用直接粘贴。"
        case .noTarget: return "已复制"
        case .targetUnavailable: return "目标应用已退出。内容已复制，可在其他应用中按 ⌘V 粘贴。"
        case .focusNotRestored: return "无法切回目标输入框。内容已复制，请点击输入框后按 ⌘V 粘贴。"
        case .eventUnavailable: return "无法完成直接粘贴。内容已复制，请按 ⌘V 粘贴。"
        case .focusQueryUnavailable: return "无法确认当前输入位置。内容已复制，请点击输入框后按 ⌘V 粘贴。"
        case .capturedFocusQueryUnavailable: return "无法确认目标输入框。内容已复制，请点击输入框后按 ⌘V 粘贴。"
        case .noEditableTarget: return "已复制"
        case .pasteActionUncertain: return "无法确认粘贴是否完成。请先检查输入框，以免重复粘贴。"
        }
    }
}

struct PasteTarget {
    let pid: pid_t
    let name: String
    let bundleID: String
    var launchDate: Date? = nil
    var focusedWindow: AXUIElement? = nil
    var focusedElement: AXUIElement? = nil
}

@MainActor
protocol PasteDispatchEnvironment {
    var accessibilityGranted: Bool { get }
    func isAlive(_ target: PasteTarget) -> Bool
    func activate(_ target: PasteTarget) -> Bool
    func restoreFocus(_ target: PasteTarget) async -> Bool
    func frontmostPID() -> pid_t?
    func sendPaste(_ target: PasteTarget) async -> Bool
    var lastSendIssue: PasteIssue? { get }
    var lastRestoreIssue: PasteIssue? { get }
    func settle() async
}
extension PasteDispatchEnvironment {
    var lastSendIssue: PasteIssue? { nil }
    var lastRestoreIssue: PasteIssue? { nil }
}

@MainActor
final class NativePasteEnvironment: PasteDispatchEnvironment {
    private(set) var lastSendIssue: PasteIssue?
    private(set) var lastRestoreIssue: PasteIssue?
    private(set) var accessibilityChecksEnabled = false
    private let trustCheck: () -> Bool
    init(trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.trustCheck = trustCheck }
    func enableAccessibilityChecks() { accessibilityChecksEnabled = true }
    var accessibilityGranted: Bool { accessibilityChecksEnabled && trustCheck() }
    func isAlive(_ target: PasteTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.bundleIdentifier == target.bundleID else { return false }
        return target.launchDate == nil || app.launchDate == target.launchDate
    }
    func activate(_ target: PasteTarget) -> Bool {
        if frontmostPID() == target.pid { return true }
        return NSRunningApplication(processIdentifier: target.pid)?.activate() ?? false
    }
    private let transport = PasteAccessibilityTransport()
    func restoreFocus(_ target: PasteTarget) async -> Bool {
        switch await transport.restore(target) {
        case .success: lastRestoreIssue = nil; return true
        case .failure(let issue): lastRestoreIssue = issue; return false
        }
    }
    func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func settle() async { try? await Task.sleep(nanoseconds: 35_000_000) }
    func sendPaste(_ target: PasteTarget) async -> Bool {
        switch await transport.send(target) {
        case .success: lastSendIssue = nil; return true
        case .failure(let issue): lastSendIssue = issue; return false
        }
    }

}

@MainActor
final class PasteEngine {
    var onTargetChange: (() -> Void)?
    private(set) var target: PasteTarget?
    private(set) var lastIssue: PasteIssue?
    private let environment: PasteDispatchEnvironment
    private var activationObserver: NSObjectProtocol?
    var accessibilityChecksEnabled: Bool { (environment as? NativePasteEnvironment)?.accessibilityChecksEnabled ?? true }
    var accessibilityGranted: Bool { environment.accessibilityGranted }
    func enableAccessibilityChecks() { (environment as? NativePasteEnvironment)?.enableAccessibilityChecks() }

    init(trackApplications: Bool = true, environment: PasteDispatchEnvironment? = nil, target: PasteTarget? = nil) {
        self.environment = environment ?? NativePasteEnvironment()
        self.target = target
        guard trackApplications else { return }
        rememberTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rememberTarget() } }
    }
    func rememberTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              !(app.bundleIdentifier?.hasPrefix("com.gaoxs.pasteboard") ?? false),
              app.bundleIdentifier != "com.apple.systempreferences", let bundle = app.bundleIdentifier else { return }
        target = PasteTarget(pid: app.processIdentifier, name: app.localizedName ?? "目标应用", bundleID: bundle, launchDate: app.launchDate)
        if environment.accessibilityGranted, var value = target, environment.isAlive(value) {
            let application = AXUIElementCreateApplication(value.pid)
            AXUIElementSetMessagingTimeout(application, 0.08)
            value.focusedWindow = PasteAccessibilityTransport.element(application, attribute: kAXFocusedWindowAttribute)
            value.focusedElement = PasteAccessibilityTransport.element(application, attribute: kAXFocusedUIElementAttribute)
            target = value
        }
        onTargetChange?()
    }
    func restoreTarget() {
        guard let target, environment.isAlive(target) else { return }
        _ = environment.activate(target)
        if environment.accessibilityGranted {
            Task {
                for _ in 0..<15 {
                    await environment.settle()
                    if environment.frontmostPID() == target.pid { break }
                }
                guard environment.accessibilityGranted, environment.isAlive(target), environment.frontmostPID() == target.pid else { return }
                _ = await environment.restoreFocus(target)
            }
        }
    }
    deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) } }

    func dispatchPaste(closePanel: () async -> Void) async -> Bool {
        lastIssue = nil
        guard let target else { lastIssue = .noTarget; return false }
        guard environment.isAlive(target) else { lastIssue = .targetUnavailable; return false }
        guard environment.accessibilityGranted else { lastIssue = .accessibilityPermissionRequired; return false }
        await closePanel()
        guard environment.accessibilityGranted else { lastIssue = .accessibilityPermissionRequired; return false }
        guard environment.isAlive(target) else { lastIssue = .targetUnavailable; return false }
        guard environment.activate(target) else { lastIssue = .focusNotRestored; return false }
        // Activation is a request: the old application's AX focus may remain until it settles.
        for _ in 0..<15 {
            await environment.settle()
            if environment.frontmostPID() == target.pid { break }
        }
        guard environment.accessibilityGranted else { lastIssue = .accessibilityPermissionRequired; return false }
        guard environment.isAlive(target), environment.frontmostPID() == target.pid else { lastIssue = .focusNotRestored; return false }
        guard await environment.restoreFocus(target) else { lastIssue = environment.lastRestoreIssue ?? .focusNotRestored; return false }
        await environment.settle()
        guard environment.accessibilityGranted else { lastIssue = .accessibilityPermissionRequired; return false }
        guard environment.isAlive(target), environment.frontmostPID() == target.pid else { lastIssue = .focusNotRestored; return false }
        guard await environment.restoreFocus(target) else { lastIssue = environment.lastRestoreIssue ?? .focusNotRestored; return false }
        await environment.settle()
        guard environment.accessibilityGranted else { lastIssue = .accessibilityPermissionRequired; return false }
        guard environment.isAlive(target), environment.frontmostPID() == target.pid else {
            lastIssue = .focusNotRestored; return false
        }
        guard await environment.sendPaste(target) else { lastIssue = environment.lastSendIssue ?? .eventUnavailable; return false }
        return true
    }
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
