import Foundation
import Combine
import Carbon

enum ToolAction: String, CaseIterable, Codable, Identifiable {
    case screenshotOCR, screenshotTranslate, inputTranslate, clipboardTranslate, selectionTranslate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenshotOCR: return "截图识别"
        case .screenshotTranslate: return "截图翻译"
        case .inputTranslate: return "输入翻译"
        case .clipboardTranslate: return "剪贴板翻译"
        case .selectionTranslate: return "选中文字翻译"
        }
    }
    var symbol: String {
        switch self {
        case .screenshotOCR: return "text.viewfinder"
        case .screenshotTranslate: return "viewfinder"
        case .inputTranslate: return "character.bubble"
        case .clipboardTranslate: return "doc.on.clipboard"
        case .selectionTranslate: return "text.cursor"
        }
    }
    var suggestedKeyCode: UInt32 {
        switch self { case .screenshotOCR: return 31; case .screenshotTranslate: return 17; case .inputTranslate: return 0; case .clipboardTranslate: return 8; case .selectionTranslate: return 1 }
    }
    var suggestedDescription: String {
        switch self { case .screenshotOCR: return "⌃⌥O"; case .screenshotTranslate: return "⌃⌥T"; case .inputTranslate: return "⌃⌥A"; case .clipboardTranslate: return "⌃⌥C"; case .selectionTranslate: return "⌃⌥S" }
    }
}
struct ToolShortcut: Codable, Equatable {
    var keyCode: UInt32?
    var modifiers: UInt32
    var description: String
    var enabled: Bool
    init(keyCode: UInt32? = nil, modifiers: UInt32 = 0, description: String = "未设置", enabled: Bool = false) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.description = description; self.enabled = enabled
    }
}

@MainActor
protocol ToolShortcutRegistration: AnyObject {
    var onActivate: (() -> Void)? { get set }
    /// A failure must leave the prior registration in place.
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool
    func unregister()
}
extension GlobalShortcut: ToolShortcutRegistration {}

@MainActor
final class ToolShortcutManager: ObservableObject {
    static let persistenceKey = "toolShortcutBindings.v1"
    var onActivate: (ToolAction) -> Void
    @Published private(set) var bindings: [ToolAction: ToolShortcut]
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let makeRegistration: (ToolAction) -> ToolShortcutRegistration
    private var registrations: [ToolAction: ToolShortcutRegistration] = [:]

