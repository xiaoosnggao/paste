import CoreGraphics

/// Where the editor, preview, stack and other secondary windows open.
///
/// The clipboard panel sits at the bottom of the screen at status-bar level,
/// above every normal or floating window. Centering a secondary window on the
/// screen therefore hid its lower part, usually the Cancel and Save buttons,
/// behind the panel. These windows now open in the space above the panel.
enum AuxiliaryWindowPlacement {
    /// Gap kept between a secondary window and the top of the panel.
    static let panelGap: CGFloat = 12

    /// - Parameters:
    ///   - size: The window's frame size.
    ///   - visibleFrame: The target screen's visible frame (menu bar and Dock excluded).
    ///   - panelFrame: The clipboard panel's frame while it is on screen, otherwise nil.
    static func origin(size: CGSize, visibleFrame: CGRect, avoiding panelFrame: CGRect?) -> CGPoint {
        var available = visibleFrame
        if let panelFrame, panelFrame.intersects(visibleFrame) {
            let floor = min(max(visibleFrame.minY, panelFrame.maxY + panelGap), visibleFrame.maxY)
            available = CGRect(x: visibleFrame.minX, y: floor, width: visibleFrame.width, height: visibleFrame.maxY - floor)
        }
        let x = size.width <= visibleFrame.width ? (visibleFrame.midX - size.width / 2).rounded() : visibleFrame.minX
        let y: CGFloat
        if size.height <= available.height {
            // Centered in the free space above the panel.
            y = (available.midY - size.height / 2).rounded()
        } else {
            // Too tall to clear the panel: keep the title bar on screen and
            // overlap the panel as little as possible.
            y = visibleFrame.maxY - size.height
        }
        return CGPoint(x: x, y: y)
    }
}

#if DEBUG
enum AuxiliaryWindowPlacementChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Window placement: " + message) }; count += 1
        }
        // 1440×900 screen with a 25pt menu bar; the panel is 320pt tall, 8pt from the bottom.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let panel = CGRect(x: 8, y: 8, width: 1424, height: 320)
        let editor = CGSize(width: 560, height: 420)
        let placed = AuxiliaryWindowPlacement.origin(size: editor, visibleFrame: screen, avoiding: panel)
        try check(placed.y >= panel.maxY + AuxiliaryWindowPlacement.panelGap, "editor overlaps the panel: \(placed)")
        try check(placed.y + editor.height <= screen.maxY, "editor title bar off screen: \(placed)")
        try check(placed.x == 440, "editor not centered horizontally: \(placed)")
        let centered = AuxiliaryWindowPlacement.origin(size: editor, visibleFrame: screen, avoiding: nil)
        try check(centered == CGPoint(x: 440, y: 228), "hidden panel should center on screen: \(centered)")
        let tall = CGSize(width: 620, height: 640)
        let tallOrigin = AuxiliaryWindowPlacement.origin(size: tall, visibleFrame: screen, avoiding: panel)
        try check(tallOrigin.y == screen.maxY - tall.height, "tall window not pinned below the menu bar: \(tallOrigin)")
        // Panel on another screen does not move this window.
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let elsewhere = AuxiliaryWindowPlacement.origin(size: editor, visibleFrame: screen, avoiding: other.offsetBy(dx: 8, dy: 8))
        try check(elsewhere == centered, "panel on another screen moved the window: \(elsewhere)")
        // Negative-origin secondary screen.
        let left = CGRect(x: -1280, y: 100, width: 1280, height: 775)
        let leftPanel = CGRect(x: -1272, y: 108, width: 1264, height: 320)
        let leftOrigin = AuxiliaryWindowPlacement.origin(size: editor, visibleFrame: left, avoiding: leftPanel)
        try check(leftOrigin.y >= leftPanel.maxY + AuxiliaryWindowPlacement.panelGap && leftOrigin.x == -920,
                  "negative-origin screen placement wrong: \(leftOrigin)")
        return count
    }
}
#endif
