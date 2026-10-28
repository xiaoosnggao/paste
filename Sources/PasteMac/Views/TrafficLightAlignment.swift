import AppKit
import SwiftUI

/// Measures where the window's traffic lights actually sit so the title bar's
/// title and toolbar share their exact center line.
enum TrafficLightGeometry {
    /// Where popup windows put the traffic lights' center line, from the window top.
    static let targetCenterFromTop: CGFloat = 23
    /// Left edge of the close button; matches its gap to the top edge.
    static let targetLeadingInset: CGFloat = 16

    /// How far the titlebar strip moves down so its centered buttons sit on `target`.
    static func titlebarDrop(containerHeight: CGFloat, target: CGFloat = targetCenterFromTop) -> CGFloat {
        max(0, target - containerHeight / 2)
    }

    /// Button origins inside the titlebar strip (bottom-left origin), keeping AppKit's spacing.
    static func buttonOrigins(sizes: [NSSize], step: CGFloat, stripHeight: CGFloat,
                              leading: CGFloat = targetLeadingInset) -> [NSPoint] {
        sizes.enumerated().map { index, size in
            let y = (stripHeight - size.height) / 2
            return NSPoint(x: leading + CGFloat(index) * step, y: y)
        }
    }

    /// Moves the system traffic lights down and right. AppKit re-lays the titlebar on resize,
    /// key and full-screen changes, so callers re-apply after each.
    @MainActor
    static func applyLayout(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard let close = buttons.first, let strip = close.superview, let container = strip.superview,
              let frameView = container.superview else { return }
        let height = container.frame.height
        let drop = titlebarDrop(containerHeight: height)
        let y = frameView.isFlipped ? drop : frameView.bounds.height - height - drop
        var changed = false
        if abs(container.frame.minY - y) > 0.5 { container.setFrameOrigin(NSPoint(x: container.frame.minX, y: y)); changed = true }
        let step = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.minX : 20
        let origins = buttonOrigins(sizes: buttons.map(\.frame.size), step: step > 0 ? step : 20,
                                    stripHeight: strip.bounds.height)
        for (button, origin) in zip(buttons, origins) where button.frame.origin != origin { button.setFrameOrigin(origin); changed = true }
        if changed { NotificationCenter.default.post(name: didLayout, object: window) }
    }

    static let didLayout = Notification.Name("TrafficLightGeometry.didLayout")

    /// Distance from the top of the content view to the close button's center.
    /// `buttonRect` is in window base coordinates (origin bottom-left).
    static func centerFromTop(buttonRect: NSRect, contentHeight: CGFloat) -> CGFloat {
        contentHeight - buttonRect.midY
    }

    @MainActor
    static func measure(_ window: NSWindow?) -> CGFloat? {
        guard let window, let button = window.standardWindowButton(.closeButton), !button.isHidden,
              let content = window.contentView else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        let contentRect = content.convert(content.bounds, to: nil)
        let value = centerFromTop(buttonRect: rect, contentHeight: contentRect.maxY)
        return value.isFinite && value > 0 && value < 80 ? value.rounded() : nil
    }
}

/// Reads the hosting window's traffic-light center and keeps it fresh on resize,
/// full-screen changes and appearance/title-bar changes.
struct TrafficLightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange; view.remeasure() }

    final class ReaderView: NSView {
        var onChange: (CGFloat) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: CGFloat?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              TrafficLightGeometry.didLayout]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // After the positioner, which observes the same notifications first.
                    DispatchQueue.main.async { self?.remeasure() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.remeasure() }
        }

        func remeasure() {
            guard let value = TrafficLightGeometry.measure(window), value != last else { return }
            last = value
            let callback = onChange
            DispatchQueue.main.async { callback(value) }
        }
    }
}


/// Keeps a popup window's traffic lights at the shared inset through AppKit's relayouts.
@MainActor
final class TrafficLightPositioner {
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.didUpdateNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        apply()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func apply() { if let window { TrafficLightGeometry.applyLayout(to: window) } }
}
