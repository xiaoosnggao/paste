import XCTest
@testable import PasteCore

final class TextToolsTests: XCTestCase {
    func testLinksAndEmailsKeepOrderAndDoNotDuplicate() throws {
        let text = "中文 https://example.com/a。 https://example.com/a test@example.com TEST@example.org"
        XCTAssertEqual(try TextTools.apply(.links, to: text), "https://example.com/a")
        XCTAssertEqual(try TextTools.apply(.emails, to: text), "test@example.com\nTEST@example.org")
    }
    func testCleanupAndBoundaries() throws {
        XCTAssertEqual(try TextTools.apply(.clean, to: "  中文  \n text \t\n"), "中文\ntext")
        XCTAssertThrowsError(try TextTools.apply(.links, to: String(repeating: "x", count: 100_001)))
        XCTAssertEqual(try TextTools.apply(.emails, to: "没有邮箱"), "")
    }
    func testRecommendationsPreferTargetSourceAndStableTies() {
        let date = Date(timeIntervalSince1970: 100)
        let first = ClipItem(lastCopiedAt: date, text: "A", kind: .text, sourceBundleID: "one")
        let second = ClipItem(lastCopiedAt: date, text: "B", kind: .text, sourceBundleID: "two")
        XCTAssertEqual(TextTools.recommended([first, second], for: "two", now: date).map(\.id), [second.id, first.id])
        XCTAssertEqual(TextTools.recommended([first, second], for: nil, now: date).map(\.id), [first.id, second.id])
        XCTAssertTrue(TextTools.recommended([first], for: nil, limit: 0).isEmpty)
    }
}
