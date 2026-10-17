#if DEBUG
import Foundation

@MainActor
enum PermissionRepairChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Permission repair: " + message) }; count += 1
        }
        let bundle = "com.gaoxs.pasteboard"
        let accessibility = try PermissionRepair.arguments(for: .directPaste, bundleID: bundle)
        try check(accessibility == ["reset", "Accessibility", bundle], "reset is not scoped to current app and permission")
        let selection = try PermissionRepair.arguments(for: .selectionTranslation, bundleID: bundle)
        try check(selection == accessibility, "selection resets a separate permission")
        let screen = try PermissionRepair.arguments(for: .screenCapture, bundleID: bundle)
        try check(screen == ["reset", "ScreenCapture", bundle], "wrong screenshot reset scope")
        let screenStep = PermissionGuideState { $0 != .screenCapture }
        screenStep.present(.screenCapture) {}
        screenStep.proceed()
        let repairedPermission = PermissionRepairKindRecorder()
        var screenSettingsOpened = 0
        screenStep.repair(using: { kind in await repairedPermission.record(kind) }, onRepaired: { screenSettingsOpened += 1 })
        for _ in 0..<50 where screenStep.repairing { try await Task.sleep(nanoseconds: 1_000_000) }
        let resetKind = await repairedPermission.value
        try check(resetKind == .screenCapture && screenSettingsOpened == 1 && !screenStep.granted,
                  "screen step did not reset ScreenCapture or incorrectly granted permission")
        for invalid in ["", "*", "com.example; echo unsafe", "com.example\nother"] {
            do { _ = try PermissionRepair.arguments(for: .directPaste, bundleID: invalid); throw SystemChecks.Failure(message: "accepted unsafe bundle ID") }
            catch is PermissionRepair.Failure { count += 1 }
        }
        var allowed = false, opened = 0
        let state = PermissionGuideState { _ in allowed }
        state.present(.directPaste) {}
        state.repair(using: { _ in }, onRepaired: { opened += 1 })
        for _ in 0..<50 where state.repairing { try await Task.sleep(nanoseconds: 1_000_000) }
        try check(opened == 1 && state.repairMessage != nil && !state.granted, "repair granted access or failed to guide reauthorization")
        state.present(.screenCapture) {}
        state.repair(using: { _ in throw PermissionRepair.Failure.resetFailed }, onRepaired: { opened += 1 })
        for _ in 0..<50 where state.repairing { try await Task.sleep(nanoseconds: 1_000_000) }
        try check(opened == 1 && state.repairMessage != nil && !state.repairing, "failed repair opened settings or stayed busy")
        state.present(.directPaste) {}
        state.repair(using: { _ in try? await Task.sleep(nanoseconds: 10_000_000) }, onRepaired: { opened += 100 })
        allowed = true; state.proceed()
        try check(state.stepNumber == 1, "step advanced during reset")
        state.dismiss()
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(opened == 1 && !state.repairing && state.repairMessage == nil, "dismissed repair presented stale UI")
        state.present(.directPaste) {}
        state.repair(using: { _ in }, onRepaired: { opened += 100 })
        await Task.yield()
        try check(opened == 1 && !state.repairing, "granted permission was reset")
        allowed = false
        let starts = PermissionRepairStartCounter()
        state.present(.directPaste) {}
        state.repair(using: { _ in await starts.mark() }, onRepaired: { opened += 100 })
        state.dismiss()
        try await Task.sleep(nanoseconds: 10_000_000)
        let started = await starts.value
        try check(started == 0, "dismissed pending operation still started")
        return count
    }
}
private actor PermissionRepairStartCounter {
    private(set) var value = 0
    func mark() { value += 1 }
}
private actor PermissionRepairKindRecorder {
    private(set) var value: PermissionGuideKind?
    func record(_ kind: PermissionGuideKind) { value = kind }
}
#endif
