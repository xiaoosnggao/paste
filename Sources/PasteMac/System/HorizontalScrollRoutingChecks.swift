#if DEBUG
import AppKit

/// Constructs events locally; never posts input or accesses the system clipboard.
@MainActor
enum HorizontalScrollRoutingChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Horizontal scrolling: \(message)") }
            count += 1
        }
        func wheel(vertical: Int32, horizontal: Int32 = 0, precise: Bool = false,
                   phase: Int64 = 0, momentum: Int64 = 0, fixedVertical: Double? = nil) throws -> NSEvent {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                   wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
                throw SystemChecks.Failure(message: "Horizontal scrolling: fixture construction failed")
            }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            if let fixedVertical { cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedVertical) }
            cg.flags = [.maskAlternate]
            guard let event = NSEvent(cgEvent: cg) else {
                throw SystemChecks.Failure(message: "Horizontal scrolling: NSEvent construction failed")
            }
            return event
        }
        func mapped(_ event: NSEvent, continuing: Bool = false) throws -> NSEvent {
            guard let value = HorizontalScrollRouting.remappedEvent(event, hasHorizontalOverflow: true,
                                                                     continuingVerticalGesture: continuing) else {
                throw SystemChecks.Failure(message: "Horizontal scrolling: vertical wheel was not remapped")
            }
            return value
        }

        let line = try wheel(vertical: -3)
        let horizontalLine = try mapped(line)
        try check(horizontalLine.scrollingDeltaX == line.scrollingDeltaY && horizontalLine.scrollingDeltaY == 0,
                  "ordinary mouse wheel did not become horizontal")
        try check(line.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3,
                  "remapping mutated the original wheel event")
        try check(horizontalLine.modifierFlags == line.modifierFlags,
                  "remapping lost keyboard modifiers")
        try check(horizontalLine.hasPreciseScrollingDeltas == line.hasPreciseScrollingDeltas,
                  "line-based wheel became a precise wheel")

        let precise = try wheel(vertical: 14, precise: true, phase: 1, momentum: 2, fixedVertical: 2.375)
        let horizontalPrecise = try mapped(precise)
        try check(horizontalPrecise.hasPreciseScrollingDeltas && horizontalPrecise.scrollingDeltaY == 0,
                  "precise wheel precision flag or axis was lost")
        try check(horizontalPrecise.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                  == precise.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                  "pixel-based wheel distance was lost")
        try check(horizontalPrecise.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                  == 2.375,
                  "fractional wheel distance was lost")
        try check(horizontalPrecise.phase == precise.phase && horizontalPrecise.momentumPhase == precise.momentumPhase,
                  "scroll or momentum phases changed during remapping")
        try check(horizontalPrecise.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0
                  && horizontalPrecise.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0,
                  "vertical point or fixed-point data remained after remapping")

        for native in [try wheel(vertical: 0, horizontal: 5), try wheel(vertical: 2, horizontal: 1, precise: true)] {
            try check(HorizontalScrollRouting.remappedEvent(native, hasHorizontalOverflow: true) == nil,
                      "native horizontal or diagonal input was remapped")
            try check(HorizontalScrollRouting.nativeHorizontalEvent(native, hasHorizontalOverflow: true) === native,
                      "native horizontal forwarding replaced the original event")
            try check(HorizontalScrollRouting.nativeHorizontalEvent(native, hasHorizontalOverflow: false) == nil,
                      "native horizontal event was swallowed without overflow")
        }
        try check(HorizontalScrollRouting.nativeHorizontalEvent(line, hasHorizontalOverflow: true) == nil,
                  "vertical wheel bypassed horizontal remapping")
        try check(HorizontalScrollRouting.remappedEvent(line, hasHorizontalOverflow: false) == nil,
                  "non-overflowing content swallowed a wheel event")
        let zero = try wheel(vertical: 0)
        try check(HorizontalScrollRouting.remappedEvent(zero, hasHorizontalOverflow: true) == nil,
                  "unrelated zero-delta event was intercepted")
        let ended = try wheel(vertical: 0, precise: true, phase: 4)
        try check(HorizontalScrollRouting.remappedEvent(ended, hasHorizontalOverflow: true) == nil,
                  "zero-delta end phase started a new routed gesture")
        let mappedEnd = try mapped(ended, continuing: true)
        try check(mappedEnd.phase == ended.phase && mappedEnd.scrollingDeltaX == 0 && mappedEnd.scrollingDeltaY == 0,
                  "routed gesture lost its zero-delta termination phase")
        try check(HorizontalScrollRouting.nativeHorizontalEvent(ended, hasHorizontalOverflow: true,
                                                                 continuingGesture: true) === ended,
                  "native horizontal gesture lost its unchanged zero-delta termination")
        try check(HorizontalScrollRouting.nativeHorizontalEvent(ended, hasHorizontalOverflow: true) == nil,
                  "native horizontal forwarding began from an unrelated zero-delta phase")

        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 320, height: 180))
        let document = NSView(frame: .init(x: 0, y: 0, width: 100, height: 180))
        scroll.documentView = document
        try check(!HorizontalScrollRouting.hasHorizontalOverflow(in: scroll), "short row was treated as overflowing")
        document.setFrameSize(.init(width: 900, height: 180))
        try check(HorizontalScrollRouting.hasHorizontalOverflow(in: scroll), "wide row overflow was not detected")
        scroll.hasHorizontalScroller = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        let fixtureWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 180),
                                     styleMask: .borderless, backing: .buffered, defer: true)
        fixtureWindow.isReleasedWhenClosed = false
        fixtureWindow.contentView = scroll
        defer { fixtureWindow.close() }
        func deliveredOffset(_ event: NSEvent) -> CGFloat {
            scroll.contentView.scroll(to: .init(x: 300, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.scrollWheel(with: event)
            // AppKit may settle a wheel on its animation timer. The window stays hidden;
            // events are delivered only to this fixture scroll view, never posted globally.
            let deadline = Date().addingTimeInterval(0.2)
            while scroll.contentView.bounds.origin.x == 300 && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            return scroll.contentView.bounds.origin.x
        }
        let nativeOffset = deliveredOffset(try wheel(vertical: 0, horizontal: -3))
        try check(nativeOffset != 300,
                  "direct native horizontal scroll did not move fixture document (offset=\(nativeOffset))")
        let remappedOffset = deliveredOffset(horizontalLine)
        try check(remappedOffset != 300,
                  "direct remapped vertical scroll did not move fixture document (offset=\(remappedOffset))")
        try check((nativeOffset - 300) * (remappedOffset - 300) > 0,
                  "native/remapped identical horizontal deltas moved in different directions (\(nativeOffset), \(remappedOffset))")
        document.setFrameSize(.init(width: scroll.contentView.bounds.width, height: 180))
        try check(!HorizontalScrollRouting.hasHorizontalOverflow(in: scroll), "fitting row swallowed scrolling")
        scroll.documentView = nil
        try check(!HorizontalScrollRouting.hasHorizontalOverflow(in: scroll), "missing document swallowed scrolling")
        return count
    }
}
#endif
