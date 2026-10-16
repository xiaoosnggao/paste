#if DEBUG
import Foundation
import Carbon

@MainActor
enum ToolShortcutChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Tool shortcuts: \(message)" }
    }
    private final class Registration: ToolShortcutRegistration {
        var onActivate: (() -> Void)?
        var accepts = true
        var registered: (UInt32, UInt32)?
        var registrations = 0
        var unregistrations = 0
        func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
            registrations += 1
            guard accepts else { return false }
            registered = (keyCode, modifiers); return true
        }
        func unregister() { unregistrations += 1; registered = nil }
    }
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; count += 1
        }
        let suite = "com.gaoxs.pasteboard.toolshortcuts.tests.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(message: "cannot create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var backends: [ToolAction: Registration] = [:]
        var activations: [ToolAction] = []
        let manager = ToolShortcutManager(defaults: defaults, onActivate: { activations.append($0) }, makeRegistration: { action in
            let registration = Registration(); backends[action] = registration; return registration
        })
        let flags = UInt32(controlKey | optionKey)
        try check(manager.bindings.count == ToolAction.allCases.count && manager.bindings.values.allSatisfy { $0.keyCode == nil && !$0.enabled }, "defaults must be unbound")
        try check(backends.isEmpty, "defaults registered real or fake hotkeys")
        try check(!manager.configure(.screenshotOCR, keyCode: 53, modifiers: flags, description: "Escape"), "Escape accepted")
        try check(!manager.configure(.screenshotOCR, keyCode: 31, modifiers: UInt32(shiftKey), description: "⇧O"), "shift-only accepted")
        try check(!manager.configure(.screenshotOCR, keyCode: 128, modifiers: flags, description: "Invalid"), "invalid key code accepted")
        try check(!manager.configure(.screenshotOCR, keyCode: 9, modifiers: UInt32(cmdKey | shiftKey), description: "⇧⌘V"), "paste conflict accepted")
        try check(!manager.configure(.screenshotOCR, keyCode: 8, modifiers: UInt32(cmdKey | shiftKey), description: "⇧⌘C"), "Stack conflict accepted")
        try check(backends.isEmpty, "invalid policy attempted registration")
        try check(manager.configure(.screenshotOCR, keyCode: 31, modifiers: flags, description: "⌃⌥O"), "valid configuration failed")
        try check(manager.conflicts(keyCode: 31, modifiers: flags), "enabled binding not reported as conflict")
        try check(!manager.configure(.screenshotTranslate, keyCode: 31, modifiers: flags, description: "⌃⌥O"), "internal duplicate accepted")
        backends[.screenshotOCR]?.onActivate?()
        try check(activations == [.screenshotOCR], "activation routed to wrong action")
        let original = manager.bindings[.screenshotOCR]
        let persisted = defaults.data(forKey: ToolShortcutManager.persistenceKey)
        backends[.screenshotOCR]?.accepts = false
        try check(!manager.configure(.screenshotOCR, keyCode: 17, modifiers: flags, description: "⌃⌥T"), "occupied system key accepted")
        try check(manager.bindings[.screenshotOCR] == original && defaults.data(forKey: ToolShortcutManager.persistenceKey) == persisted, "failed registration changed configuration")
        try check(backends[.screenshotOCR]?.registered?.0 == 31 && backends[.screenshotOCR]?.unregistrations == 0, "failed replacement removed original registration")
        backends[.screenshotOCR]?.accepts = true
        let attempts = backends[.screenshotOCR]?.registrations
        try check(manager.configure(.screenshotOCR, keyCode: 31, modifiers: flags, description: "⌃⌥O") && backends[.screenshotOCR]?.registrations == attempts, "identical active binding should not register again")
        try check(manager.setEnabled(.screenshotOCR, false) && !manager.conflicts(keyCode: 31, modifiers: flags), "disable did not release conflict")
        try check(backends[.screenshotOCR]?.registered == nil && backends[.screenshotOCR]?.unregistrations == 1, "disable did not unregister")
        backends[.screenshotOCR]?.onActivate?()
        try check(activations == [.screenshotOCR], "disabled callback activated tool")
        backends[.screenshotOCR]?.accepts = false
        try check(!manager.setEnabled(.screenshotOCR, true) && manager.bindings[.screenshotOCR]?.enabled == false, "failed enable falsely became active")
        backends[.screenshotOCR]?.accepts = true
        try check(manager.setEnabled(.screenshotOCR, true), "re-enable failed")
        var restarted: [ToolAction: Registration] = [:]
        let restored = ToolShortcutManager(defaults: defaults, onActivate: { _ in }, makeRegistration: { action in let registration = Registration(); restarted[action] = registration; return registration })
        try check(restored.bindings[.screenshotOCR] == manager.bindings[.screenshotOCR] && restarted[.screenshotOCR]?.registered?.0 == 31, "restart failed to restore registration")
        manager.clear(.screenshotOCR)
        try check(manager.bindings[.screenshotOCR]?.keyCode == nil && manager.bindings[.screenshotOCR]?.enabled == false && backends[.screenshotOCR]?.registered == nil, "clear retained active binding")
        try check(!manager.setEnabled(.inputTranslate, true), "unbound action enabled")
        defaults.set(17, forKey: "shortcutKeyCode"); defaults.set(Int(flags), forKey: "shortcutModifiers")
        try check(!manager.configure(.inputTranslate, keyCode: 17, modifiers: flags, description: "⌃⌥T"), "custom legacy paste conflict accepted")
        defaults.removeObject(forKey: "shortcutKeyCode"); defaults.removeObject(forKey: "shortcutModifiers")
        defaults.set(try JSONEncoder().encode([ToolAction.clipboardTranslate.rawValue: ToolShortcut(keyCode: 8, modifiers: flags, description: "⌃⌥C", enabled: true)]), forKey: ToolShortcutManager.persistenceKey)
        let failedRestart = ToolShortcutManager(defaults: defaults, onActivate: { _ in }, makeRegistration: { _ in let registration = Registration(); registration.accepts = false; return registration })
        try check(failedRestart.bindings[.clipboardTranslate]?.enabled == false && failedRestart.bindings[.clipboardTranslate]?.keyCode == 8 && failedRestart.errorMessage != nil, "failed restart falsely enabled binding")
        defaults.set(try JSONEncoder().encode([ToolAction.inputTranslate.rawValue: ToolShortcut(keyCode: 53, modifiers: flags, description: "Esc", enabled: true)]), forKey: ToolShortcutManager.persistenceKey)
        var invalidRegistrations = 0
        let invalidRestart = ToolShortcutManager(defaults: defaults, onActivate: { _ in }, makeRegistration: { _ in invalidRegistrations += 1; return Registration() })
        try check(invalidRestart.bindings[.inputTranslate]?.enabled == false && invalidRestart.errorMessage != nil && invalidRegistrations == 0, "invalid restart attempted registration")
        defaults.set(try JSONEncoder().encode([
            ToolAction.screenshotOCR.rawValue: ToolShortcut(keyCode: 31, modifiers: flags, description: "⌃⌥O", enabled: true),
            ToolAction.screenshotTranslate.rawValue: ToolShortcut(keyCode: 31, modifiers: flags, description: "⌃⌥O", enabled: true)
        ]), forKey: ToolShortcutManager.persistenceKey)
        let duplicateRestart = ToolShortcutManager(defaults: defaults, onActivate: { _ in }, makeRegistration: { _ in Registration() })
        try check(duplicateRestart.bindings.values.filter(\.enabled).count == 1 && duplicateRestart.errorMessage != nil, "duplicate restart enabled two conflicting tools")
        defaults.set(Data("broken".utf8), forKey: ToolShortcutManager.persistenceKey)
        let corrupt = ToolShortcutManager(defaults: defaults, onActivate: { _ in }, makeRegistration: { _ in Registration() })
        try check(corrupt.bindings.values.allSatisfy { !$0.enabled } && corrupt.errorMessage != nil, "corrupt configuration silently accepted")
        defaults.removeObject(forKey: ToolShortcutManager.persistenceKey)
        let selection = ToolShortcutManager(defaults: defaults, onActivate: { activations.append($0) }, makeRegistration: { action in
            let registration = Registration(); backends[action] = registration; return registration
        })
        try check(selection.bindings[.selectionTranslate] == ToolShortcut(), "selection shortcut must be unbound")
        try check(selection.configure(.selectionTranslate, keyCode: 1, modifiers: flags, description: "⌃⌥S"), "selection shortcut could not be configured")
        backends[.selectionTranslate]?.onActivate?()
        try check(activations.last == .selectionTranslate, "selection callback routed incorrectly")
        try check(!selection.configure(.clipboardTranslate, keyCode: 1, modifiers: flags, description: "⌃⌥S"), "selection binding conflict accepted")
        selection.clear(.selectionTranslate)
        try check(selection.bindings[.selectionTranslate] == ToolShortcut(), "selection shortcut did not clear")
        return count
    }
}
#endif
