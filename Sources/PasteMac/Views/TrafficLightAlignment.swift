import AppKit
import SwiftUI

/// Measures where the window's traffic lights actually sit so the title bar's
/// title and toolbar share their exact center line.
enum TrafficLightGeometry {
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
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.remeasure() }
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

