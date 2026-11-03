import Foundation

/// Layout-independent key handling for the clipboard panel.
enum PanelKeyboard {
    /// Virtual key codes of the digits 1…9 on the top row (kVK_ANSI_1 …) and the keypad (kVK_ANSI_Keypad1 …).
    ///
    /// Shortcuts such as ⇧⌘1 must not read `charactersIgnoringModifiers`:
    /// Shift is not ignored there, so ⇧1 arrives as "!" on a US layout, and on
    /// AZERTY layouts the unshifted key is "&". The physical key is stable.
    static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// The digit 1…9 printed on the key, or nil for any other key.
    static func digit(for keyCode: UInt16) -> Int? { digitKeyCodes[keyCode] }
}
