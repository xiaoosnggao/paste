import AppKit
import SwiftUI

/// Semantic colors follow the same window appearance as the native glass beneath them.
/// Light neutrals are sampled from the installed Raycast root window.
enum PanelPalette {
    static let canvas = adaptive(light: 0xECEAED, dark: 0x202124)
    static let surface = adaptive(light: 0xFAF9FB, dark: 0x2E2F34)
    static let raised = adaptive(light: 0xF1EFF3, dark: 0x37383E)
    static let hover = adaptive(light: 0xE6E4E9, dark: 0x414349)
    static let selection = adaptive(light: 0xFFFFFF, dark: 0xDCE8FF)
    static let selectionText = adaptive(light: 0x111827, dark: 0x111827)
    static let selectionSecondaryText = adaptive(light: 0x46546B, dark: 0x34445F)
    /// Ring around the selected card or row. Non-text, so it needs 3:1 against `selection` and `surface`.
    static let selectionBorder = adaptive(light: 0x0058D0, dark: 0x3B7BEA)
    static let text = adaptive(light: 0x111112, dark: 0xF2F2F5)
    static let secondaryText = adaptive(light: 0x59575D, dark: 0xBDC0C9)
    /// Links, active filters and prominent buttons. Meets 4.5:1 on every panel background.
    static let accent = adaptive(light: 0x0058D0, dark: 0x8AB4F8)
    /// Text and symbols drawn on an `accent` fill.
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x202124)
    static let border = adaptive(light: 0xAAA7AF, dark: 0x686A73)
    static let skeleton = adaptive(light: 0xC9C7CC, dark: 0x45474F)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// Feedback belongs to the control, never to the entire glass window.
struct PanelControlStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration, selected: selected)
    }
    private struct Control: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(selected ? PanelPalette.selectionText : PanelPalette.text)
                .background(selected ? PanelPalette.selection : (hovering || configuration.isPressed ? PanelPalette.hover : .clear), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).strokeBorder(selected ? PanelPalette.selectionBorder : .clear, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.72 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
