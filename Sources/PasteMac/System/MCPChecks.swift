#if DEBUG
import AppKit
import PasteCore

@MainActor
enum MCPChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw MCPFailure("MCP check failed: " + message) }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-mcp-checks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("pasteboard.mcp.fixture.\(UUID())"))
        defer { board.releaseGlobally() }
        let model = AppModel(isDemo: true, storageDirectory: root, bridge: ClipboardBridge(pasteboard: board))
        let service = MCPService(model: model, directory: root.appendingPathComponent("MCP"))
        try check(!service.enabled, "default off")
        service.start(); defer { service.stop() }
        var port = 0
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: service.directory.appendingPathComponent("endpoint.json")), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int], let value = object["port"] { port = value; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(port > 0, "listener ready on ephemeral port")
        func post(_ path: String, _ object: [String: Any], token: String? = nil, origin: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"; request.timeoutInterval = 4
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let (data, response) = try await transport.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let sessionID = UUID().uuidString
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "fixture", "version": "1"], "capabilities": [:]]]
        let unauth = try await post("/rpc", ["session": sessionID, "message": initialize])
        try check(unauth.0 == 401 && unauth.1.isEmpty, "unauthorized history unavailable")
        let foreign = try await post("/pair", [:], origin: "https://untrusted.example")
        try check(foreign.0 == 403, "Origin rejected")
        let deniedTicket = MCPService.randomSecret()
        let deniedPair: [String: Any] = ["ticket": deniedTicket, "name": "Denied fixture", "permissions": ["read"]]
        _ = try await post("/pair", deniedPair); service.deny(deniedTicket)
        let deniedAgain = try await post("/pair", deniedPair)
        try check(deniedAgain.0 == 403 && service.pending.isEmpty, "denial cannot silently reapply")
        let ticket = MCPService.randomSecret()
        let pair: [String: Any] = ["ticket": ticket, "name": "Isolated automated fixture", "permissions": ["read", "write", "copy"]]
        let waiting = try await post("/pair", pair)
        try check(waiting.0 == 202 && waiting.1["token"] == nil && service.pending.count == 1, "pending approval has no credential")
        // Only this isolated demo server receives automated fixture approval.
        service.approve(ticket, permissions: [.read])
        let grant = try await post("/pair", pair)
        guard let token = grant.1["token"] as? String else { throw MCPFailure("Fixture approval missing token") }
        try check(grant.0 == 200 && token.count == 64, "random per-client credential")
        let initialized = try await post("/rpc", ["session": sessionID, "message": initialize], token: token)
        try check((initialized.1["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "negotiated supported version")
        _ = try await post("/rpc", ["session": sessionID, "message": ["jsonrpc": "2.0", "method": "notifications/initialized"]], token: token)
        let tools = try await post("/rpc", ["session": sessionID, "message": ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]], token: token)
        try check(((tools.1["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 3, "read grant restricts tools")
        func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            try await post("/rpc", ["session": sessionID, "message": ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": arguments]]], token: token).1
        }
        let denied = try await call("add_text", ["text": "must not save"])
        try check((denied["error"] as? [String: Any])?["code"] as? Int == -32001 && !model.snapshot.items.contains(where: { $0.text == "must not save" }), "write permission enforced")
        let search = try await call("search_history", ["limit": 1])
        try check((search["result"] as? [String: Any])?["isError"] as? Bool == false, "bounded search")
        let badLimit = try await call("search_history", ["limit": 51])
        try check((badLimit["result"] as? [String: Any])?["isError"] as? Bool == true, "excessive limit rejected")
        let badType = try await call("search_history", ["limit": true])
        try check((badType["result"] as? [String: Any])?["isError"] as? Bool == true, "bool is not integer")
        let malformedID = try await call("get_item", ["id": "not-a-uuid"])
        try check((malformedID["result"] as? [String: Any])?["isError"] as? Bool == true, "UUID validation")
        let spoof = try await post("/rpc", ["session": sessionID, "message": ["jsonrpc": "2.0", "id": 4, "method": "ping"]], token: MCPService.randomSecret())
        try check(spoof.0 == 401, "client name does not confer authority")
        if let client = service.clients.first { service.revoke(client.id) }
        let revoked = try await post("/rpc", ["session": sessionID, "message": initialize], token: token)
        try check(revoked.0 == 401, "revoke immediately invalidates existing session")
        let writeTicket = MCPService.randomSecret()
        let writePair: [String: Any] = ["ticket": writeTicket, "name": "Write fixture", "permissions": ["write", "copy"]]
        _ = try await post("/pair", writePair); service.approve(writeTicket, permissions: [.write, .copy])
        let writeGrant = try await post("/pair", writePair)
        guard let writeToken = writeGrant.1["token"] as? String else { throw MCPFailure("Write fixture failed") }
        let writeSession = UUID().uuidString
        _ = try await post("/rpc", ["session": writeSession, "message": initialize], token: writeToken)
        _ = try await post("/rpc", ["session": writeSession, "message": ["jsonrpc": "2.0", "method": "notifications/initialized"]], token: writeToken)
        let text = "MCP isolated fixture \(UUID())"
        let saved = try await post("/rpc", ["session": writeSession, "message": ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "add_text", "arguments": ["text": text]]]], token: writeToken)
        let acceptedContent = ((saved.1["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        try check((saved.1["result"] as? [String: Any])?["isError"] as? Bool == false && acceptedContent?.contains("\"accepted\":true") == true && model.snapshot.items.contains(where: { $0.text == text }), "write reports accepted admission, not disk saved")
        guard let clip = model.snapshot.items.first(where: { $0.text == text }) else { throw MCPFailure("Saved fixture absent") }
        _ = try await post("/rpc", ["session": writeSession, "message": ["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": ["name": "copy_item", "arguments": ["id": clip.id.uuidString, "plain_text": true]]]], token: writeToken)
        try check(board.string(forType: .string) == text && !model.isPasting, "copy only uses named board; no paste event")
        let attributes = try FileManager.default.attributesOfItem(atPath: service.directory.appendingPathComponent("clients.json").path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credential storage private")
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasteboardMCP")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            let process = Process(); process.executableURL = executable; process.arguments = ["--client-name", "Write fixture"]
            var environment = ProcessInfo.processInfo.environment
            environment["PASTEBOARD_MCP_DIRECTORY"] = service.directory.path; environment["PASTEBOARD_MCP_TOKEN"] = writeToken
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            let messages: [[String: Any]] = [initialize, ["jsonrpc": "2.0", "method": "notifications/initialized"], ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]]
            for message in messages { input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data([10])) }
            try input.fileHandleForWriting.close()
            let deadline = Task.detached {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled && process.isRunning { process.terminate() }
            }
            let result = await Task.detached { let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (data, process.terminationStatus) }.value
            deadline.cancel()
            let lines = String(decoding: result.0, as: UTF8.self).split(separator: "\n")
            try check(result.1 == 0 && lines.count == 2 && lines.allSatisfy({ (try? JSONSerialization.jsonObject(with: Data($0.utf8))) is [String: Any] }), "real stdio handshake and EOF cleanup")
        }
        // Simulate disk failure while retaining the previous, readable credential file.
        service.simulateAuthorizationWriteFailure = true
        guard let writeClient = service.clients.first(where: { $0.token == writeToken }) else { throw MCPFailure("Write client missing") }
        service.revoke(writeClient.id)
        try check(!service.enabled && !service.isActive(writeClient.id), "failed revoke persistence disables live service")
        let reloaded = MCPService(model: model, directory: service.directory)
        try check(reloaded.clients.contains(where: { $0.token == writeToken }) && !reloaded.isActive(writeClient.id), "old disk credential stays inactive after restart")
        reloaded.start(); defer { reloaded.stop() }
        port = 0
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: reloaded.directory.appendingPathComponent("endpoint.json")), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int], let value = object["port"] { port = value; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(port > 0, "reloaded service ready")
        let oldToken = try await post("/rpc", ["session": UUID().uuidString, "message": initialize], token: writeToken)
        try check(oldToken.0 == 401, "failed disk revoke cannot automatically restore stale token")
        reloaded.resume(writeClient.id) // Explicit isolated human-action fixture.
        let resumed = try await post("/rpc", ["session": UUID().uuidString, "message": initialize], token: writeToken)
        try check(resumed.0 == 200, "only explicit resume activates saved credential")
        reloaded.stop()
        service.stop()
        try check(!service.enabled && !FileManager.default.fileExists(atPath: service.directory.appendingPathComponent("endpoint.json").path), "stop disconnects and removes endpoint")
        return count
    }
}
#endif
