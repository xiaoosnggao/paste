import AppKit
import SwiftUI

enum PanelPresentation {
    static func visibleFrame(on screen: NSRect) -> NSRect {
        NSRect(x: screen.minX + 8, y: screen.minY + 8,
               width: max(1, screen.width - 16), height: min(330, max(1, screen.height - 16)))
    }

    static func hiddenContentFrame(size: NSSize) -> NSRect {
        NSRect(x: 0, y: -size.height - 4, width: size.width, height: size.height)
    }
}

@MainActor
final class PanelAnimationContainer: NSView {
    let surface: NSView
    init(surface: NSView, frame: NSRect, cornerRadius: CGFloat = 25) {
        self.surface = surface
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
enum PanelGlassContainer {
    static func make<Content: View>(content: Content, frame: NSRect, cornerRadius: CGFloat = 25) -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            return PanelAnimationContainer(surface: glass, frame: frame, cornerRadius: cornerRadius)
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.addSubview(hosting)
        return PanelAnimationContainer(surface: blur, frame: frame, cornerRadius: cornerRadius)
    }
}
