import AppKit
import SwiftUI

enum PanelPresentation {
    static let baseHeight: CGFloat = 320
    static let suggestionContentHeight: CGFloat = 132
    static let suggestionSpacing: CGFloat = 12
    static let suggestionExpansionHeight = suggestionContentHeight + suggestionSpacing

    static func visibleFrame(on screen: NSRect, suggestionsVisible: Bool = false, additionalHeight: CGFloat = 0) -> NSRect {
        NSRect(x: screen.minX + 8, y: screen.minY + 8,
               width: max(1, screen.width - 16), height: min(baseHeight + (suggestionsVisible ? suggestionExpansionHeight + additionalHeight : 0), max(1, screen.height - 16)))
    }

    static func hiddenContentFrame(size: NSSize) -> NSRect {
        NSRect(x: 0, y: -size.height - 4, width: size.width, height: size.height)
    }

    static func interpolatedFrame(from start: NSRect, to end: NSRect, progress: CGFloat) -> NSRect {
        let progress = min(1, max(0, progress))
        let eased = 1 - pow(1 - progress, 3)
        return NSRect(x: start.minX + (end.minX - start.minX) * eased,
                      y: start.minY + (end.minY - start.minY) * eased,
                      width: start.width + (end.width - start.width) * eased,
                      height: start.height + (end.height - start.height) * eased)
    }
}

/// Owns frame animation so dismissal or a newer summary can stop it immediately.
/// AppKit animator proxies otherwise keep resizing the window during its exit slide.
@MainActor
final class PanelFrameAnimator {
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); task = nil }

    func animate(_ panel: NSWindow, to destination: NSRect, reduceMotion: Bool = false) {
        cancel()
        guard !reduceMotion else { panel.setFrame(destination, display: true); return }
        let start = panel.frame
        guard start != destination else { return }
        task = Task { @MainActor [weak panel] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let panel else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / 0.24)
                panel.setFrame(PanelPresentation.interpolatedFrame(from: start, to: destination, progress: progress), display: true)
                if progress >= 1 { return }
                do { try await Task.sleep(nanoseconds: 16_666_667) }
                catch { return }
            }
        }
    }
}

@MainActor
final class PanelAnimationContainer: NSView {
    let surface: NSView
    init(surface: NSView, frame: NSRect, cornerRadius: CGFloat = DesignTokens.Radius.panel) {
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
    static func make<Content: View>(content: Content, frame: NSRect, cornerRadius: CGFloat = DesignTokens.Radius.panel,
                                    reduceTransparency: Bool? = nil) -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        let surface = PanelGlassSurface(content: hosting, frame: frame, cornerRadius: cornerRadius,
                                        reduceTransparency: reduceTransparency)
        return PanelAnimationContainer(surface: surface, frame: frame, cornerRadius: cornerRadius)
    }
}

/// Keeps the animated surface stable when accessibility settings replace its material.
@MainActor
final class PanelGlassSurface: NSView {
    enum Material { case solid, liquidGlass, visualEffect }
    private(set) var material: Material = .solid
    private let content: NSView
    private let cornerRadius: CGFloat
    private let reduceTransparencyOverride: Bool?
    private var background: NSView?

    init(content: NSView, frame: NSRect, cornerRadius: CGFloat, reduceTransparency: Bool?) {
        self.content = content
        self.cornerRadius = cornerRadius
        reduceTransparencyOverride = reduceTransparency
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        refreshMaterial()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshMaterial),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterialColors()
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func updateMaterialColors() {
        guard let background else { return }
        if material == .solid {
            let color = usesDarkAppearance
                ? NSColor(srgbRed: 32.0 / 255, green: 33.0 / 255, blue: 36.0 / 255, alpha: 1)
                : NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 237.0 / 255, alpha: 1)
            background.layer?.backgroundColor = color.cgColor
        } else if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            // Native glass brightens this calibrated light tint toward Raycast's neutral gray.
            glass.tintColor = usesDarkAppearance
                ? NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 0.80)
                : NSColor(srgbRed: 188.0 / 255, green: 180.0 / 255, blue: 192.0 / 255, alpha: 0.28)
        }
    }

    @objc private func refreshMaterial() {
        let reduceTransparency = reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard background == nil || (material == .solid) != reduceTransparency else { return }
        content.removeFromSuperview()
        background?.removeFromSuperview()
        let surface: NSView
        if reduceTransparency {
            let solid = NSView(frame: bounds)
            solid.wantsLayer = true
            solid.addSubview(content)
            material = .solid
            surface = solid
        } else {
            surface = makeTranslucentMaterial()
        }
        content.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        background = surface
        updateMaterialColors()
    }

    private func makeTranslucentMaterial() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            // effectIsInteractive is only in the macOS 27 SDK (Xcode 27, Swift 6.4);
            // older SDKs already default to non-interactive glass.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            #endif
            // AppKit only guarantees correct glass ordering for contentView.
            glass.contentView = content
            material = .liquidGlass
            return glass
        }
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.addSubview(content)
        material = .visualEffect
        return blur
    }
}
