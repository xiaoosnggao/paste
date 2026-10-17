#if DEBUG
import Foundation

@MainActor
enum PermissionGuideChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Permission guide: " + message) }; count += 1
        }
        let demo = AppModel(isDemo: true)
        var demoGuides = 0
        demo.onAccessibilityGuide = { demoGuides += 1 }
        demo.requestDirectPastePermission()
        try check(!demo.pasteEngine.accessibilityChecksEnabled, "demo setup enabled real permission queries")
        try check(demoGuides == 1, "demo setup did not present guide")
        var probes: [PermissionGuideKind] = [], accessibility = false, screen = false, continued = 0
        let state = PermissionGuideState { kind in
            probes.append(kind)
            return kind == .screenCapture ? screen : accessibility
        }
        try check(probes.isEmpty, "initialization queried permissions")
        state.present(.screenCapture) { continued += 1 }
        try check(state.stepNumber == 1 && state.kind == .directPaste, "wizard did not start with shared accessibility permission")
        state.proceed()
        try check(state.stepNumber == 1 && continued == 0, "unverified step advanced")
        accessibility = true; state.refresh()
        try check(state.granted && state.stepNumber == 1 && continued == 0, "polling advanced workflow")
        state.proceed()
        try check(state.stepNumber == 2 && state.kind == .screenCapture && !state.granted, "screen permission skipped")
        screen = true; state.proceed()
        try check(state.isReview && state.stepNumber == 3 && continued == 0, "verification did not show completion review")
        accessibility = false; state.proceed()
        try check(state.stepNumber == 1 && continued == 0, "revoked permission passed completion")
        accessibility = true; state.proceed(); state.proceed(); state.proceed(); state.proceed()
        try check(continued == 1, "completion ran zero or multiple times")
        state.present(.selectionTranslation) { continued += 10 }
        try check(state.kind == .selectionTranslation, "selection context lost")
        state.dismiss(); state.proceed()
        try check(continued == 1, "dismissed workflow resumed")
        state.present(.screenCapture) { continued += 100 }
        state.present(.selectionTranslation) { continued += 1 }
        state.proceed(); state.proceed(); state.proceed()
        try check(continued == 2, "superseded action resumed")
        try check(PermissionGuideKind.screenCapture.settingsTitle.contains("屏幕"), "wrong screenshot destination")
        try check(PermissionGuideKind.selectionTranslation.settingsTitle.contains("辅助"), "wrong selection destination")
        try check(PermissionGuideKind.forError(ScreenshotCoordinator.Failure.permissionRequired) == .screenCapture, "capture routing")
        try check(PermissionGuideKind.forError(SelectedTextCapture.CaptureError.permission) == .selectionTranslation, "selection routing")
        try check(PermissionGuideKind.forError(ScreenshotCoordinator.Failure.timedOut) == nil, "timeout requested permission")
        try check(PermissionGuideKind.forError(SelectedTextCapture.CaptureError.noSelection) == nil, "empty selection requested permission")
        return count
    }
}
#endif
