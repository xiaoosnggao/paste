import CoreGraphics

/// Where the 连续粘贴 capsule sits relative to the mouse.
///
/// The capsule follows the cursor only at discrete moments: when it is shown
/// and after each 粘贴下一项. It never tracks the mouse continuously, because a
/// window that moves while you aim at its button can't be clicked, and the
/// cursor usually rests on the target app's insertion point between pastes.
/// When its size changes (list expanded or collapsed) the top-left corner stays
/// put and the frame is clamped again.
///
/// All values are in AppKit screen coordinates (origin bottom-left, y up).
enum StackCapsulePlacement {
    /// Gap between the cursor and the capsule's nearest corner.
    static let cursorGap: CGFloat = 16
    /// Minimum distance from the edges of the visible screen frame.
    static let screenMargin: CGFloat = 8

    /// Frame for a capsule of `size` shown near `mouse` on a screen whose
    /// visible frame (menu bar and Dock removed) is `visible`.
    ///
    /// The capsule goes below and to the right of the cursor. If that would run
    /// off the right or bottom edge it flips to the other side of the cursor
    /// rather than sliding underneath it; the result is then clamped.
    static func frame(size: CGSize, mouse: CGPoint, visible: CGRect) -> CGRect {
        var x = mouse.x + cursorGap
        var y = mouse.y - cursorGap - size.height
        if x + size.width > visible.maxX - screenMargin { x = mouse.x - cursorGap - size.width }
        if y < visible.minY + screenMargin { y = mouse.y + cursorGap }
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), to: visible)
    }

    /// Frame after a resize that keeps `topLeft` fixed, clamped to `visible`.
    static func resized(_ size: CGSize, topLeft: CGPoint, visible: CGRect) -> CGRect {
        clamp(CGRect(origin: CGPoint(x: topLeft.x, y: topLeft.y - size.height), size: size), to: visible)
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: screenMargin, dy: screenMargin)
        var origin = frame.origin
        // When the capsule is wider or taller than the screen, pin its top-left.
        origin.x = frame.width > inner.width ? inner.minX : min(max(origin.x, inner.minX), inner.maxX - frame.width)
        origin.y = frame.height > inner.height ? inner.maxY - frame.height : min(max(origin.y, inner.minY), inner.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}
