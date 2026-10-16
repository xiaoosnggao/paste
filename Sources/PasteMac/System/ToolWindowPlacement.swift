import AppKit

struct ToolWindowPlacement {
    static func origin(size: CGSize, saved: CGPoint?, screens: [CGRect], defaultScreen: CGRect) -> CGPoint {
        let centered = CGPoint(x: size.width <= defaultScreen.width ? defaultScreen.midX - size.width / 2 : defaultScreen.minX,
                               y: size.height <= defaultScreen.height ? defaultScreen.midY - size.height / 2 : defaultScreen.maxY - size.height)
        guard let saved, saved.x.isFinite, saved.y.isFinite else { return centered }
        let frame = CGRect(origin: saved, size: size)
        let available = screens.isEmpty ? [defaultScreen] : screens
        let ranked = available.map { screen -> (CGRect, CGFloat) in
            let overlap = screen.intersection(frame)
            return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return centered }
        let screen = best.0
        return CGPoint(x: size.width > screen.width ? screen.minX : min(max(saved.x, screen.minX), screen.maxX - size.width),
                       y: size.height > screen.height ? screen.maxY - size.height : min(max(saved.y, screen.minY), screen.maxY - size.height))
    }
}

/// Written only by the translation window's move delegate; independent of clipboard data.
final class ToolWindowPositionStore {
    private struct Position: Codable { let x: Double; let y: Double }
    private let defaults: UserDefaults
    private let key = "toolWindowUserPosition.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> CGPoint? {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Position.self, from: data),
              value.x.isFinite, value.y.isFinite else { return nil }
        return CGPoint(x: value.x, y: value.y)
    }
    func save(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite,
              let data = try? JSONEncoder().encode(Position(x: point.x, y: point.y)) else { return }
        defaults.set(data, forKey: key)
    }
}

#if DEBUG
@MainActor
enum ToolWindowPlacementChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: "Tool placement: " + message) }; count += 1
        }
        let screen = CGRect(x: 0, y: 24, width: 1440, height: 850), size = CGSize(width: 640, height: 480)
        try check(ToolWindowPlacement.origin(size: size, saved: nil, screens: [screen], defaultScreen: screen) == CGPoint(x: 400, y: 209), "initial window not centered on both axes")
        let moved = CGPoint(x: 103, y: 81)
        try check(ToolWindowPlacement.origin(size: size, saved: moved, screens: [screen], defaultScreen: screen) == moved, "user position reset")
        let upper = CGRect(x: -300, y: 1000, width: 1800, height: 1000)
        try check(ToolWindowPlacement.origin(size: size, saved: nil, screens: [screen, upper], defaultScreen: upper) == CGPoint(x: 280, y: 1260), "upper screen default incorrect")
        try check(ToolWindowPlacement.origin(size: size, saved: CGPoint(x: -240, y: 1200), screens: [screen, upper], defaultScreen: screen) == CGPoint(x: -240, y: 1200), "negative origin position lost")
        try check(ToolWindowPlacement.origin(size: size, saved: CGPoint(x: -240, y: 1200), screens: [screen], defaultScreen: screen) == CGPoint(x: 400, y: 209), "disconnected screen not recovered")
        try check(ToolWindowPlacement.origin(size: size, saved: CGPoint(x: 1300, y: 800), screens: [screen], defaultScreen: screen) == CGPoint(x: 800, y: 394), "partially offscreen not clamped")
        try check(ToolWindowPlacement.origin(size: size, saved: CGPoint(x: CGFloat.nan, y: 0), screens: [screen], defaultScreen: screen) == CGPoint(x: 400, y: 209), "invalid saved coordinate accepted")
        let tiny = CGRect(x: 0, y: 0, width: 500, height: 300)
        try check(ToolWindowPlacement.origin(size: size, saved: CGPoint(x: 10, y: 10), screens: [tiny], defaultScreen: tiny) == CGPoint(x: 0, y: -180), "oversized window titlebar offscreen")
        let suite = "placement-check-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ToolWindowPositionStore(defaults: defaults)
        try check(first.load() == nil, "fresh install has saved position")
        first.save(moved)
        try check(ToolWindowPositionStore(defaults: defaults).load() == moved, "position not persisted across store instances")
        return count
    }
}
#endif
