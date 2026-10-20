import AppKit
import SwiftUI

/// Remaps a wheel locally; native horizontal trackpad and side-wheel input keeps its original event.
enum HorizontalScrollRouting {
    /// Forward the original native event directly so controls inside the row cannot consume it.
    static func nativeHorizontalEvent(_ event: NSEvent, hasHorizontalOverflow: Bool,
                                      continuingGesture: Bool = false) -> NSEvent? {
        guard event.type == .scrollWheel, hasHorizontalOverflow, let source = event.cgEvent else { return nil }
        let horizontal = event.scrollingDeltaX != 0
            || source.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0
            || source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) != 0
            || source.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0
        let stationary = event.scrollingDeltaY == 0
            && source.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0
            && source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0
            && source.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0
        let endingOrMomentum = continuingGesture && stationary && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
        return horizontal || endingOrMomentum ? event : nil
    }

    static func remappedEvent(_ event: NSEvent, hasHorizontalOverflow: Bool,
                              continuingVerticalGesture: Bool = false) -> NSEvent? {
        guard event.type == .scrollWheel, hasHorizontalOverflow, let source = event.cgEvent,
              event.scrollingDeltaX == 0,
              source.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0,
              source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0,
              source.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0 else { return nil }
        let hasVerticalDelta = event.scrollingDeltaY != 0
            || source.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0
            || source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) != 0
            || source.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0
        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard hasVerticalDelta || (continuingVerticalGesture && hasGesturePhase),
              let copy = source.copy() else { return nil }
        let integerAxes: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)
        ]
        for (vertical, horizontal) in integerAxes {
            copy.setIntegerValueField(horizontal, value: source.getIntegerValueField(vertical))
            copy.setIntegerValueField(vertical, value: 0)
        }
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                 value: source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: copy)
    }

    @MainActor
    static func hasHorizontalOverflow(in scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return false }
        return document.frame.width > scrollView.contentView.bounds.width + 0.5
    }
}

extension View {
    /// Apply to the content INSIDE a horizontal ScrollView, preserving its ScrollViewReader proxy.
    func horizontalScrollWheelRouting() -> some View {
        background(HorizontalScrollRoutingAnchor())
    }
}

private struct HorizontalScrollRoutingAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalScrollRoutingView { HorizontalScrollRoutingView() }
    func updateNSView(_ nsView: HorizontalScrollRoutingView, context: Context) {}
    static func dismantleNSView(_ nsView: HorizontalScrollRoutingView, coordinator: ()) { nsView.stopMonitoring() }
}

@MainActor
private final class HorizontalScrollRoutingView: NSView {
    private var monitor: Any?
    private var continuingVerticalGesture = false
    private var continuingNativeHorizontalGesture = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.route(event)
            }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        continuingVerticalGesture = false
        continuingNativeHorizontalGesture = false
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard let scrollView = enclosingScrollView, let window, event.window === window,
              !isHiddenOrHasHiddenAncestor, !scrollView.isHiddenOrHasHiddenAncestor,
              scrollView.contentView.bounds.contains(scrollView.contentView.convert(event.locationInWindow, from: nil)),
              let root = window.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
              hit.enclosingScrollView === scrollView else {
            continuingVerticalGesture = false
            continuingNativeHorizontalGesture = false
            return event
        }
        let hasOverflow = HorizontalScrollRouting.hasHorizontalOverflow(in: scrollView)
        if let native = HorizontalScrollRouting.nativeHorizontalEvent(event, hasHorizontalOverflow: hasOverflow,
                                continuingGesture: continuingNativeHorizontalGesture) {
            continuingNativeHorizontalGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            continuingVerticalGesture = false
            scrollView.scrollWheel(with: native)
            return nil
        }
        guard let mapped = HorizontalScrollRouting.remappedEvent(event,
                    hasHorizontalOverflow: hasOverflow,
                    continuingVerticalGesture: continuingVerticalGesture) else {
            continuingVerticalGesture = false
            continuingNativeHorizontalGesture = false
            return event
        }
        continuingNativeHorizontalGesture = false
        continuingVerticalGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        // Deliver directly to this scroll view. No event posting, accessibility access, or global monitor.
        scrollView.scrollWheel(with: mapped)
        return nil
    }
}
