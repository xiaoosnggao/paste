import AppKit

/// Uses the same recorded glyphs as Settings, with native menu shortcut alignment.
@MainActor
enum MenuShortcut {
    static func apply(_ description: String?, enabled: Bool = true, to item: NSMenuItem) {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        guard enabled, var key = description, !key.contains("占用") else { return }
        var flags: NSEvent.ModifierFlags = []
        let modifiers: [(Character, NSEvent.ModifierFlags)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let character = key.first, let modifier = modifiers.first(where: { $0.0 == character }) {
            flags.insert(modifier.1)
            key.removeFirst()
        }
        guard !flags.isEmpty, key.count == 1 else { return }
        item.keyEquivalent = key.lowercased()
        item.keyEquivalentModifierMask = flags
    }
}

#if DEBUG
extension MenuShortcut {
    static func checkPresentation() throws -> Int {
        let item = NSMenuItem(title: "截图识别", action: nil, keyEquivalent: "")
        apply("⌃⌥O", to: item)
        guard item.keyEquivalent == "o", item.keyEquivalentModifierMask == [.control, .option] else {
            throw SystemChecks.Failure(message: "Menu shortcut did not show configured combination")
        }
        apply("⇧⌘V", to: item)
        guard item.keyEquivalent == "v", item.keyEquivalentModifierMask == [.shift, .command] else {
            throw SystemChecks.Failure(message: "Menu shortcut retained stale binding")
        }
        apply("⌃⌥O", enabled: false, to: item)
        guard item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.isEmpty else {
            throw SystemChecks.Failure(message: "Menu shortcut displayed a disabled combination")
        }
        for invalid in ["未设置", "⇧⌘V（占用）", "⌘", "⌘invalid"] {
            apply(invalid, to: item)
            guard item.keyEquivalent.isEmpty else { throw SystemChecks.Failure(message: "Menu shortcut displayed invalid combination") }
        }
        return 7
    }
}
#endif
