#if DEBUG
import AppKit
import PasteCore

@MainActor
enum AppModelHistoryChecks {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Paged history: \(message)") }; checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-history-check-\(UUID())")
        let suite = "pasteboard-history-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSince1970: 1_000_000)
        let items = (0..<123).map { index in
            ClipItem(createdAt: old, lastCopiedAt: old, text: index == 122 ? "报价 unique-tail-knowledge-fixture" : "报价 history-fixture-\(index)", kind: .text, sourceBundleID: index == 122 ? "com.tencent.xinWeChat" : "fixture.source", sourceName: index == 122 ? "WeChat" : "Synthetic")
        }
        var initial = ClipboardSnapshot(items: items)
        initial.preferences.retentionDays = 1; initial.preferences.maxHistoryItems = 1
        let repository = SnapshotRepository(directory: directory)
        try repository.save(initial)
        let model = AppModel(storageDirectory: directory, bridge: ClipboardBridge(pasteboard: board), toolDefaults: defaults)
        defer { model.historyQueryTask?.cancel(); model.flushPersistence() }
        try check(!model.corruptStore && model.historyTotalCount == 123, "startup lost old records")
        try check(model.visibleItems.count == 50 && model.snapshot.items.count <= 50, "startup eagerly loaded the full history")
        try check(try repository.itemCount() == 123, "legacy retention preference pruned stored rows")
        model.queryString = "unique-tail-knowledge-fixture"
        await model.historyQueryTask?.value
        try check(model.visibleItems.map(\.id) == [items[122].id], "search excluded an unloaded record")
        try check(try repository.itemCount() == 123, "search replaced stored history with a result page")
        model.queryString = "从微信复制的报价"
        await model.historyQueryTask?.value
        try check(model.visibleItems.map(\.id) == [items[122].id], "source filtering happened after result pagination")
        model.queryString = ""
        await model.historyQueryTask?.value
        try check(model.visibleItems.count == 50, "clearing search did not restore the first page")
        try check(model.saveText("new-history-fixture", title: "", item: nil), "new record could not be saved")
        model.flushPersistence()
        try check(try repository.itemCount() == 124, "saving a window removed unloaded rows")
        try check(try repository.loadItems(ids: [items[122].id]).count == 1, "saving lost the last history page")
        guard let added = model.snapshot.items.first(where: { $0.text == "new-history-fixture" }) else { throw SystemChecks.Failure(message: "new record not visible") }
        model.undoManager.removeAllActions() // Start a distinct user action after fixture creation.
        try check(model.commit(SnapshotOperations.deleteItems(ids: [added.id], in: model.snapshot), action: "fixture deletion"), "delete failed")
        model.flushPersistence()
        try check(try repository.itemCount() == 123, "deletion changed unrelated history rows")
        model.undo(); model.flushPersistence()
        try check(try repository.itemCount() == 124 && repository.loadItems(ids: [added.id]).count == 1, "undo failed to restore only the affected record")
        try check(try repository.loadItems(ids: [items[122].id]).count == 1, "undo rewrote the database from a partial window")
        return checks
    }
}
#endif
