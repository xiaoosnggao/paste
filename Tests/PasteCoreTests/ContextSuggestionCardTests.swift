import XCTest
@testable import PasteCore

final class ContextSuggestionCardTests: XCTestCase {
    func testAIResultPreservesSourceAndApplicationAttribution() throws {
        let source = ClipItem(text: "{\"ok\":true}", kind: .text, sourceBundleID: "com.microsoft.VSCode", sourceName: "Visual Studio Code")
        let result = ClipItem(text: "{\n  \"ok\": true\n}", kind: .text,
                              sourceName: "Local AI", derivation: .init(sourceItemID: source.id, operation: .aiTransform, provider: "Local AI"))
        let snapshot = SnapshotOperations.capture(result, in: .init(items: [source]))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items.first(where: { $0.id == source.id }), source)
        let decoded = try JSONDecoder().decode(ClipboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.items.first?.derivation?.operation, .aiTransform)
        XCTAssertEqual(decoded.items.first?.derivation?.sourceItemID, source.id)
        XCTAssertEqual(decoded.items.last?.sourceBundleID, "com.microsoft.VSCode")
    }

    func testIdenticalAIOutputDoesNotReplaceOriginalCard() {
        let source = ClipItem(text: "Already formatted", kind: .text)
        let result = ClipItem(text: source.text, kind: .text,
                              derivation: .init(sourceItemID: source.id, operation: .aiTransform, provider: "AI"))
        let once = SnapshotOperations.capture(result, in: .init(items: [source]))
        let twice = SnapshotOperations.capture(result, in: once)
        XCTAssertEqual(twice.items.count, 2)
        XCTAssertNil(twice.items.first(where: { $0.id == source.id })?.derivation)
        XCTAssertEqual(twice.items.filter { $0.derivation?.operation == .aiTransform }.count, 1)
    }

    func testTranslationAndAIResultHaveIndependentIdentity() {
        let source = ClipItem(text: "Hello", kind: .text)
        let translated = ClipItem(text: "你好", kind: .text,
                                  derivation: .init(sourceItemID: source.id, operation: .translation, provider: "AI"))
        let transformed = ClipItem(text: "你好", kind: .text,
                                   derivation: .init(sourceItemID: source.id, operation: .aiTransform, provider: "AI"))
        let result = SnapshotOperations.capture(transformed, in: .init(items: [translated, source]))
        XCTAssertEqual(result.items.count, 3)
        XCTAssertTrue(result.items.contains { $0.id == translated.id })
        XCTAssertTrue(result.items.contains { $0.derivation?.operation == .aiTransform })
    }
}
