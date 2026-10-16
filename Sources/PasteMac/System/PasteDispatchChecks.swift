#if DEBUG
import Foundation

/// Exercises only a fake environment: no pasteboard writes, accessibility calls or keyboard events.
@MainActor
enum PasteDispatchChecks {
    @MainActor
    private final class Environment: PasteDispatchEnvironment {
        var accessibilityGranted = true
        var alive = true
        var activationSucceeds = true
        var sendSucceeds = true
        var lastSendIssue: PasteIssue?
        var lastRestoreIssue: PasteIssue?
        var restoreSucceeds = true
        var failOnRestore: Int?
        var focusedPID: pid_t? = 42
        var exitOnSettle = false
        var activateAfterSettles: Int?
        var requireFrontmostForRestore = false
        var revokeAfterSettles: Int?
        var loseFocusAfterSettles: Int?
        var trace: [String] = []
        var sendCount = 0
        var settleCount = 0
        var restoreCount = 0
        func isAlive(_ target: PasteTarget) -> Bool { alive }
        func activate(_ target: PasteTarget) -> Bool { trace.append("activate"); return activationSucceeds }
        func restoreFocus(_ target: PasteTarget) async -> Bool {
            trace.append("restore"); restoreCount += 1
            await Task.yield()
            return restoreSucceeds && failOnRestore != restoreCount && (!requireFrontmostForRestore || focusedPID == target.pid)
        }
        func frontmostPID() -> pid_t? { focusedPID }
        func sendPaste(_ target: PasteTarget) async -> Bool {
            trace.append("send"); sendCount += 1
            await Task.yield()
            return sendSucceeds
        }
        func settle() async {
            trace.append("settle"); settleCount += 1
            if exitOnSettle { alive = false }
            if let activateAfterSettles, settleCount >= activateAfterSettles { focusedPID = 42 }
            if let revokeAfterSettles, settleCount >= revokeAfterSettles { accessibilityGranted = false }
            if let loseFocusAfterSettles, settleCount >= loseFocusAfterSettles { focusedPID = 99 }
            await Task.yield()
        }
    }
    static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Paste dispatch: \(message)") }
            count += 1
        }
        let target = PasteTarget(pid: 42, name: "Fake", bundleID: "test.fake")
        func engine(_ environment: Environment) -> PasteEngine {
            PasteEngine(trackApplications: false, environment: environment, target: target)
        }
        let denied = Environment(); denied.accessibilityGranted = false
        let deniedEngine = engine(denied)
        let deniedResult = await deniedEngine.dispatchPaste { denied.trace.append("close") }
        try check(!deniedResult && deniedEngine.lastIssue == .accessibilityPermissionRequired, "permission denial reason")
        try check(denied.trace.isEmpty && denied.sendCount == 0, "permission denial closed panel or sent event")

        let success = Environment(); let successEngine = engine(success)
        let successful = await successEngine.dispatchPaste {
            success.trace.append("close.begin")
            await Task.yield()
            success.trace.append("close.end")
        }
        try check(successful && successEngine.lastIssue == nil, "successful dispatch reported failure")
        try check(success.sendCount == 1, "successful dispatch must send exactly once")
        let closedIndex = success.trace.firstIndex(of: "close.end")!
        let activatedIndex = success.trace.firstIndex(of: "activate")!
        let restoredIndex = success.trace.lastIndex(of: "restore")!
        let sentIndex = success.trace.firstIndex(of: "send")!
        try check(closedIndex < activatedIndex && activatedIndex < restoredIndex && restoredIndex < sentIndex,
                  "activation or send preceded completed panel close and focus restoration")
        try check(success.restoreCount == 2, "saved window focus must be restored after activation and revalidated before sending")

        let delayed = Environment()
        delayed.focusedPID = 99
        delayed.activateAfterSettles = 3
        delayed.requireFrontmostForRestore = true
        let delayedEngine = engine(delayed)
        let delayedResult = await delayedEngine.dispatchPaste { delayed.trace.append("close") }
        try check(delayedResult && delayed.sendCount == 1, "asynchronous application activation was rejected before settling")
        let delayedFirstRestore = delayed.trace.firstIndex(of: "restore")
        try check(delayedFirstRestore != nil && delayed.trace.prefix(delayedFirstRestore!).filter { $0 == "settle" }.count == 3,
                  "captured focus restored before target application became frontmost")

        let revoked = Environment(); let revokedEngine = engine(revoked)
        let revokedResult = await revokedEngine.dispatchPaste {
            revoked.trace.append("close")
            revoked.accessibilityGranted = false
        }
        try check(!revokedResult && revokedEngine.lastIssue == .accessibilityPermissionRequired, "permission revoked during panel close reason")
        try check(revoked.sendCount == 0, "permission revoked during panel close still sent")

        for stage in 1...3 {
            let settlingRevocation = Environment(); settlingRevocation.revokeAfterSettles = stage
            let settlingRevocationEngine = engine(settlingRevocation)
            let result = await settlingRevocationEngine.dispatchPaste { settlingRevocation.trace.append("close") }
            try check(!result && settlingRevocationEngine.lastIssue == .accessibilityPermissionRequired,
                      "permission revocation during activation/focus settle \(stage) was not detected")
            try check(settlingRevocation.sendCount == 0, "permission revocation during settle \(stage) still sent")
        }

        let changedFocus = Environment(); changedFocus.loseFocusAfterSettles = 2
        let changedFocusEngine = engine(changedFocus)
        let changedFocusResult = await changedFocusEngine.dispatchPaste { changedFocus.trace.append("close") }
        try check(!changedFocusResult && changedFocusEngine.lastIssue == .focusNotRestored && changedFocus.sendCount == 0,
                  "target losing activation during captured-focus settle still received paste")

        let failedRestore = Environment(); failedRestore.restoreSucceeds = false
        let failedRestoreEngine = engine(failedRestore)
        let failedRestoreResult = await failedRestoreEngine.dispatchPaste { failedRestore.trace.append("close") }
        try check(!failedRestoreResult && failedRestoreEngine.lastIssue == .focusNotRestored, "failed initial focus restoration reason")
        try check(failedRestore.restoreCount == 1 && failedRestore.sendCount == 0, "failed initial focus restoration retried or sent")
        let unreadableRestore = Environment(); unreadableRestore.restoreSucceeds = false
        unreadableRestore.lastRestoreIssue = .capturedFocusQueryUnavailable
        let unreadableRestoreEngine = engine(unreadableRestore)
        let unreadableRestoreResult = await unreadableRestoreEngine.dispatchPaste {}
        try check(!unreadableRestoreResult && unreadableRestoreEngine.lastIssue == .capturedFocusQueryUnavailable && unreadableRestore.sendCount == 0,
                  "captured-focus query issue was swallowed by engine")

        let lostFocus = Environment(); lostFocus.failOnRestore = 2
        let lostFocusEngine = engine(lostFocus)
        let lostFocusResult = await lostFocusEngine.dispatchPaste { lostFocus.trace.append("close") }
        try check(!lostFocusResult && lostFocusEngine.lastIssue == .focusNotRestored, "failed focus revalidation reason")
        try check(lostFocus.restoreCount == 2 && lostFocus.sendCount == 0, "failed focus revalidation still sent")

        let unfocused = Environment(); unfocused.focusedPID = 99
        let unfocusedEngine = engine(unfocused)
        let unfocusedResult = await unfocusedEngine.dispatchPaste { unfocused.trace.append("close") }
        try check(!unfocusedResult && unfocusedEngine.lastIssue == .focusNotRestored, "focus failure reason")
        try check(unfocused.sendCount == 0, "wrong frontmost application still received paste")
        try check(unfocused.settleCount == 15, "focus retry loop must be bounded")

        let activation = Environment(); activation.activationSucceeds = false
        let activationEngine = engine(activation)
        let activationResult = await activationEngine.dispatchPaste { activation.trace.append("close") }
        try check(!activationResult && activationEngine.lastIssue == .focusNotRestored, "activation failure reason")
        try check(activation.sendCount == 0 && activation.settleCount == 0, "activation failure proceeded to dispatch")

        let exited = Environment(); exited.alive = false
        let exitedEngine = engine(exited)
        let exitedResult = await exitedEngine.dispatchPaste { exited.trace.append("close") }
        try check(!exitedResult && exitedEngine.lastIssue == .targetUnavailable, "already exited target reason")
        try check(exited.trace.isEmpty && exited.sendCount == 0, "exited target closed panel or sent event")

        let closingExit = Environment(); let closingEngine = engine(closingExit)
        let closingResult = await closingEngine.dispatchPaste { closingExit.trace.append("close"); closingExit.alive = false }
        try check(!closingResult && closingEngine.lastIssue == .targetUnavailable, "target exit during panel close reason")
        try check(closingExit.trace == ["close"] && closingExit.sendCount == 0, "target exit during close still activated or sent")

        let settlingExit = Environment(); settlingExit.exitOnSettle = true
        let settlingEngine = engine(settlingExit)
        let settlingResult = await settlingEngine.dispatchPaste { settlingExit.trace.append("close") }
        try check(!settlingResult && settlingEngine.lastIssue == .focusNotRestored, "target exit during settling did not fail safely")
        try check(settlingExit.sendCount == 0, "target exit during settling still sent")

        let failedSend = Environment(); failedSend.sendSucceeds = false
        let failedSendEngine = engine(failedSend)
        let failedSendResult = await failedSendEngine.dispatchPaste { failedSend.trace.append("close") }
        try check(!failedSendResult && failedSendEngine.lastIssue == .eventUnavailable, "send failure reason")
        try check(failedSend.sendCount == 1 && failedSend.trace.last == "send", "send failure must not retry or duplicate")
        let disabled = Environment(); disabled.sendSucceeds = false; disabled.lastSendIssue = .noEditableTarget
        let disabledEngine = engine(disabled)
        let disabledResult = await disabledEngine.dispatchPaste {}
        try check(!disabledResult && disabledEngine.lastIssue == .noEditableTarget, "specific disabled-input reason was swallowed")

        let missing = Environment()
        let missingEngine = PasteEngine(trackApplications: false, environment: missing)
        let missingResult = await missingEngine.dispatchPaste { missing.trace.append("close") }
        try check(!missingResult && missingEngine.lastIssue == .noTarget, "missing target reason")
        try check(missing.trace.isEmpty && missing.sendCount == 0, "missing target caused side effects")
        return count
    }
}
#endif
