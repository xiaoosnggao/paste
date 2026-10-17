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
        case .directPaste: return "在“辅助功能”中添加并开启 Pasteboard。"
        case .selectionTranslation: return "在“辅助功能”中添加并开启 Pasteboard。"
        case .screenCapture: return "在“屏幕录制”中添加并开启 Pasteboard。"
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

/// Explicit setup only. Checking a step never advances or resumes an action.
@MainActor
final class PermissionGuideState: ObservableObject {
    @Published private(set) var kind: PermissionGuideKind = .directPaste
    @Published private(set) var granted = false
    @Published private(set) var stepNumber = 1
    @Published private(set) var repairing = false
    @Published private(set) var repairMessage: String?
    private var repairTask: Task<Void, Never>?
    private var generation = UUID()
    var isReview: Bool { stepNumber == 3 }
    private var steps: [PermissionGuideKind] = [.directPaste, .screenCapture]
    private var active = false
    private let check: (PermissionGuideKind) -> Bool
    private var continuation: (() -> Void)?
    init(check: @escaping (PermissionGuideKind) -> Bool) { self.check = check }
    func present(_ kind: PermissionGuideKind, onContinue: @escaping () -> Void) {
        cancelRepair()
        steps = [kind == .selectionTranslation ? .selectionTranslation : .directPaste, .screenCapture]
        self.kind = steps[0]; stepNumber = 1
        continuation = onContinue; active = true; refresh()
    }
    func refresh() {
        guard active else { return }
        granted = isReview ? steps.allSatisfy(check) : check(kind)
    }
    func proceed() {
        guard active, !repairing else { return }
        if isReview {
            if let missing = steps.firstIndex(where: { !check($0) }) {
                stepNumber = missing + 1; kind = steps[missing]; refresh(); return
            }
            let action = continuation
            continuation = nil; active = false
            action?()
            return
        }
        refresh()
        guard granted else { return }
        stepNumber += 1
        if !isReview { kind = steps[stepNumber - 1] }
        refresh()
    }
    func repair(using operation: @escaping @Sendable (PermissionGuideKind) async throws -> Void,
                onRepaired: @escaping () -> Void) {
        guard active, !isReview, !granted, !repairing else { return }
        repairing = true; repairMessage = nil
        let token = generation, permission = kind
        repairTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.active == true, self?.generation == token else { return }
                try await operation(permission)
                try Task.checkCancellation()
                guard let self, self.active, self.generation == token else { return }
                self.repairing = false; self.repairTask = nil
                self.repairMessage = "旧授权已清除，请重新开启。"
                self.refresh()
                onRepaired()
            } catch {
                guard let self, self.active, self.generation == token else { return }
                self.repairing = false; self.repairTask = nil
                self.repairMessage = error.localizedDescription
            }
        }
    }
    private func cancelRepair() {
        generation = UUID(); repairTask?.cancel(); repairTask = nil
        repairing = false; repairMessage = nil
    }
    func dismiss() { active = false; continuation = nil; cancelRepair() }
}
