#if DEBUG
import AppKit
import PasteCore

@MainActor
enum SessionStateChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: message) }
            count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-session-tests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init("com.gaoxs.pasteboard.session-tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let bridge = ClipboardBridge(pasteboard: board)
        let repository = SnapshotRepository(directory: directory)
        let first = ClipItem(text: "first", kind: .text)
        let second = ClipItem(text: "second", kind: .text)
        var initial = ClipboardSnapshot(items: [first, second])
        initial.preferences.pasteToFrontmost = false
        try repository.save(initial)
        let model = AppModel(storageDirectory: directory, bridge: bridge)
        try check(model.snapshot.session == nil && model.stackItems.isEmpty, "legacy session changed history")
        model.setStack([second, first])
        model.setStackReversed(true)
        model.pause(minutes: nil)
        model.flushPersistence()
        let reloaded = AppModel(storageDirectory: directory, bridge: bridge)
        try check(reloaded.stackItems.map(\.id) == [second.id, first.id] && reloaded.stackReversed, "stack order or reversal not restored")
        try check(reloaded.isPaused && reloaded.pauseUntil == nil, "indefinite pause not restored")
        reloaded.pasteNextStack()
        reloaded.flushPersistence()
        try check(try repository.load().session?.stackItemIDs == [second.id], "successful stack consumption not persisted")
        try check(board.string(forType: .string) == "first", "reversed stack consumed wrong item")
        reloaded.resume()
        reloaded.pause(minutes: 5)
        reloaded.flushPersistence()
        let timed = AppModel(storageDirectory: directory, bridge: bridge)
        try check(timed.isPaused && timed.pauseUntil != nil, "timed pause not restored")
        timed.resume()
        timed.flushPersistence()
        try check(try repository.load().session?.pauseUntil == nil && !timed.isPaused, "resume not persisted")
        timed.setStack([first, second])
        timed.commit(SnapshotOperations.deleteItems(ids: [first.id], in: timed.snapshot), action: "test delete")
        try check(timed.stackItems.map(\.id) == [second.id], "deleted stack reference survived")
        timed.undo()
        try check(timed.stackItems.map(\.id) == [second.id], "undo resurrected consumed stack state")
        timed.flushPersistence()
        var imported = ClipboardSnapshot(items: [first], session: .init(stackItemIDs: [first.id], pauseUntil: Date().addingTimeInterval(-1)))
        imported.preferences.pasteToFrontmost = false
        timed.commit(imported, action: "test import")
        try check(timed.stackItems.map(\.id) == [first.id] && !timed.isPaused, "import did not reconcile session")
        timed.flushPersistence()
        let image = ClipItem(text: "", kind: .image, representations: [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([1, 2, 3]))])
        var imageState = ClipboardSnapshot(items: [image])
        imageState.preferences.pasteToFrontmost = false
        imageState.preferences.alwaysPlainText = true
        timed.commit(imageState, action: "test failed paste")
        timed.setStack([image])
        timed.pasteNextStack()
        timed.flushPersistence()
        let afterFailedPaste = try repository.load()
        try check(timed.stackItems.map(\.id) == [image.id] && afterFailedPaste.session?.stackItemIDs == [image.id], "failed paste consumed stack entry")
        let savedBeforeDemo = try repository.load()
        let demo = AppModel(isDemo: true, storageDirectory: directory, bridge: bridge)
        demo.setStack(Array(demo.snapshot.items.prefix(2)))
        demo.pause(minutes: nil)
        demo.flushPersistence()
        try check(try repository.load() == savedBeforeDemo, "demo changed real session file")
        return count
    }
}
#endif
