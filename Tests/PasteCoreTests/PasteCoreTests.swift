import XCTest
@testable import PasteCore

final class PasteCoreTests: XCTestCase {
    func clip(_ text: String, date: Date = Date(), representations: [PasteboardRepresentation] = []) -> ClipItem {
        ClipItem(createdAt: date, lastCopiedAt: date, text: text, kind: .text, representations: representations)
    }
    func testClassification() {
        XCTAssertEqual(ContentClassifier.classify(text: "https://example.com/a"), .link)
        XCTAssertEqual(ContentClassifier.classify(text: "#AABBCC"), .color)
        XCTAssertEqual(ContentClassifier.classify(text: "hello https://example.com"), .text)
        XCTAssertEqual(ContentClassifier.classify(text: "", hasImage: true), .image)
        XCTAssertEqual(ContentClassifier.classify(text: "", filePaths: ["/tmp/a"]), .file)
        XCTAssertEqual(ContentClassifier.classify(text: ""), .unknown)
    }
    func testFingerprintPreservesRichDataAndBoundaries() {
        let first = clip("same", representations: [.init(type: "public.rtf", data: Data([1]), itemIndex: 0)])
        let changed = clip("same", representations: [.init(type: "public.rtf", data: Data([2]), itemIndex: 0)])
        let moved = clip("same", representations: [.init(type: "public.rtf", data: Data([1]), itemIndex: 1)])
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
        XCTAssertNotEqual(first.fingerprint, moved.fingerprint)
        XCTAssertEqual(first.fingerprint, clip("same", representations: first.representations).fingerprint)
    }
    func testDuplicatePromotionPreservesIdentityAndPins() {
        let old = clip("a", date: Date(timeIntervalSince1970: 1))
        let other = clip("b", date: Date(timeIntervalSince1970: 2))
        let board = Pinboard(name: "Work", itemIDs: [old.id])
        let newer = clip("a", date: Date(timeIntervalSince1970: 3))
        var snapshot = ClipboardSnapshot(items: [other, old], pinboards: [board])
        snapshot.preferences.retentionDays = nil
        let result = SnapshotOperations.capture(newer, in: snapshot)
        XCTAssertEqual(result.items.map(\.id), [old.id, other.id])
        XCTAssertEqual(result.items[0].lastCopiedAt, newer.lastCopiedAt)
        XCTAssertEqual(result.items[0].createdAt, old.createdAt)
        XCTAssertEqual(result.pinboards[0].itemIDs, [old.id])
    }
    func testFilteredOrderingUsesBoardOrderAndCurrentHistory() {
        let one = clip("Alpha", date: Date(timeIntervalSince1970: 1))
        let two = clip("ALPHA", date: Date(timeIntervalSince1970: 2))
        let board = Pinboard(name: "All", itemIDs: [one.id, two.id])
        let snapshot = ClipboardSnapshot(items: [two, one], pinboards: [board])
        XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: "alpha", pinboardID: board.id, filter: .init()).map(\.id), [one.id, two.id])
        XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: "alpha", pinboardID: nil, filter: .init()).map(\.id), [two.id, one.id])
        XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: "", pinboardID: nil, filter: .init(since: Date(timeIntervalSince1970: 2))).map(\.id), [two.id])
    }
    func testReorderedBoardKeepsSearchResultsInExplicitOrder() {
        let first = clip("Alpha first")
        let excluded = clip("Beta")
        let second = clip("Alpha second")
        var snapshot = ClipboardSnapshot(items: [first, excluded, second], pinboards: [.init(name: "Work", itemIDs: [first.id, excluded.id, second.id])])
        let boardID = snapshot.pinboards[0].id
        snapshot.pinboards[0].itemIDs = [second.id, excluded.id, first.id]
        XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: "alpha", pinboardID: boardID, filter: .init()).map(\.id), [second.id, first.id])
        XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: "alpha", pinboardID: nil, filter: .init()).map(\.id), [first.id, second.id])
        XCTAssertTrue(SnapshotOperations.filteredItems(in: snapshot, query: "", pinboardID: UUID(), filter: .init()).isEmpty)
    }
    func testRetentionProtectsPinsAndEnforcesHistoryLimit() {
        let old = clip("old", date: Date(timeIntervalSince1970: 0))
        let first = clip("first")
        let second = clip("second")
        var snapshot = ClipboardSnapshot(items: [first, second, old], pinboards: [.init(name: "Keep", itemIDs: [old.id])])
        snapshot.preferences.maxHistoryItems = 1
        snapshot.preferences.retentionDays = 1
        XCTAssertEqual(SnapshotOperations.prune(snapshot).items.map(\.id), [first.id, old.id])
    }
    func testByteBudgetPrunesLargeHistoryButProtectsPins() {
        let small = clip("small")
        let large = clip("image", representations: [.init(type: "public.png", data: Data(count: 49 * 1024 * 1024))])
        let unpinned = ClipboardSnapshot(items: [small, large])
        XCTAssertEqual(SnapshotOperations.prune(unpinned).items.map(\.id), [small.id])
        let pinned = ClipboardSnapshot(items: [small, large], pinboards: [.init(name: "Keep", itemIDs: [large.id])])
        XCTAssertEqual(SnapshotOperations.prune(pinned).items.map(\.id), [small.id, large.id])
    }
    func testInvalidSavePreservesPreviousDurableSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let original = ClipboardSnapshot(items: [clip("safe")])
        try repository.save(original)
        var invalid = original
        invalid.items.append(original.items[0])
        XCTAssertThrowsError(try repository.save(invalid))
        XCTAssertEqual(try repository.load(), original)
    }
    func testBoardMembershipAndDeletion() {
        let item = clip("a")
        var snapshot = SnapshotOperations.addPinboard(name: "Work", to: .init(items: [item]))
        let board = snapshot.pinboards[0].id
        snapshot = SnapshotOperations.pin(itemIDs: [item.id, item.id, UUID()], to: board, in: snapshot)
        XCTAssertEqual(snapshot.pinboards[0].itemIDs, [item.id])
        snapshot = SnapshotOperations.deleteItems(ids: [item.id], in: snapshot)
        XCTAssertTrue(snapshot.pinboards[0].itemIDs.isEmpty)
        snapshot = SnapshotOperations.deletePinboard(id: board, in: snapshot)
        XCTAssertTrue(snapshot.pinboards.isEmpty)
    }
    func testRepositoryRoundtripAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        XCTAssertEqual(try repository.load(), ClipboardSnapshot())
        let snapshot = ClipboardSnapshot(items: [clip("rich", representations: [.init(type: "public.rtf", data: Data([0, 255, 1]), itemIndex: 2)])])
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load(), snapshot)
        var changed = snapshot
        changed.items[0].title = "Edited"
        try repository.save(changed)
        XCTAssertEqual(try repository.load(), changed)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testCorruptAndUnsupportedStoresThrow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        try repository.save(.init())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        var future = ClipboardSnapshot()
        future.version = 99
        XCTAssertThrowsError(try repository.save(future))
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: file)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: file), futureData)
    }
    func testMalformedImportAndInvariantsThrow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let file = directory.appendingPathComponent("import.json")
        let item = clip("a")
        for snapshot in [ClipboardSnapshot(items: [item, item]), ClipboardSnapshot(pinboards: [.init(name: "Bad", itemIDs: [UUID()])])] {
            try JSONEncoder().encode(snapshot).write(to: file)
            XCTAssertThrowsError(try repository.importSnapshot(from: file))
        }
        var invalid = ClipboardSnapshot()
        invalid.preferences.maxHistoryItems = -1
        XCTAssertThrowsError(try repository.save(invalid))
        let duplicateFormat = clip("a", representations: [.init(type: "public.text", data: Data([1])), .init(type: "public.text", data: Data([2]))])
        XCTAssertThrowsError(try repository.save(.init(items: [duplicateFormat])))
        let negative = clip("a", representations: [.init(type: "x", data: Data(), itemIndex: -1)])
        XCTAssertThrowsError(try repository.save(.init(items: [negative])))
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 100 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try repository.importSnapshot(from: file))
        let huge = clip(String(repeating: "x", count: 2 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try repository.save(.init(items: [huge])))
    }
    func testUndoPreservesLaterCaptureThroughEditAndRedo() {
        let original = clip("Original")
        let before = ClipboardSnapshot(items: [original])
        var edited = original; edited.text = "Edited"; edited.title = "Title"
        let after = SnapshotOperations.replaceItem(edited, in: before)
        let captured = clip("Later")
        let current = SnapshotOperations.capture(captured, in: after)
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertEqual(undone.items.map(\.id), [captured.id, original.id])
        XCTAssertEqual(undone.items[1].text, "Original")
        let redone = SnapshotOperations.undoChange(before: after, after: before, in: undone)
        XCTAssertEqual(redone.items.map(\.id), [captured.id, original.id])
        XCTAssertEqual(redone.items[1].text, "Edited")
    }
    func testUndoBoardCreationDeletionAndMembershipPreservesNewCapture() {
        let item = clip("Old"); let later = clip("Later")
        let before = ClipboardSnapshot(items: [item])
        let created = SnapshotOperations.addPinboard(name: "Work", to: before)
        let current = SnapshotOperations.capture(later, in: created)
        let undoneCreation = SnapshotOperations.undoChange(before: before, after: created, in: current)
        XCTAssertEqual(undoneCreation.items.map(\.id), [later.id, item.id])
        XCTAssertTrue(undoneCreation.pinboards.isEmpty)
        let boardID = created.pinboards[0].id
        let pinned = SnapshotOperations.pin(itemIDs: [item.id], to: boardID, in: created)
        let laterPinned = SnapshotOperations.pin(itemIDs: [later.id], to: boardID, in: SnapshotOperations.capture(later, in: pinned))
        let undonePin = SnapshotOperations.undoChange(before: created, after: pinned, in: laterPinned)
        XCTAssertEqual(undonePin.pinboards[0].itemIDs, [later.id])
        let deleted = SnapshotOperations.deleteItems(ids: [item.id], in: pinned)
        let undoneDelete = SnapshotOperations.undoChange(before: pinned, after: deleted, in: SnapshotOperations.capture(later, in: deleted))
        XCTAssertEqual(undoneDelete.items.map(\.id), [later.id, item.id])
        XCTAssertEqual(undoneDelete.pinboards[0].itemIDs, [item.id])
        let redoneDelete = SnapshotOperations.undoChange(before: deleted, after: pinned, in: undoneDelete)
        XCTAssertEqual(redoneDelete.items.map(\.id), [later.id])
        XCTAssertTrue(redoneDelete.pinboards[0].itemIDs.isEmpty)
        let boardDeleted = SnapshotOperations.deletePinboard(id: boardID, in: pinned)
        let undoneBoardDelete = SnapshotOperations.undoChange(before: pinned, after: boardDeleted, in: SnapshotOperations.capture(later, in: boardDeleted))
        XCTAssertEqual(undoneBoardDelete.pinboards, pinned.pinboards)
        XCTAssertEqual(undoneBoardDelete.items.first?.id, later.id)
    }
    func testUndoKeepsLaterChangesToSameItemFields() {
        let item = clip("Original")
        let before = ClipboardSnapshot(items: [item])
        var edited = item; edited.text = "Edited"
        let after = SnapshotOperations.replaceItem(edited, in: before)
        var recaptured = edited; recaptured.lastCopiedAt = Date().addingTimeInterval(60); recaptured.sourceName = "New Source"
        let current = SnapshotOperations.replaceItem(recaptured, in: after)
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertEqual(undone.items[0].text, "Original")
        XCTAssertEqual(undone.items[0].lastCopiedAt, recaptured.lastCopiedAt)
        XCTAssertEqual(undone.items[0].sourceName, "New Source")
    }

    func testUndoBoardReorderKeepsLaterMember() {
        let first = clip("First"); let second = clip("Second"); let later = clip("Later")
        let before = ClipboardSnapshot(items: [first, second], pinboards: [.init(name: "Work", itemIDs: [first.id, second.id])])
        var after = before; after.pinboards[0].itemIDs = [second.id, first.id]
        let current = SnapshotOperations.pin(itemIDs: [later.id], to: before.pinboards[0].id, in: SnapshotOperations.capture(later, in: after))
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertEqual(undone.pinboards[0].itemIDs, [first.id, second.id, later.id])
        XCTAssertEqual(undone.items.first?.id, later.id)
    }

    func testPinnedBytesReduceAvailableHistoryBudget() {
        let pinned = clip("Pinned", representations: [.init(type: "public.png", data: Data(count: 40 * 1024 * 1024))])
        let tooLarge = clip("Too large", representations: [.init(type: "public.png", data: Data(count: 22 * 1024 * 1024))])
        let small = clip("Small", representations: [.init(type: "public.png", data: Data(count: 10 * 1024 * 1024))])
        let snapshot = ClipboardSnapshot(items: [tooLarge, small, pinned], pinboards: [.init(name: "Keep", itemIDs: [pinned.id])])
        let pruned = SnapshotOperations.prune(snapshot)
        XCTAssertEqual(pruned.items.map(\.id), [small.id, pinned.id])
        XCTAssertNoThrow(try SnapshotRepository(directory: FileManager.default.temporaryDirectory).validate(pruned))
    }
    func testValidationRejectsInvalidAdmissionWithoutWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = SnapshotRepository(directory: directory)
        let invalid = ClipboardSnapshot(items: [clip(String(repeating: "x", count: 3 * 1024 * 1024))])
        XCTAssertThrowsError(try repository.validate(invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUndoBoardOrderPreservesLaterBoardSlotsAndRedo() {
        let first = Pinboard(name: "A"); let second = Pinboard(name: "B"); let later = Pinboard(name: "C")
        let before = ClipboardSnapshot(pinboards: [first, second])
        let after = ClipboardSnapshot(pinboards: [second, first])
        let current = ClipboardSnapshot(pinboards: [second, later, first])
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertEqual(undone.pinboards.map(\.id), [first.id, later.id, second.id])
        let redone = SnapshotOperations.undoChange(before: after, after: before, in: undone)
        XCTAssertEqual(redone.pinboards.map(\.id), [second.id, later.id, first.id])
    }
    func testUndoDeletedBoardInsertsBeforeOriginalSuccessor() {
        let first = Pinboard(name: "A"); let second = Pinboard(name: "B"); let third = Pinboard(name: "D"); let later = Pinboard(name: "C")
        let before = ClipboardSnapshot(pinboards: [first, second, third])
        let after = ClipboardSnapshot(pinboards: [first, third])
        let current = ClipboardSnapshot(pinboards: [later, first, third])
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertEqual(undone.pinboards.map(\.id), [later.id, first.id, second.id, third.id])
    }

}
