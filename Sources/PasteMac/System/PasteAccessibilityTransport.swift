import AppKit
import ApplicationServices
import OSLog

/// AX calls can block on another process. Keep them off the UI thread and bound each call.
final class PasteAccessibilityTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gaoxs.pasteboard.paste-accessibility", qos: .userInitiated)
    func restore(_ target: PasteTarget) async -> Result<Void, PasteIssue> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = Self.restoreCapturedFocus(target)
                if case .failure(let issue) = result {
                    Self.logger.error("focus restore rejected target=\(target.bundleID, privacy: .public) pid=\(target.pid) stage=\(String(describing: issue), privacy: .public)")
                }
                continuation.resume(returning: result)
            }
        }
    }
    private static let logger = Logger(subsystem: "com.gaoxs.pasteboard", category: "paste")
    func send(_ target: PasteTarget) async -> Result<Void, PasteIssue> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = Self.sendOnce(target)
                if case .failure(let issue) = result {
                    Self.logger.error("paste rejected target=\(target.bundleID, privacy: .public) pid=\(target.pid) stage=\(String(describing: issue), privacy: .public)")
                }
                continuation.resume(returning: result)
            }
        }
    }
    private static func sendOnce(_ target: PasteTarget) -> Result<Void, PasteIssue> {
        let systemFocusUnavailable: Bool
        switch verifyTargetFocus(target) {
        case .failure(let issue): return .failure(issue)
        case .success(let probe): systemFocusUnavailable = probe == .unavailable
        }
        if let issue = capturedFocusIssue(target) { return .failure(issue) }
        // A missing AX system attribute does not mean the app lost keyboard focus.
        // NSWorkspace and the captured target still agree; avoid another AX menu dependency.
        if systemFocusUnavailable {
            logger.notice("paste using foreground fallback target=\(target.bundleID, privacy: .public) pid=\(target.pid)")
            return postKeyboardPaste(target)
        }
        // Text editors receive their normal paste key directly. AX menu validation may lag window focus.
        if hasEditableFocusedField(target) { return postKeyboardPaste(target) }
        let outcome = pressPasteMenu(target)
        logger.info("paste menu outcome=\(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .pressed: return .success(())
        case .disabled: return .failure(.noEditableTarget)
        case .focusChanged: return .failure(.focusNotRestored)
        case .rejected(let issue): return .failure(issue)
        case .indeterminate: return .failure(.pasteActionUncertain)
        case .unavailable, .timedOut: return postKeyboardPaste(target)
        }
    }
    private static func postKeyboardPaste(_ target: PasteTarget) -> Result<Void, PasteIssue> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityPermissionRequired) }
        if case .failure(let issue) = verifyTargetFocus(target) { return .failure(issue) }
        if let issue = capturedFocusIssue(target) { return .failure(issue) }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .failure(.eventUnavailable) }
        down.flags = .maskCommand; up.flags = .maskCommand
        // AX queries above may have taken time. Recheck the foreground process immediately
        // before posting; postToPid keeps this pair directed at the captured application.
        guard foregroundMatches(target) else { return .failure(.focusNotRestored) }
        guard AXIsProcessTrusted() else { return .failure(.accessibilityPermissionRequired) }
        down.postToPid(target.pid); up.postToPid(target.pid)
        logger.info("paste keyboard dispatched target=\(target.bundleID, privacy: .public) pid=\(target.pid)")
        return .success(())
    }
    static func isEditableTextRole(_ role: String, settable: Bool, enabled: Bool) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) && settable && enabled
    }
    private static func hasEditableFocusedField(_ target: PasteTarget) -> Bool {
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let focused = element(application, attribute: kAXFocusedUIElementAttribute) else { return false }
        AXUIElementSetMessagingTimeout(focused, 0.2)
        var role: CFTypeRef?; var enabled: CFTypeRef?; var writable = DarwinBoolean(false)
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success,
              AXUIElementCopyAttributeValue(focused, kAXEnabledAttribute as CFString, &enabled) == .success,
              AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &writable) == .success,
              let name = role as? String else { return false }
        return isEditableTextRole(name, settable: writable.boolValue, enabled: (enabled as? NSNumber)?.boolValue == true)
    }
    private static func restoreCapturedFocus(_ target: PasteTarget) -> Result<Void, PasteIssue> {
        let issue = restoreFocusSafely(preflight: {
            guard AXIsProcessTrusted() else { return .accessibilityPermissionRequired }
            return foregroundMatches(target) ? nil : .focusNotRestored
        }, captured: { capturedFocusIssue(target) }, raise: {
            if let window = target.focusedWindow {
                AXUIElementSetMessagingTimeout(window, 0.2)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }, focus: {
            if let element = target.focusedElement {
                AXUIElementSetMessagingTimeout(element, 0.2)
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        })
        return issue.map { .failure($0) } ?? .success(())
    }
    /// Re-check before every focus-changing action; a matched target needs no mutation.
    static func restoreFocusSafely(preflight: () -> PasteIssue?, captured: () -> PasteIssue?,
                                   raise: () -> Void, focus: () -> Void) -> PasteIssue? {
        if let issue = preflight() { return issue }
        let initialIssue = captured()
        if let issue = preflight() { return issue }
        guard let initialIssue else { return nil }
        guard initialIssue == .focusNotRestored else { return initialIssue }
        raise()
        if let issue = preflight() { return issue }
        focus()
        if let issue = preflight() { return issue }
        let finalIssue = captured()
        return preflight() ?? finalIssue
    }
    private static func capturedFocusIssue(_ target: PasteTarget) -> PasteIssue? {
        verifyCapturedFocus(probe: { capturedFocus(target) }, wait: { Thread.sleep(forTimeInterval: 0.04) })
    }
    static func verifyCapturedFocus(probe: () -> FocusProbe, wait: () -> Void) -> PasteIssue? {
        for attempt in 0..<3 {
            switch probe() {
            case .matched: return nil
            case .mismatched: return .focusNotRestored
            case .unavailable: if attempt < 2 { wait() }
            }
        }
        return .capturedFocusQueryUnavailable
    }
    private static func capturedFocus(_ target: PasteTarget) -> FocusProbe {
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var unavailable = false
        for (attribute, expected) in [(kAXFocusedWindowAttribute, target.focusedWindow), (kAXFocusedUIElementAttribute, target.focusedElement)] {
            guard let expected else { continue }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
            guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                logger.error("captured focus query unavailable attribute=\(attribute, privacy: .public) ax=\(status.rawValue)")
                unavailable = true
                continue
            }
            let actual = unsafeBitCast(value, to: AXUIElement.self)
            if !CFEqual(expected, actual) { return .mismatched }
        }
        return unavailable ? .unavailable : .matched
    }
    enum FocusProbe { case matched, mismatched, unavailable }
    static func verifySystemFocus(probe: () -> FocusProbe, wait: () -> Void,
                                  foregroundMatches: (() -> Bool)? = nil) -> PasteIssue? {
        for attempt in 0..<3 {
            if let foregroundMatches, !foregroundMatches() { return .focusNotRestored }
            switch probe() {
            case .matched:
                return foregroundMatches?() == false ? .focusNotRestored : nil
            case .mismatched: return .focusNotRestored
            case .unavailable: if attempt < 2 { wait() }
            }
        }
        guard let foregroundMatches else { return .focusQueryUnavailable }
        return foregroundMatches() ? nil : .focusNotRestored
    }
    private static func foregroundMatches(_ target: PasteTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.bundleIdentifier == target.bundleID,
              target.launchDate == nil || app.launchDate == target.launchDate else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }
    private static func verifyTargetFocus(_ target: PasteTarget) -> Result<FocusProbe, PasteIssue> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityPermissionRequired) }
        var lastProbe = FocusProbe.unavailable
        let issue = verifySystemFocus(probe: {
            lastProbe = systemFocus(target.pid)
            return lastProbe
        }, wait: { Thread.sleep(forTimeInterval: 0.04) }, foregroundMatches: { foregroundMatches(target) })
        if let issue { return .failure(issue) }
        return .success(lastProbe)
    }
    private static func systemFocus(_ pid: pid_t) -> FocusProbe {
        let system = AXUIElementCreateSystemWide()
        // This handle sets the process-wide default: use a bounded but usable timeout, not 50 ms.
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            logger.error("system focus query unavailable ax=\(status.rawValue)")
            return .unavailable
        }
        let focused = unsafeBitCast(value, to: AXUIElement.self)
        var actual: pid_t = 0
        let pidStatus = AXUIElementGetPid(focused, &actual)
        guard pidStatus == .success else {
            logger.error("system focus PID query unavailable ax=\(pidStatus.rawValue)")
            return .unavailable
        }
        return actual == pid ? .matched : .mismatched
    }
    enum MenuResult: Equatable {
        case pressed, disabled, unavailable, timedOut, focusChanged, indeterminate
        case rejected(PasteIssue)
        init(actionResult: AXError) { self = actionResult == .success ? .pressed : .indeterminate }
        // A search timeout has never attempted AXPress. Its keyboard fallback revalidates focus.
        // An uncertain AXPress outcome must never be retried, because it may have pasted already.
        var allowsKeyboardFallback: Bool { self == .unavailable || self == .timedOut }
    }
    private static func pressPasteMenu(_ target: PasteTarget) -> MenuResult {
        let pid = target.pid
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let bar = element(application, attribute: kAXMenuBarAttribute) else { return .unavailable }
        var remaining = 150
        func visit(_ node: AXUIElement, depth: Int) -> MenuResult {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
            guard depth <= 4, remaining > 0 else { return .unavailable }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.05)
            var character: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXMenuItemCmdCharAttribute as CFString, &character)
            if (character as? String)?.lowercased() == "v" {
                var modifiers: CFTypeRef?
                AXUIElementCopyAttributeValue(node, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                if (modifiers as? NSNumber)?.intValue == 0 {
                    var enabled: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &enabled) == .success else { return .unavailable }
                    guard (enabled as? NSNumber)?.boolValue == true else { return .disabled }
                    guard AXIsProcessTrusted() else { return .rejected(.accessibilityPermissionRequired) }
                    if case .failure(let issue) = verifyTargetFocus(target) { return .rejected(issue) }
                    if let issue = capturedFocusIssue(target) {
                        return .rejected(issue)
                    }
                    guard foregroundMatches(target) else { return .focusChanged }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
                    guard AXIsProcessTrusted() else { return .rejected(.accessibilityPermissionRequired) }
                    return MenuResult(actionResult: AXUIElementPerformAction(node, kAXPressAction as CFString))
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let values = children as? [AXUIElement] else { return .unavailable }
            for child in values {
                let result = visit(child, depth: depth + 1)
                if result != .unavailable { return result }
            }
            return .unavailable
        }
        return visit(bar, depth: 0)
    }
    static func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
