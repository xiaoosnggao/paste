#if DEBUG
import AppKit

@MainActor
enum SelectedTextChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Selected text: \(message)" }
    }
    @MainActor private final class Fixture {
        var trusted = true
        var pid: pid_t? = 42
        var selected: SelectedTextCapture.AXSelection = .text("原始选中文字")
        var count = 7
        var clipboard = "original clipboard"
        var original = "original clipboard"
        var copies = 0
        var restores = 0
        var polls = 0
        var copyAllowed = true
        var snapshotAllowed = true
        var afterSelection: (() -> Void)?
        var onPause: (() throws -> Void)?
        func make() -> SelectedTextCapture {
            SelectedTextCapture(dependencies: .init(trusted: { self.trusted }, ownPID: 1,
                frontmostPID: { self.pid }, selectedText: { _ in self.afterSelection?(); return self.selected },
                snapshot: {
                    guard self.snapshotAllowed else { throw SelectedTextCapture.CaptureError.clipboardUnavailable }
                    return .init(count: self.count, items: [["public.utf8-plain-text": Data(self.clipboard.utf8)]])
                }, changeCount: { self.count }, text: { self.clipboard }, restore: { saved, expected in
                    guard self.count == expected else { return }
                    self.clipboard = String(data: saved.items[0]["public.utf8-plain-text"]!, encoding: .utf8)!
                    self.count += 1; self.restores += 1
                }, copy: { _ in self.copies += 1; return self.copyAllowed }, pause: {
                    self.polls += 1; try self.onPause?()
                }))
        }
    }
    static func run() async throws -> Int {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; assertions += 1
        }
        func fails(_ fixture: Fixture) async -> Bool {
            do { _ = try await fixture.make().capture(); return false } catch { return true }
        }
        let ax = Fixture()
        let text = try await ax.make().capture()
        try check(text == "原始选中文字" && ax.copies == 0 && ax.restores == 0, "AX path touched clipboard or altered selection")
        let permission = Fixture(); permission.trusted = false
        try check(await fails(permission) && permission.copies == 0, "permission denial dispatched Copy")
        let own = Fixture(); own.pid = 1
        try check(await fails(own) && own.copies == 0, "own app accepted as source")
        let missing = Fixture(); missing.pid = nil
        try check(await fails(missing), "missing source accepted")
        let secure = Fixture(); secure.selected = .secureField
        try check(await fails(secure) && secure.copies == 0, "password field triggered fallback Copy")
        let moved = Fixture(); moved.afterSelection = { moved.pid = 99 }
        try check(await fails(moved) && moved.copies == 0, "changed target accepted AX text")
        let copy = Fixture(); copy.selected = .unavailable
        copy.onPause = { if copy.polls == 1 { copy.count += 1; copy.clipboard = "copied selection" } }
        let copied = try await copy.make().capture()
        try check(copied == "copied selection" && copy.copies == 1 && copy.restores == 1 && copy.clipboard == copy.original, "Copy fallback failed to restore original")
        let timeout = Fixture(); timeout.selected = .unavailable
        try check(await fails(timeout) && timeout.polls == 30 && timeout.restores == 0, "unchanged clipboard returned stale text or polled without bound")
        let race = Fixture(); race.selected = .unavailable
        race.onPause = { race.count += 1; race.clipboard = race.polls == 1 ? "selection" : "new user copy" }
        try check(await fails(race) && race.restores == 0 && race.clipboard == "new user copy", "newer user clipboard overwritten or translated")
        let cannotSnapshot = Fixture(); cannotSnapshot.selected = .unavailable; cannotSnapshot.snapshotAllowed = false
        try check(await fails(cannotSnapshot) && cannotSnapshot.copies == 0, "incomplete clipboard snapshot dispatched Copy")
        let cannotCopy = Fixture(); cannotCopy.selected = .unavailable; cannotCopy.copyAllowed = false
        try check(await fails(cannotCopy) && cannotCopy.restores == 0, "failed dispatch modified clipboard")
        let cancelled = Fixture(); cancelled.selected = .unavailable
        cancelled.onPause = { throw CancellationError() }
        try check(await fails(cancelled) && cancelled.restores == 0, "cancelled wait returned clipboard")
        let changedDuringCopy = Fixture(); changedDuringCopy.selected = .unavailable
        changedDuringCopy.onPause = { changedDuringCopy.pid = 99 }
        try check(await fails(changedDuringCopy) && changedDuringCopy.restores == 0, "source change during Copy accepted")
        let tooLarge = Fixture(); tooLarge.selected = .text(String(repeating: "a", count: 2 * 1024 * 1024 + 1))
        try check(await fails(tooLarge) && tooLarge.copies == 0, "oversized AX text accepted")
        let whitespace = Fixture(); whitespace.selected = .text("  \n")
        try check(await fails(whitespace) && whitespace.copies == 1, "empty AX text accepted without selection fallback")
        let preserve = "  exact\n原文  "
        try check(try SelectedTextCapture.validated(preserve) == preserve, "selection whitespace changed")
        // A named pasteboard exercises real format/item preservation without reading
        // or changing the user’s general clipboard.
        let board = NSPasteboard(name: .init("Pasteboard.SelectedText.Tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([0, 1, 2, 255]), forType: .init("com.gaoxs.pasteboard.selected-text-test"))
        let second = NSPasteboardItem(); second.setString("second", forType: .string)
        board.clearContents()
        try check(board.writeObjects([first, second]), "named clipboard setup failed")
        let saved = try SelectedTextCapture.snapshot(board)
        try check(saved.items.count == 2 && saved.items[0]["com.gaoxs.pasteboard.selected-text-test"] == Data([0, 1, 2, 255]), "native snapshot dropped representations")
        board.clearContents(); board.setString("temporary selection", forType: .string)
        SelectedTextCapture.restore(saved, to: board, expectedCount: board.changeCount)
        let restored = try SelectedTextCapture.snapshot(board)
        try check(restored.items == saved.items, "native restore altered original item boundaries or bytes")
        let previous = board.changeCount
        board.clearContents(); board.setString("new user clipboard", forType: .string)
        SelectedTextCapture.restore(saved, to: board, expectedCount: previous)
        try check(board.string(forType: .string) == "new user clipboard", "native restore overwrote a newer clipboard")
        return assertions
    }
}
#endif
