import Foundation
import Combine

enum PermissionGuideKind: Equatable {
    case directPaste, selectionTranslation, screenCapture
    var title: String {
        switch self {
        case .directPaste: return "开启直接粘贴"
        case .selectionTranslation: return "开启选中文字翻译"
        case .screenCapture: return "开启截图识别与翻译"
        }
    }
    var destination: String { self == .screenCapture ? "屏幕与系统音频录制" : "辅助功能" }
    var settingsTitle: String { self == .screenCapture ? "打开屏幕录制设置" : "打开辅助功能设置" }
    var instructions: String {
        switch self {
        case .directPaste: return "在辅助功能列表中添加并开启 Pasteboard，即可双击卡片或按回车粘贴。"
        case .selectionTranslation: return "在辅助功能列表中添加并开启 Pasteboard。仅在启动选中文字翻译时读取所选文本。"
        case .screenCapture: return "在屏幕录制列表中添加并开启 Pasteboard。截图仅包含框选区域。"
        }
    }
    var continueTitle: String {
        switch self { case .directPaste: return "完成"; case .selectionTranslation: return "继续翻译"; case .screenCapture: return "继续截图" }
    }
    static func forError(_ error: Error) -> Self? {
        if let error = error as? ScreenshotCoordinator.Failure, case .permissionRequired = error { return .screenCapture }
        if let error = error as? SelectedTextCapture.CaptureError, case .permission = error { return .selectionTranslation }
        return nil
    }
}

/// No permission probes on initialization. Polling never resumes the user's action.
@MainActor
final class PermissionGuideState: ObservableObject {
    @Published private(set) var kind: PermissionGuideKind = .directPaste
    @Published private(set) var granted = false
    private var active = false
    private let check: (PermissionGuideKind) -> Bool
    private var continuation: (() -> Void)?
    init(check: @escaping (PermissionGuideKind) -> Bool) { self.check = check }
    func present(_ kind: PermissionGuideKind, onContinue: @escaping () -> Void) {
        self.kind = kind; continuation = onContinue; active = true; refresh()
    }
    func refresh() { if active { granted = check(kind) } }
    func proceed() {
        guard active else { return }
        refresh()
        guard granted else { return }
        let action = continuation; continuation = nil
        action?()
    }
    func dismiss() { active = false; continuation = nil }
}
