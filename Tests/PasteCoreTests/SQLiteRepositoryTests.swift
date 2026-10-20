import XCTest
@testable import PasteCore

final class SQLiteRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func item(_ text: String) -> ClipItem { .init(text: text, kind: .text) }
    func testMigrationPreservesOldHistoryAndBackupAndDoesNotRepeat() throws {
        let folder = try directory()
        let old = ClipboardSnapshot(items: [item("很久以前的数据库报价")])
        let original = try JSONEncoder().encode(old)
        try original.write(to: folder.appendingPathComponent("clipboard.json"))
        let repository = SnapshotRepository(directory: folder)
        XCTAssertEqual(try repository.load(), old)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("clipboard.pre-sqlite.json")), original)
        try repository.save(.init())
        XCTAssertTrue(try SnapshotRepository(directory: folder).load().items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("clipboard.json")), original)
    }
    func testMoreThanTenThousandItemsPagingAndChineseSubstring() throws {
        let repository = SnapshotRepository(directory: try directory())
        var items = (0..<10_001).map { item("记录 \($0)") }
        items[9_999].text = "项目数据库迁移报价"
        try repository.save(.init(items: items))
        XCTAssertEqual(try repository.itemCount(), 10_001)
        XCTAssertEqual(try repository.loadItems(limit: 3, offset: 9_998).count, 3)
        XCTAssertEqual(try repository.loadItems(limit: 10, query: "据库").map(\.id), [items[9_999].id])
        XCTAssertEqual(try repository.loadItems(ids: [items[0].id, items[10_000].id]).count, 2)
    }
    func testBoundedChangesRetainUnloadedRowsAndDeleteOnlyExplicitIDs() throws {
        let repository = SnapshotRepository(directory: try directory())
        let first = item("one"), second = item("two")
        try repository.save(.init(items: [first, second]))
        var updated = first; updated.text = "changed"
        let metadata = try repository.loadMetadata()
        XCTAssertTrue(metadata.items.isEmpty)
        try repository.applyChanges(metadata: metadata, upserting: [updated], deleting: [])
        XCTAssertEqual(try repository.itemCount(), 2)
        XCTAssertEqual(try repository.loadItems(ids: [first.id]).first?.text, "changed")
        try repository.applyChanges(metadata: metadata, upserting: [], deleting: [second.id])
        XCTAssertEqual(try repository.itemCount(), 1)
    }
    func testPermanentCaptureIgnoresLegacyRetentionAndByteCaps() throws {
        var snapshot = ClipboardSnapshot(items: [item("old")])
        snapshot.items[0].lastCopiedAt = Date(timeIntervalSince1970: 1)
        snapshot.preferences.retentionDays = 1; snapshot.preferences.maxHistoryItems = 1
        snapshot = SnapshotOperations.capture(item("new"), in: snapshot)
        XCTAssertEqual(snapshot.items.count, 2)
    }
    func testBinaryAssetsRoundtripAndMissingAssetFailsExplicitly() throws {
        let folder = try directory(), repository = SnapshotRepository(directory: folder)
        let binary = Data(repeating: 128, count: 70_000)
        let value = ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: binary)])
        try repository.save(.init(items: [value]))
        XCTAssertEqual(try repository.load().items, [value])
        let assets = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        XCTAssertEqual(assets.count, 1)
        try FileManager.default.removeItem(at: assets[0])
        XCTAssertThrowsError(try repository.load())
    }
    func testTransactionalJobsAndFailedDeltaRollback() throws {
        let repository = SnapshotRepository(directory: try directory())
        let first = item("one")
        try repository.save(.init(items: [first]))
        let database = try SQLiteDatabase(url: repository.databaseURL)
        var originalToken = ""
        try database.rows("SELECT fingerprint FROM knowledge_jobs WHERE item_id=?", [.text(first.id.uuidString)]) { originalToken = SQLiteDatabase.text($0, 0) }
        try database.execute("UPDATE knowledge_jobs SET state='ready'")
        try repository.applyChanges(metadata: try repository.loadMetadata(), upserting: [first], deleting: [])
        var state = ""
        try database.rows("SELECT state FROM knowledge_jobs WHERE item_id=?", [.text(first.id.uuidString)]) { state = SQLiteDatabase.text($0, 0) }
        XCTAssertEqual(state, "ready")
        var changed = first; changed.enrichment = .init(ocr: .init(text: "new OCR"))
        try repository.applyChanges(metadata: try repository.loadMetadata(), upserting: [changed], deleting: [])
        try database.rows("SELECT state FROM knowledge_jobs WHERE item_id=?", [.text(first.id.uuidString)]) { state = SQLiteDatabase.text($0, 0) }
        XCTAssertEqual(state, "pending")
        var newToken = ""
        try database.rows("SELECT fingerprint FROM knowledge_jobs WHERE item_id=?", [.text(first.id.uuidString)]) { newToken = SQLiteDatabase.text($0, 0) }
        XCTAssertNotEqual(originalToken, newToken, "OCR changes invalidate a running index job even when clipboard payload identity is unchanged")
        var invalid = try repository.loadMetadata()
        invalid.pinboards = [.init(name: "missing", itemIDs: [UUID()])]
        let addition = item("must rollback")
        XCTAssertThrowsError(try repository.applyChanges(metadata: invalid, upserting: [addition], deleting: [first.id]))
        XCTAssertEqual(try repository.load().items, [changed])
        var count = 0
        try database.rows("SELECT COUNT(*) FROM knowledge_jobs") { count += Int(SQLiteDatabase.text($0, 0)) ?? 0 }
        XCTAssertEqual(count, 1)
        try repository.applyChanges(metadata: try repository.loadMetadata(), upserting: [], deleting: [first.id])
        try database.rows("SELECT COUNT(*) FROM knowledge_jobs") { count = Int(SQLiteDatabase.text($0, 0)) ?? -1 }
        XCTAssertEqual(count, 0)
    }
    func testMetadataOnlyKeepsIdentityAndDoesNotReadAssets() throws {
        let folder = try directory(), repository = SnapshotRepository(directory: folder)
        let value = ClipItem(text: "image", kind: .image, representations: [.init(type: "public.png", data: Data([1,2,3]))])
        try repository.save(.init(items: [value]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("assets"))
        let summary = try XCTUnwrap(repository.loadItems(limit: 1, includePayload: false).first)
        XCTAssertEqual(summary.fingerprint, value.fingerprint)
        XCTAssertTrue(summary.representations.isEmpty)
        XCTAssertThrowsError(try repository.loadItems(ids: [value.id]))
    }
    func testBoardPagingOrderFiltersAndIncrementalEditOrder() throws {
        let repository = SnapshotRepository(directory: try directory())
        let first = item("alpha"), second = item("alpha second"), third = item("third")
        let board = Pinboard(name: "ordered", itemIDs: [third.id, second.id, first.id])
        try repository.save(.init(items: [first, second, third], pinboards: [board]))
        XCTAssertEqual(try repository.loadItems(limit: 1, offset: 1, pinboardID: board.id).map(\.id), [second.id])
        XCTAssertEqual(try repository.loadItems(limit: 5, query: "alpha", pinboardID: board.id).map(\.id), [second.id, first.id])
        var changed = third; changed.title = "edit without promotion"
        try repository.applyChanges(metadata: try repository.loadMetadata(), upserting: [changed], deleting: [])
        XCTAssertEqual(try repository.loadItems(limit: 3).map(\.id), [first.id, second.id, third.id])
        changed.lastCopiedAt = Date().addingTimeInterval(10)
        try repository.applyChanges(metadata: try repository.loadMetadata(), upserting: [changed], deleting: [])
        XCTAssertEqual(try repository.loadItems(limit: 3).first?.id, third.id)
        XCTAssertTrue(try repository.loadItems(limit: 3, filter: .init(until: Date(timeIntervalSince1970: 1))).isEmpty)
    }
    func testSourceFilterRunsBeforePaginationAndRetainsKeywordCount() throws {
        let repository = SnapshotRepository(directory: try directory())
        let unrelated = (0..<60).map { item("报价 \($0)") }
        let match = ClipItem(text: "数据库报价", kind: .text, sourceBundleID: "com.tencent.xinWeChat", sourceName: "WeChat")
        try repository.save(.init(items: unrelated + [match]))
        XCTAssertEqual(try repository.loadItems(limit: 5, query: "报价", filter: .init(sourceName: "微信")).map(\.id), [match.id])
        XCTAssertEqual(try repository.itemCount(query: "报价"), 61)
    }

}
