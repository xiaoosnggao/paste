#if DEBUG
import Foundation

/// Pure checks for layout-independent panel shortcuts.
enum PanelKeyboardChecks {
    static func run() throws -> Int {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: message) }
        }
        let expected: [(UInt16, Int)] = [(18, 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9),
                                         (83, 1), (87, 5), (92, 9)]
        for (code, digit) in expected {
            try check(PanelKeyboard.digit(for: code) == digit, "key code \(code) did not map to digit \(digit)")
        }
        // 0 (row and keypad), letters, and Return are not card shortcuts.
        for code: UInt16 in [29, 82, 0, 8, 36] {
            try check(PanelKeyboard.digit(for: code) == nil, "key code \(code) mapped to a card digit")
        }
        try check(Set(PanelKeyboard.digitKeyCodes.values) == Set(1...9), "digit key map is not exactly 1…9")
        return expected.count + 6
    }
}
#endif
