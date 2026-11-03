#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum PanelPaletteChecks {
    static func run() throws -> Int {
        var count = 0
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            var minimumRatio = Double.infinity
            var canvasLuminance = Double.infinity
            var indicatorRatio = 0.0
            appearance.performAsCurrentDrawingAppearance {
                func luminance(_ color: Color) -> Double {
                    let rgb = NSColor(color).usingColorSpace(.sRGB)!
                    func linear(_ component: CGFloat) -> Double {
                        let value = Double(component)
                        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                    }
                    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                }
                canvasLuminance = luminance(PanelPalette.canvas)
                for background in [PanelPalette.canvas, PanelPalette.surface, PanelPalette.raised, PanelPalette.hover] {
                    for foreground in [PanelPalette.text, PanelPalette.secondaryText, PanelPalette.accent] {
                        let a = luminance(foreground), b = luminance(background)
                        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                        minimumRatio = min(minimumRatio, ratio)
                        count += 1
                    }
                }
                let selected = luminance(PanelPalette.selection)
                guard selected > luminance(PanelPalette.surface) else { minimumRatio = 0; return }
                for foreground in [PanelPalette.selectionText, PanelPalette.selectionSecondaryText] {
                    let value = luminance(foreground)
                    minimumRatio = min(minimumRatio, (selected + 0.05) / (value + 0.05))
                    count += 1
                }
                func ratio(_ a: Color, _ b: Color) -> Double {
                    let x = luminance(a), y = luminance(b)
                    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
                }
                // Labels on prominent buttons.
                minimumRatio = min(minimumRatio, ratio(PanelPalette.onAccent, PanelPalette.accent))
                count += 1
                // The selection ring is a non-text indicator: WCAG 1.4.11 asks for 3:1.
                indicatorRatio = min(ratio(PanelPalette.selectionBorder, PanelPalette.selection),
                                     ratio(PanelPalette.selectionBorder, PanelPalette.surface))
                count += 1
            }
            let dark = name == .darkAqua
            guard dark ? canvasLuminance < 0.10 : canvasLuminance > 0.7 && canvasLuminance < 0.90 else {
                throw SystemChecks.Failure(message: "Panel palette did not follow \(name.rawValue)")
            }
            count += 1
            guard minimumRatio >= 4.5 else { throw SystemChecks.Failure(message: "Panel text contrast below 4.5:1 in \(name.rawValue): \(minimumRatio)") }
            guard indicatorRatio >= 3 else { throw SystemChecks.Failure(message: "Selection ring contrast below 3:1 in \(name.rawValue): \(indicatorRatio)") }
        }
        return count
    }
}
#endif
