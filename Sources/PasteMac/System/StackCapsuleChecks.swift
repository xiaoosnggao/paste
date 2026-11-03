#if DEBUG
import AppKit
import PasteCore

/// Pure checks for the 连续粘贴 capsule's placement and paste order.
enum StackCapsuleChecks {
    @MainActor
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Stack capsule: \(message)") }
            count += 1
        }
        typealias P = StackCapsulePlacement
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let size = CGSize(width: 360, height: 52)
        let inner = screen.insetBy(dx: P.screenMargin, dy: P.screenMargin)

        let middle = P.frame(size: size, mouse: CGPoint(x: 600, y: 500), visible: screen)
        try check(middle.minX == 600 + P.cursorGap && middle.maxY == 500 - P.cursorGap,
                  "capsule was not placed below-right of the cursor")
        try check(!middle.contains(CGPoint(x: 600, y: 500)), "capsule covered the cursor")

        let right = P.frame(size: size, mouse: CGPoint(x: 1500, y: 500), visible: screen)
        try check(right.maxX == 1500 - P.cursorGap, "capsule near the right edge did not flip left of the cursor")
        try check(inner.contains(right), "capsule near the right edge left the screen")

        let bottom = P.frame(size: size, mouse: CGPoint(x: 600, y: 20), visible: screen)
        try check(bottom.minY == 20 + P.cursorGap, "capsule near the bottom did not flip above the cursor")
        try check(inner.contains(bottom), "capsule near the bottom left the screen")

        let corner = P.frame(size: size, mouse: CGPoint(x: 1510, y: 940), visible: screen)
        try check(inner.contains(corner), "capsule in the top-right corner left the screen")

        // A second display to the left with its own origin.
        let left = CGRect(x: -1440, y: 120, width: 1440, height: 870)
        let onLeft = P.frame(size: size, mouse: CGPoint(x: -20, y: 140), visible: left)
        try check(left.insetBy(dx: P.screenMargin, dy: P.screenMargin).contains(onLeft), "capsule left a secondary display")

        let expanded = CGSize(width: 360, height: 320)
        let grown = P.resized(expanded, topLeft: CGPoint(x: middle.minX, y: middle.maxY), visible: screen)
        try check(grown.minX == middle.minX && grown.maxY == middle.maxY, "expanding moved the capsule's top-left corner")
        let grownLow = P.resized(expanded, topLeft: CGPoint(x: bottom.minX, y: bottom.maxY), visible: screen)
        try check(inner.contains(grownLow), "expanding near the bottom left the screen")
        let huge = P.clamp(CGRect(x: 50, y: 50, width: 2000, height: 2000), to: screen)
        try check(huge.minX == inner.minX && huge.maxY == inner.maxY, "an oversized capsule was not pinned top-left")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-capsule-\(UUID())")
        let suite = "stack-capsule-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(isDemo: true, storageDirectory: root, bridge: ClipboardBridge(pasteboard: board), toolDefaults: defaults)
        let items = (1...3).map { ClipItem(text: "Stack \($0)", kind: .text, sourceBundleID: "test.source", sourceName: "Fixture") }
        model.snapshot = .init(items: items)
        model.setStack(items)
        try check(model.orderedStackItems.map(\.id) == items.map(\.id), "stack order changed")
        try check(model.stackPositions[items[0].id] == 1 && model.stackPositions[items[2].id] == 3,
                  "order badges did not follow paste order")
        model.setStackReversed(true)
        try check(model.orderedStackItems.first?.id == items[2].id && model.stackPositions[items[2].id] == 1,
                  "倒序粘贴 badges did not start from the last card")
        model.setStackReversed(false)
        model.setStack([])
        try check(model.stackPositions.isEmpty, "cleared stack kept badges")
        return count
    }
}
#endif
