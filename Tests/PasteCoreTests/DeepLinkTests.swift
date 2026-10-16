import XCTest
@testable import PasteCore

final class DeepLinkTests: XCTestCase {
    func testKnownActionsAndChineseEncoding() throws {
        XCTAssertEqual(try DeepLinkParser.parse(URL(string: "pasteboard://open")!), .open)
        XCTAssertEqual(try DeepLinkParser.parse(URL(string: "pasteboard://search?query=%E4%B8%AD%E6%96%87")!), .search("中文"))
        XCTAssertEqual(try DeepLinkParser.parse(URL(string: "pasteboard://add?text=hello&title=test")!), .add(text: "hello", title: "test"))
        let id = UUID()
        XCTAssertEqual(try DeepLinkParser.parse(URL(string: "pasteboard://copy?id=\(id)")!), .copy(id))
    }
    func testRejectsUnknownActionsDuplicateAndOversizedParameters() {
        for value in ["https://open", "pasteboard://delete", "pasteboard://open/anything", "pasteboard://open?x=a", "pasteboard://search?query=a&query=b", "pasteboard://copy?id=bad", "pasteboard://add?text=", "pasteboard://add?text=a&other=b", "pasteboard://open#fragment", "pasteboard://user@open"] {
            XCTAssertThrowsError(try DeepLinkParser.parse(URL(string: value)!), value)
        }
        XCTAssertThrowsError(try DeepLinkParser.parse(URL(string: "pasteboard://search?query=" + String(repeating: "a", count: 1025))!))
    }
}
