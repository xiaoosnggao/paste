import XCTest
@testable import PasteCore

final class MCPProtocolTests: XCTestCase {
    private func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func object(_ data: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:] }
    private func initialize(_ session: inout MCPSession, version: String = "2025-11-25") -> [String: Any] {
        let result = object(session.handle(data(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": version, "clientInfo": ["name": "untrusted", "version": "1"], "capabilities": [:]]]), permissions: [.read]) { _, _ in [:] })
        XCTAssertNil(session.handle(data(["jsonrpc": "2.0", "method": "notifications/initialized"]), permissions: [.read]) { _, _ in [:] })
        return result
    }
    func testVersionNegotiationAndReadyTools() {
        for version in ["2025-11-25", "2025-06-18", "unknown"] {
            var session = MCPSession()
            let result = initialize(&session, version: version)["result"] as? [String: Any]
            XCTAssertEqual(result?["protocolVersion"] as? String, version == "unknown" ? "2025-11-25" : version)
            let listed = object(session.handle(data(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]), permissions: [.read]) { _, _ in [:] })["result"] as? [String: Any]
            XCTAssertEqual((listed?["tools"] as? [[String: Any]])?.count, 3)
        }
    }
    func testCallsRequireInitializationAndPermission() {
        var session = MCPSession(); var calls = 0
        let request = data(["jsonrpc": "2.0", "id": "req", "method": "tools/call", "params": ["name": "get_item", "arguments": ["id": UUID().uuidString]]])
        let before = object(session.handle(request, permissions: [.read]) { _, _ in calls += 1; return [:] })
        XCTAssertEqual((before["error"] as? [String: Any])?["code"] as? Int, -32002)
        _ = initialize(&session)
        let denied = object(session.handle(request, permissions: []) { _, _ in calls += 1; return [:] })
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? Int, -32001)
        XCTAssertEqual(calls, 0)
        let allowed = object(session.handle(request, permissions: [.read]) { name, _ in calls += 1; XCTAssertEqual(name, "get_item"); return ["text": "fixture"] })
        XCTAssertEqual(calls, 1); XCTAssertNotNil(allowed["result"])
    }
    func testOptionalArgumentsDefaultToEmptyObject() {
        var session = MCPSession(); _ = initialize(&session)
        let reply = object(session.handle(data(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "list_pinboards"]]), permissions: [.read]) { _, arguments in
            XCTAssertTrue(arguments.isEmpty); return ["pinboards": []]
        })
        XCTAssertNotNil(reply["result"]); XCTAssertNil(reply["error"])
    }
    func testBusinessFailureUsesToolError() {
        var session = MCPSession(); _ = initialize(&session)
        let reply = object(session.handle(data(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_item", "arguments": [:]]]), permissions: [.read]) { _, _ in throw MCPFailure("Item not found") })
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNil(reply["error"])
    }
    func testMalformedOversizedAndUnknownMessages() {
        var session = MCPSession()
        XCTAssertEqual((object(session.handle(Data("[1]".utf8), permissions: []) { _, _ in [:] })["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((object(session.handle(Data(repeating: 32, count: 65_537), permissions: []) { _, _ in [:] })["error"] as? [String: Any])?["code"] as? Int, -32600)
        let reply = object(session.handle(data(["jsonrpc": "2.0", "id": 7, "method": "resources/read"]), permissions: [.read]) { _, _ in [:] })
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(reply["id"] as? Int, 7)
    }
    func testBooleanRequestIDAndNotificationNeverDispatch() {
        var session = MCPSession(); var calls = 0
        let invalid = object(session.handle(data(["jsonrpc": "2.0", "id": true, "method": "ping"]), permissions: []) { _, _ in calls += 1; return [:] })
        XCTAssertNotNil(invalid["error"])
        XCTAssertNil(session.handle(data(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]), permissions: [.read]) { _, _ in calls += 1; return [:] })
        XCTAssertEqual(calls, 0)
    }
    func testOutputSizeBoundAndUnknownTool() {
        var session = MCPSession(); _ = initialize(&session)
        let request = data(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_item", "arguments": [:]]])
        let reply = object(session.handle(request, permissions: [.read]) { _, _ in ["text": String(repeating: "x", count: 48_001)] })
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = object(session.handle(data(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "delete", "arguments": [:]]]), permissions: [.read, .write]) { _, _ in XCTFail("Unknown tool dispatched"); return [:] })
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
    }
}