    convenience init(defaults: UserDefaults = .standard, onActivate: @escaping (ToolAction) -> Void) {
        self.init(defaults: defaults, onActivate: onActivate, makeRegistration: { action in
            GlobalShortcut(identifier: UInt32(100 + (ToolAction.allCases.firstIndex(of: action) ?? 0)))
        })
    }
    init(defaults: UserDefaults, onActivate: @escaping (ToolAction) -> Void, makeRegistration: @escaping (ToolAction) -> ToolShortcutRegistration) {
        self.defaults = defaults; self.onActivate = onActivate; self.makeRegistration = makeRegistration
        self.bindings = Dictionary(uniqueKeysWithValues: ToolAction.allCases.map { ($0, ToolShortcut()) })
        guard let data = defaults.data(forKey: Self.persistenceKey) else { return }
        guard data.count <= 64 * 1024 else { errorMessage = "快捷键设置文件过大，请重新设置。"; return }
        let stored: [String: ToolShortcut]
        do { stored = try JSONDecoder().decode([String: ToolShortcut].self, from: data) }
        catch { errorMessage = "无法读取快捷键设置，请重新设置。"; return }
        var errors: [String] = []
        for action in ToolAction.allCases {
            guard var binding = stored[action.rawValue] else { continue }
            let requested = binding.enabled
            binding.enabled = false
            if let code = binding.keyCode {
                guard valid(keyCode: code, modifiers: binding.modifiers, description: binding.description) else {
                    errors.append("\(action.title)的快捷键无效，请重新设置。")
                    continue
                }
            } else if requested || binding.description.utf8.count > 128 {
                errors.append("\(action.title)的快捷键无效，请重新设置。")
                continue
            }
            bindings[action] = binding
            guard requested else { continue }
            guard let keyCode = binding.keyCode, !isConflict(keyCode: keyCode, modifiers: binding.modifiers, excluding: action) else {
                errors.append("\(action.title)的快捷键无效或冲突。")
                continue
            }
            guard registration(for: action).register(keyCode: keyCode, modifiers: binding.modifiers) else {
                errors.append("\(action.title)的快捷键已被系统或其他应用占用。")
                continue
            }
            binding.enabled = true; bindings[action] = binding
        }
        if !errors.isEmpty { errorMessage = errors.joined(separator: "\n"); persist() }
    }
    @discardableResult
    func configure(_ action: ToolAction, keyCode: UInt32, modifiers: UInt32, description: String) -> Bool {
        guard valid(keyCode: keyCode, modifiers: modifiers, description: description) else {
            errorMessage = "快捷键需包含 ⌘、⌃ 或 ⌥。按 Esc 取消设置。"; return false
        }
        guard !isConflict(keyCode: keyCode, modifiers: modifiers, excluding: action) else {
            errorMessage = "此快捷键已用于剪贴板窗口、连续粘贴或其他工具。"; return false
        }
        if let current = bindings[action], current.enabled, current.keyCode == keyCode, current.modifiers == modifiers {
            bindings[action] = ToolShortcut(keyCode: keyCode, modifiers: modifiers, description: description, enabled: true)
            errorMessage = nil; persist(); return true
        }
        // GlobalShortcut registers a replacement before releasing its old Carbon handle.
        // Publish and persist only after registration succeeds.
        guard registration(for: action).register(keyCode: keyCode, modifiers: modifiers) else {
            errorMessage = "快捷键已被系统或其他应用占用，原设置已保留。"; return false
        }
        bindings[action] = ToolShortcut(keyCode: keyCode, modifiers: modifiers, description: description, enabled: true)
        errorMessage = nil; persist(); return true
    }
    @discardableResult
    func setEnabled(_ action: ToolAction, _ enabled: Bool) -> Bool {
        guard var binding = bindings[action] else { return false }
        if enabled {
            guard let code = binding.keyCode else { errorMessage = "请先设置快捷键。"; return false }
            return configure(action, keyCode: code, modifiers: binding.modifiers, description: binding.description)
        }
        registrations[action]?.unregister()
        binding.enabled = false; bindings[action] = binding; errorMessage = nil; persist(); return true
    }
    func clear(_ action: ToolAction) {
        registrations[action]?.unregister()
        bindings[action] = ToolShortcut(); errorMessage = nil; persist()
    }
    func conflicts(keyCode: UInt32, modifiers: UInt32) -> Bool {
        bindings.values.contains { $0.enabled && $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
    private func registration(for action: ToolAction) -> ToolShortcutRegistration {
        if let existing = registrations[action] { return existing }
        let registration = makeRegistration(action)
        registration.onActivate = { [weak self] in
            guard let self, self.bindings[action]?.enabled == true else { return }
            self.onActivate(action)
        }
        registrations[action] = registration
        return registration
    }
    private func valid(keyCode: UInt32, modifiers: UInt32, description: String) -> Bool {
        let required = UInt32(cmdKey | controlKey | optionKey)
        let allowed = required | UInt32(shiftKey)
        return keyCode < 128 && keyCode != 53 && modifiers & required != 0 && modifiers & ~allowed == 0 && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && description.utf8.count <= 128
    }
    private func isConflict(keyCode: UInt32, modifiers: UInt32, excluding action: ToolAction) -> Bool {
        if bindings.contains(where: { $0.key != action && $0.value.enabled && $0.value.keyCode == keyCode && $0.value.modifiers == modifiers }) { return true }
        for (keyName, modifiersName, fallback) in [("shortcutKeyCode", "shortcutModifiers", 9), ("stackShortcutKeyCode", "stackShortcutModifiers", 8)] {
            let code = defaults.object(forKey: keyName) == nil ? UInt32(fallback) : UInt32(exactly: defaults.integer(forKey: keyName)) ?? UInt32(fallback)
            let flags = defaults.object(forKey: modifiersName) == nil ? UInt32(cmdKey | shiftKey) : UInt32(exactly: defaults.integer(forKey: modifiersName)) ?? UInt32(cmdKey | shiftKey)
            if code == keyCode && flags == modifiers { return true }
        }
        return false
    }
    private func persist() {
        do {
            let stored = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.persistenceKey)
        } catch { errorMessage = "快捷键保存失败：\(error.localizedDescription)" }
    }
}
