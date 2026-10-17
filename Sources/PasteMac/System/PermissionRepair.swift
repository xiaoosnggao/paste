import Foundation

/// Only invoked after the user confirms repair of this app's current permission.
/// Does not grant access or touch any other application's records.
enum PermissionRepair {
    enum Failure: LocalizedError {
        case unavailable, resetFailed
        var errorDescription: String? {
            "无法修复旧授权，请在系统设置中移除 Pasteboard 后重新添加。"
        }
    }
    static func arguments(for kind: PermissionGuideKind, bundleID: String) throws -> [String] {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255,
              bundleID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { throw Failure.unavailable }
        return ["reset", kind == .screenCapture ? "ScreenCapture" : "Accessibility", bundleID]
    }
    static func reset(_ kind: PermissionGuideKind) async throws {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.hasSuffix(".demo") else { throw Failure.unavailable }
        let arguments = try arguments(for: kind, bundleID: bundleID)
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw Failure.resetFailed }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.resetFailed }
        }
        // Cancellation can stop a pending reset, but cannot undo one already started.
        try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
