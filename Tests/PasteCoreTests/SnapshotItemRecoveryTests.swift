import XCTest
@testable import PasteCore

final class SnapshotItemRecoveryTests: XCTestCase {
    private func repository() throws -> SnapshotRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SnapshotRepository(directory: directory)
    }
    func testArchivedRichItemsRestoreWithoutReadingAssetsAndRebuildSearch() throws {
        let repository = try repository()
        let item = ClipItem(text: "恢复报价", kind: .text, representations: [.init(type: "public.rtf", data: Data([0,255,1]))])
        try repository.save(.init(items: [item]))
        let token = try repository.archiveItems(ids: [item.id])
        try repository.applyChanges(metadata: .init(), upserting: [], deleting: [item.id])
        let assets = repository.databaseURL.deletingLastPathComponent().appendingPathComponent("assets")
        let hidden = assets.appendingPathExtension("hidden")
        try FileManager.default.moveItem(at: assets, to: hidden)
        XCTAssertEqual(try repository.restoreArchivedItems(token: token), [item.id])
        XCTAssertEqual(try repository.itemCount(query: "不存在"), 0)
        XCTAssertEqual(try repository.itemCount(query: "报价"), 1)
        XCTAssertEqual(try repository.loadItems(limit: 1, includePayload: false).first?.fingerprint, item.fingerprint)
        try FileManager.default.moveItem(at: hidden, to: assets)
        XCTAssertEqual(try repository.load().items, [item])
        let database = try SQLiteDatabase(url: repository.databaseURL)
        var state = ""
        try database.rows("SELECT state FROM knowledge_jobs") { state = SQLiteDatabase.text($0, 0) }
        XCTAssertEqual(state, "pending")
        XCTAssertTrue(try repository.restoreArchivedItems(token: token).isEmpty)
    }
    func testRestoreNeverOverwritesLaterEditsAndRetainsCaptureOrder() throws {
        let repository = try repository()
        let first = ClipItem(text: "first", kind: .text), second = ClipItem(text: "second", kind: .text)
        try repository.save(.init(items: [first, second]))
        let token = try repository.archiveItems(ids: [first.id, second.id])
        var changed = first; changed.text = "later edit"
        let captured = ClipItem(text: "later capture", kind: .text)
        try repository.applyChanges(metadata: .init(), upserting: [captured, changed], deleting: [second.id])
        XCTAssertEqual(try repository.restoreArchivedItems(token: token), [second.id])
        XCTAssertEqual(try repository.loadItems(ids: [first.id]).first?.text, "later edit")
        XCTAssertEqual(try repository.loadItems(limit: 3).map(\.id), [captured.id, first.id, second.id])
        let malformedArchiveID = "invalid token"
        XCTAssertThrowsError(try repository.restoreArchivedItems(token: malformedArchiveID))
    }
    func testLargeArchiveCopiesRowsInDatabaseWithoutHydratingBinaryData() throws {
        let repository = try repository()
        let items = (0..<1500).map { ClipItem(text: "archive \($0)", kind: .text, representations: [.init(type: "public.data", data: Data(repeating: 1, count: 65_536))]) }
        try repository.save(.init(items: items))
        let token = try repository.archiveItems(ids: Set(items.map(\.id)))
        try repository.applyChanges(metadata: .init(), upserting: [], deleting: Set(items.map(\.id)))
        XCTAssertEqual(try repository.restoreArchivedItems(token: token).count, 1500)
        XCTAssertEqual(try repository.itemCount(), 1500)
    }
    func testCorruptStoreRecoveryPreservesLegacyAndOriginalBackup() throws {
        let repository = try repository(), directory = repository.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damaged = Data("damaged sqlite".utf8), legacy = Data("damaged legacy JSON".utf8)
        try damaged.write(to: repository.databaseURL)
        try legacy.write(to: directory.appendingPathComponent("clipboard.json"))
        let imported = ClipboardSnapshot(items: [.init(text: "safe replacement", kind: .text)])
        try repository.recoverCorruptStore(with: imported)
        XCTAssertEqual(try repository.load(), imported)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clipboard.json")), legacy)
        let folders = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Damaged Store Recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(folders.first).appendingPathComponent("clipboard.sqlite")), damaged)
    }
    func testFailedCorruptRecoveryRestoresEveryOriginalFile() throws {
        let repository = try repository(), directory = repository.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["clipboard.sqlite", "clipboard.sqlite-wal", "clipboard.sqlite-shm", "clipboard.json"]
        for name in names { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
        // A regular file at the asset-directory path forces replacement to fail after isolation.
        try Data("keep".utf8).write(to: directory.appendingPathComponent("assets"))
        let binary = ClipItem(text: "image", kind: .image, representations: [.init(type: "public.png", data: Data([1]))])
        XCTAssertThrowsError(try repository.recoverCorruptStore(with: .init(items: [binary])))
        for name in names { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data(name.utf8)) }
    }
    func testMigrationAndImportAreNotEligibleForAutomaticClassification() throws {
        let repository = try repository()
        let old = ClipItem(text: "old", kind: .text), new = ClipItem(text: "new", kind: .text)
        try repository.save(.init(items: [old]))
        try repository.applyChanges(metadata: .init(), upserting: [new], deleting: [])
        let database = try SQLiteDatabase(url: repository.databaseURL)
        var eligibility: [String: String] = [:]
        try database.rows("SELECT item_id,eligible FROM knowledge_jobs") { eligibility[SQLiteDatabase.text($0, 0)] = SQLiteDatabase.text($0, 1) }
        XCTAssertEqual(eligibility[old.id.uuidString], "0")
        XCTAssertEqual(eligibility[new.id.uuidString], "1")
        var edited = old; edited.text = "old edited"
        try repository.applyChanges(metadata: .init(), upserting: [edited], deleting: [])
        try database.rows("SELECT eligible FROM knowledge_jobs WHERE item_id=?", [.text(old.id.uuidString)]) { XCTAssertEqual(SQLiteDatabase.text($0, 0), "0") }
        try repository.save(.init(items: [new, edited]))
        try database.rows("SELECT eligible FROM knowledge_jobs WHERE item_id=?", [.text(new.id.uuidString)]) { XCTAssertEqual(SQLiteDatabase.text($0, 0), "0", "Import must not retain eligibility from an earlier capture of the same ID") }
    }
}
