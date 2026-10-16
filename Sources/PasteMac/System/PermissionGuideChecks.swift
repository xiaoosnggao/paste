#if DEBUG
import Foundation

@MainActor
enum PermissionGuideChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Permission guide: " + message) }; count += 1
        }
        var probes: [PermissionGuideKind] = [], allowed = false, continued = 0
        let state = PermissionGuideState { kind in probes.append(kind); return allowed }
        try check(probes.isEmpty, "initialization checked privacy permissions")
        state.present(.screenCapture, onContinue: { continued += 1 })
        try check(probes == [.screenCapture] && !state.granted, "screenshot checked wrong permission")
        state.proceed()
        try check(continued == 0, "unauthorized action resumed")
        allowed = true; state.refresh()
        try check(state.granted && continued == 0, "permission polling automatically resumed action")
        state.proceed(); state.proceed()
        try check(continued == 1, "authorized action ran more than once")
        state.present(.selectionTranslation, onContinue: { continued += 10 })
        try check(state.kind == .selectionTranslation, "selection guide retained screenshot instructions")
        state.dismiss(); state.proceed()
        try check(continued == 1, "dismissed action resumed")
        state.present(.directPaste, onContinue: { continued += 100 })
        allowed = false; state.proceed()
        try check(continued == 1 && !state.granted, "revoked permission allowed continuation")
        try check(PermissionGuideKind.screenCapture.settingsTitle.contains("屏幕"), "screenshot points at Accessibility")
        try check(PermissionGuideKind.selectionTranslation.settingsTitle.contains("辅助"), "selection points at screen recording")
        try check(PermissionGuideKind.forError(ScreenshotCoordinator.Failure.permissionRequired) == .screenCapture, "capture permission failure not routed")
        try check(PermissionGuideKind.forError(SelectedTextCapture.CaptureError.permission) == .selectionTranslation, "selection permission failure not routed")
        try check(PermissionGuideKind.forError(ScreenshotCoordinator.Failure.timedOut) == nil, "capture timeout requests privacy access")
        try check(PermissionGuideKind.forError(SelectedTextCapture.CaptureError.noSelection) == nil, "empty selection requests privacy access")
        allowed = true
        state.present(.screenCapture, onContinue: { continued += 1000 })
        state.present(.selectionTranslation, onContinue: { continued += 1 })
        state.proceed()
        try check(continued == 2, "superseded guide resumed stale action")
        return count
    }
}
#endif
