import XCTest
@testable import PasteCore

final class SessionStateTests: XCTestCase {
    func testLegacyJSONRetainsHistoryWithoutSession() throws {
        let item = ClipItem(text: "legacy", kind: .text)
        let snapshot = ClipboardSnapshot(items: [item])
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["session"])
        let restored = try JSONDecoder().decode(ClipboardSnapshot.self, from: data)
        XCTAssertEqual(restored.items, [item])
        XCTAssertNil(restored.session)
    }

    func testSessionRoundTripRetainsQueueOrderAndModes() throws {
        let first = ClipItem(text: "first", kind: .text)
        let second = ClipItem(text: "second", kind: .text)
        let snapshot = ClipboardSnapshot(items: [first, second], session: .init(stackItemIDs: [second.id, first.id], stackReversed: true, pauseIndefinitely: true))
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testNormalizationPrunesExpiredPauseAndDanglingIDsInOrder() {
        let first = ClipItem(text: "first", kind: .text)
        let second = ClipItem(text: "second", kind: .text)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = ClipboardSnapshot(items: [first, second], session: .init(stackItemIDs: [second.id, UUID(), first.id, second.id], stackReversed: true, pauseUntil: now))
        let result = SnapshotOperations.normalizeSession(snapshot, now: now)
        XCTAssertEqual(result.session?.stackItemIDs, [second.id, first.id])
        XCTAssertNil(result.session?.pauseUntil)
        XCTAssertEqual(result.session?.stackReversed, true)
    }

    func testDeleteAndPruneCleanSessionBeforeValidation() throws {
        let first = ClipItem(text: "first", kind: .text)
        let second = ClipItem(text: "second", kind: .text)
        var snapshot = ClipboardSnapshot(items: [first, second], session: .init(stackItemIDs: [second.id, first.id]))
        let deleted = SnapshotOperations.deleteItems(ids: [second.id], in: snapshot)
        XCTAssertEqual(deleted.session?.stackItemIDs, [first.id])
        snapshot.preferences.maxHistoryItems = 1
        let pruned = SnapshotOperations.prune(snapshot)
        XCTAssertEqual(pruned.session?.stackItemIDs, [second.id, first.id])
    }

    func testUndoNeverResurrectsConsumedSessionEntries() {
        let item = ClipItem(text: "queued", kind: .text)
        let before = ClipboardSnapshot(items: [item], session: .init(stackItemIDs: [item.id]))
        let after = SnapshotOperations.deleteItems(ids: [item.id], in: before)
        let restored = SnapshotOperations.undoChange(before: before, after: after, in: after)
        XCTAssertEqual(restored.items, [item])
        XCTAssertEqual(restored.session?.stackItemIDs, [])
    }
}
