#if DEBUG
import AppKit

@MainActor
enum ScreenshotChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "ScreenshotChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        let retina = try ScreenshotCoordinator.region(selection: CGRect(x: 10, y: 20, width: 100, height: 80), screenSize: CGSize(width: 1000, height: 800), scale: 2)
        try check(retina.sourceRect == CGRect(x: 10, y: 700, width: 100, height: 80), "bottom-left to top-left mapping failed")
        try check(retina.pixelWidth == 200 && retina.pixelHeight == 160, "Retina pixel mapping failed")
        for screen in [CGRect(x: -1440, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 900, width: 1440, height: 900), CGRect(x: 200, y: -900, width: 1440, height: 900)] {
            let local = ScreenshotCoordinator.localSelection(global: CGRect(x: screen.minX + 30, y: screen.minY + 40, width: 200, height: 100), screenFrame: screen)
            let region = try ScreenshotCoordinator.region(selection: local, screenSize: screen.size, scale: 1)
            try check(region.sourceRect == CGRect(x: 30, y: 760, width: 200, height: 100), "secondary display mapping failed")
        }
        let clipped = try ScreenshotCoordinator.region(selection: CGRect(x: -20, y: -10, width: 100, height: 60), screenSize: CGSize(width: 200, height: 200), scale: 2)
        try check(clipped.sourceRect == CGRect(x: 0, y: 150, width: 80, height: 50), "selection clipping failed")
        let fractional = try ScreenshotCoordinator.region(selection: CGRect(x: 1.2, y: 2.3, width: 10.2, height: 11.1), screenSize: CGSize(width: 100, height: 100), scale: 2)
        try check(fractional.pixelWidth == 21 && fractional.pixelHeight == 23, "fractional pixel alignment failed")
        for input in [CGRect.zero, CGRect(x: 0, y: 0, width: 1, height: 10), CGRect(x: 500, y: 500, width: 30, height: 30)] {
            do { _ = try ScreenshotCoordinator.region(selection: input, screenSize: CGSize(width: 100, height: 100), scale: 2); try check(false, "empty selection accepted") }
            catch ScreenshotCoordinator.Failure.emptySelection { count += 1 }
        }
        do { _ = try ScreenshotCoordinator.region(selection: CGRect(x: 0, y: 0, width: 5000, height: 4000), screenSize: CGSize(width: 5000, height: 4000), scale: 2); try check(false, "oversized screenshot accepted") }
        catch ScreenshotCoordinator.Failure.tooLarge { count += 1 }
        let reversed = try ScreenshotCoordinator.region(selection: CGRect(x: 100, y: 100, width: -50, height: -40), screenSize: CGSize(width: 200, height: 200), scale: 1)
        try check(reversed.sourceRect == CGRect(x: 50, y: 100, width: 50, height: 40), "reverse drag mapping failed")
        return count
    }

    /// No AppKit windows or screen permissions: exercise real async continuation ownership.
    static func runLifecycle() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "ScreenshotLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        func ready(_ gate: ScreenshotResultGate<Int>) async throws {
            for _ in 0..<1000 {
                if gate.isWaiting { return }
                await Task.yield()
            }
            throw NSError(domain: "ScreenshotLifecycle", code: 2)
        }
        let gate = ScreenshotResultGate<Int>()
        let oldToken = UUID()
        var oldCompletion: (@MainActor (Result<Int, Error>) -> Void)?
        let first = Task { @MainActor in try await gate.wait(token: oldToken, timeoutNanoseconds: nil) { oldCompletion = $0 } }
        try await ready(gate)
        gate.cancel(token: oldToken)
        try check(!gate.isWaiting, "cancel did not immediately release pending continuation")
        do { _ = try await first.value; try check(false, "cancel returned a value") }
        catch ScreenshotCoordinator.Failure.cancelled { count += 1 }
        let newToken = UUID()
        var newCompletion: (@MainActor (Result<Int, Error>) -> Void)?
        let second = Task { @MainActor in try await gate.wait(token: newToken, timeoutNanoseconds: nil) { newCompletion = $0 } }
        try await ready(gate)
        oldCompletion?(.success(99))
        gate.cancel(token: oldToken)
        try check(gate.isWaiting, "late callback or old cancellation consumed newer request")
        newCompletion?(.success(7))
        newCompletion?(.success(9))
        try check(try await second.value == 7, "request completed more than once")
        try check(!gate.isWaiting, "completion did not release gate")
        do {
            _ = try await gate.wait(token: UUID(), timeoutNanoseconds: 1_000_000) { _ in }
            try check(false, "timeout returned a value")
        } catch ScreenshotCoordinator.Failure.timedOut { count += 1 }
        try check(!gate.isWaiting, "timeout left gate busy")
        let synchronous = try await gate.wait(token: UUID(), timeoutNanoseconds: 1_000_000_000) { $0(.success(44)) }
        try check(synchronous == 44 && !gate.isWaiting, "synchronous callback ownership failed")
        let busyToken = UUID()
        let busy = Task { @MainActor in try await gate.wait(token: busyToken, timeoutNanoseconds: nil) { _ in } }
        try await ready(gate)
        do {
            _ = try await gate.wait(token: UUID(), timeoutNanoseconds: nil) { $0(.success(1)) }
            try check(false, "concurrent wait replaced earlier continuation")
        } catch ScreenshotCoordinator.Failure.busy { count += 1 }
        gate.cancel(token: busyToken)
        do { _ = try await busy.value; try check(false, "busy owner was not cancelled") }
        catch ScreenshotCoordinator.Failure.cancelled { count += 1 }
        return count
    }

}
#endif
