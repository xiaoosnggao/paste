import XCTest
@testable import PasteCore

final class DerivedCardTests: XCTestCase {
    private func original(_ text: String = "Hello") -> ClipItem { .init(text: text, kind: .text) }
    private func derived(_ text: String, source: ClipItem) -> ClipItem {
        .init(text: text, kind: .text, derivation: .init(sourceItemID: source.id, operation: .translation, provider: "System"))
    }
    func testEqualSourceAndResultStaySeparate() {
        let source = original()
        let next = SnapshotOperations.capture(derived("Hello", source: source), in: .init(items: [source]))
        XCTAssertEqual(next.items.count, 2)
        XCTAssertTrue(next.items.contains { $0.id == source.id })
    }
    func testSameSourceResultDeduplicatesWithoutReplacingSource() {
        let source = original()
        let first = SnapshotOperations.capture(derived("你好", source: source), in: .init(items: [source]))
        let second = SnapshotOperations.capture(derived("你好", source: source), in: first)
        XCTAssertEqual(second.items.count, 2)
        XCTAssertEqual(second.items.first?.id, first.items.first?.id)
        XCTAssertEqual(second.items.last?.id, source.id)
    }
    func testOrdinaryRecopyDoesNotStealResultIdentity() {
        let source = original()
        let result = derived("你好", source: source)
        let next = SnapshotOperations.capture(original("你好"), in: .init(items: [result, source]))
        XCTAssertEqual(next.items.count, 3)
        XCTAssertTrue(next.items.contains { $0.id == result.id && $0.derivation != nil })
    }
    func testRelationRoundTripAndLegacy() throws {
        let source = original()
        let item = derived("你好", source: source)
        let copy = try JSONDecoder().decode(ClipItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(copy.derivation, item.derivation)
        XCTAssertNil(try JSONDecoder().decode(ClipItem.self, from: JSONEncoder().encode(source)).derivation)
    }
    func testDifferentSourcesDoNotLoseTheirResult() {
        let a = original("Hello"), b = original("Hi")
        let next = SnapshotOperations.capture(derived("你好", source: b), in: .init(items: [derived("你好", source: a), a, b]))
        XCTAssertEqual(next.items.count, 4)
    }
}
