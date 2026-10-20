import AppKit
import Combine
import CryptoKit
import Security
import CoreFoundation
import Network
import PasteCore

struct MCPClient: Identifiable, Codable {
    let id: UUID
    let name: String
    let token: String
    let permissions: Set<MCPPermission>
}
struct MCPPairing: Identifiable {
    let id: String
    let name: String
    let expires: Date
    let requested: Set<MCPPermission>
    var grantedToken: String?
}

/// HTTP here is loopback-only private IPC for the standard stdio MCP executable.
@MainActor
final class MCPService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var clients: [MCPClient] = []
    @Published private(set) var activeClientIDs: Set<UUID> = []
    @Published private(set) var pending: [MCPPairing] = []
    @Published private(set) var status: String?
    private let model: AppModel
    let directory: URL
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [String: (token: String, value: MCPSession, touched: Date)] = [:]
    private var pairings: [String: MCPPairing] = [:]
    private var deniedPairings: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.gaoxs.pasteboard.mcp", qos: .utility)
    private var generation = UUID()
    #if DEBUG
    var simulateAuthorizationWriteFailure = false
    #endif
    init(model: AppModel, directory: URL? = nil) {
        self.model = model
        self.directory = directory ?? model.storageDirectory.appendingPathComponent("MCP", isDirectory: true)
        do {
            let file = self.directory.appendingPathComponent("clients.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count < 65_536 else { throw MCPFailure("MCP 授权文件过大") }
                clients = try JSONDecoder().decode([MCPClient].self, from: data)
                guard clients.count <= 64, clients.allSatisfy({ $0.token.count == 64 && $0.name.count <= 80 }) else { throw MCPFailure("MCP 授权文件无效") }
            }
        } catch { clients = []; status = "无法读取授权记录，请重新授权客户端。" }
    }
    func start() {
        guard !enabled else { return }
        do {
            try prepareDirectory()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            generation = UUID(); let current = generation
            listener = server; enabled = true; status = "正在启动…"
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .ready:
                        guard let port = server?.port else { self.stop(); return }
                        do {
                            try self.writePrivate(try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue)]), to: "endpoint.json")
                            self.status = "服务已启动，仅接受本机客户端连接"
                        } catch { self.stop(); self.status = "无法保存连接信息。" }
                    case .failed: self.stop(); self.status = "本机 MCP 服务启动失败。"
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, generation: current) }
            }
            server.start(queue: queue)
        } catch { enabled = false; status = "MCP 服务启动失败：\(error.localizedDescription)" }
    }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); sessions.removeAll(); pairings.removeAll(); deniedPairings.removeAll(); pending = []; activeClientIDs.removeAll(); enabled = false
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("endpoint.json"))
        status = "服务已关闭"
    }
    func approve(_ id: String, permissions: Set<MCPPermission>) {
        expire()
        guard var pairing = pairings[id], pairing.grantedToken == nil, !permissions.isEmpty, permissions.isSubset(of: pairing.requested), clients.count < 64 else { return }
        let token = Self.randomSecret()
        let client = MCPClient(id: UUID(), name: pairing.name, token: token, permissions: permissions)
        do {
            try writePrivate(try JSONEncoder().encode(clients + [client]), to: "clients.json")
            clients.append(client); activeClientIDs.insert(client.id); pairing.grantedToken = token; pairings[id] = pairing; pending.removeAll { $0.id == id }
            status = "已授权 \(client.name)"
        } catch { status = "授权保存失败，客户端未获授权。" }
    }
    func deny(_ id: String) { pairings.removeValue(forKey: id); pending.removeAll { $0.id == id }; deniedPairings[id] = Date().addingTimeInterval(180) }
    func isActive(_ id: UUID) -> Bool { activeClientIDs.contains(id) }
    /// Explicit human action; saved credentials never reactivate themselves after restart.
    func resume(_ id: UUID) {
        guard enabled, clients.contains(where: { $0.id == id }) else { return }
        activeClientIDs.insert(id); status = "客户端已授权，本次运行有效"
    }
    func revoke(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id }) else { return }
        // Invalidate in memory immediately even if persistence later fails.
        activeClientIDs.remove(id); clients.removeAll { $0.id == id }; sessions = sessions.filter { $0.value.token != client.token }
        do { try writePrivate(try JSONEncoder().encode(clients), to: "clients.json"); status = "授权已撤销" }
        catch { stop(); status = "授权撤销未能保存，服务已关闭。请检查存储权限后再次撤销；旧授权重启后不会自动生效。" }
        pairings = pairings.filter { $0.value.grantedToken != client.token }
    }
    var clientConfiguration: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasteboardMCP").path
        let value: [String: Any] = ["mcpServers": ["pasteboard": ["command": path, "args": ["--client-name", "MCP 客户端"]]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { preconditionFailure("Secure randomness unavailable") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func writePrivate(_ data: Data, to name: String) throws {
        #if DEBUG
        if name == "clients.json" && simulateAuthorizationWriteFailure { throw MCPFailure("Isolated authorization write failure fixture") }
        #endif
        try prepareDirectory()
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func expire() {
        let now = Date()
        pairings = pairings.filter { $0.value.expires > now }
        deniedPairings = deniedPairings.filter { $0.value > now }
        pending = pending.filter { pairings[$0.id] != nil }
        sessions = sessions.filter { now.timeIntervalSince($0.value.touched) < 3600 }
    }
    private func accept(_ connection: NWConnection, generation current: UUID) {
        guard enabled, generation == current, connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in self?.finish(id) }
        }
        receive(connection, id: id, buffer: Data())
    }
    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let accumulated = buffer + (data ?? Data())
                guard accumulated.count <= 73_728 else { self.respond(connection, id: id, code: 413, body: Data()); return }
                if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    guard range.lowerBound <= 8192, let header = String(data: accumulated[..<range.lowerBound], encoding: .utf8) else { self.respond(connection, id: id, code: 400, body: Data()); return }
                    let lines = header.components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
                        guard fields.count == 2, headers[fields[0].lowercased()] == nil else { self.respond(connection, id: id, code: 400, body: Data()); return }
                        headers[fields[0].lowercased()] = fields[1].trimmingCharacters(in: .whitespaces)
                    }
                    guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= MCPSession.maximumMessageBytes, headers["transfer-encoding"] == nil else { self.respond(connection, id: id, code: 413, body: Data()); return }
                    let body = accumulated[range.upperBound...]
                    if body.count < length && !complete && error == nil { self.receive(connection, id: id, buffer: accumulated); return }
                    guard body.count == length else { self.respond(connection, id: id, code: 400, body: Data()); return }
                    let first = (lines.first ?? "").split(separator: " ")
                    guard first.count == 3, first[2] == "HTTP/1.1", headers["origin"] == nil,
                          headers["host"] == "127.0.0.1:\(self.listener?.port?.rawValue ?? 0)" else { self.respond(connection, id: id, code: 403, body: Data()); return }
                    let response = self.route(method: String(first[0]), path: String(first[1]), headers: headers, data: Data(body))
                    self.respond(connection, id: id, code: response.0, body: response.1)
                } else if complete || error != nil || accumulated.count > 8192 { self.finish(id) }
                else { self.receive(connection, id: id, buffer: accumulated) }
            }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, code: Int, body: Data) {
        let head = "HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.finish(id) } })
    }
    private func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
    private func route(method: String, path: String, headers: [String: String], data: Data) -> (Int, Data) {
        expire()
        guard method == "POST", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (400, Data()) }
        if path == "/pair" {
            guard let ticket = object["ticket"] as? String, ticket.count == 64, ticket.allSatisfy({ $0.isHexDigit }),
                  let name = object["name"] as? String, !name.isEmpty, name.count <= 80,
                  let requested = object["permissions"] as? [String], !requested.isEmpty,
                  requested.allSatisfy({ MCPPermission(rawValue: $0) != nil }) else { return (400, Data()) }
            if deniedPairings[ticket] != nil { return (403, Data()) }
            if let pairing = pairings[ticket] {
                if let token = pairing.grantedToken, let client = clients.first(where: { $0.token == token && activeClientIDs.contains($0.id) }) { return (200, json(["token": token, "permissions": client.permissions.map(\.rawValue)])) }
                return (202, json(["status": "pending"]))
            }
            guard pairings.count < 12 else { return (429, Data()) }
            let pairing = MCPPairing(id: ticket, name: name, expires: Date().addingTimeInterval(180), requested: Set(requested.compactMap(MCPPermission.init(rawValue:))), grantedToken: nil)
            pairings[ticket] = pairing; pending.append(pairing)
            return (202, json(["status": "pending"]))
        }
        guard let bearer = headers["authorization"], bearer.hasPrefix("Bearer "), let client = clients.first(where: { "Bearer " + $0.token == bearer && activeClientIDs.contains($0.id) }) else { return (401, Data()) }
        guard let session = object["session"] as? String, UUID(uuidString: session) != nil else { return (400, Data()) }
        if path == "/close" { if sessions[session]?.token == client.token { sessions.removeValue(forKey: session) }; return (204, Data()) }
        guard path == "/rpc", let message = object["message"] as? [String: Any] else { return (404, Data()) }
        if let existing = sessions[session], existing.token != client.token { return (403, Data()) }
        guard sessions[session] != nil || sessions.count < 64 else { return (429, Data()) }
        var protocolSession = sessions[session]?.value ?? MCPSession()
        let response = protocolSession.handle(json(message), permissions: client.permissions) { [self] name, arguments in try tool(name, arguments) }
        sessions[session] = (client.token, protocolSession, Date())
        return response.map { (200, $0) } ?? (204, Data())
    }
    private func tool(_ name: String, _ arguments: [String: Any]) throws -> Any {
        let allowed: [String: Set<String>] = ["search_history": ["query", "offset", "limit"], "get_item": ["id", "offset", "limit"], "add_text": ["text", "title"], "copy_item": ["id", "plain_text"], "list_pinboards": ["offset", "limit"]]
        guard Set(arguments.keys).isSubset(of: allowed[name] ?? []) else { throw MCPFailure("Unknown argument") }
        func integer(_ key: String, default fallback: Int, maximum: Int) throws -> Int {
            guard let value = arguments[key] else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 0, number.doubleValue < Double(Int.max), number.doubleValue <= Double(maximum) else { throw MCPFailure("Invalid \(key)") }
            return number.intValue
        }
        func item() throws -> ClipItem {
            guard let id = arguments["id"] as? String, let uuid = UUID(uuidString: id), !model.deletedHistoryIDs.contains(uuid) else { throw MCPFailure("Item not found") }
            if model.isDemo {
                guard let clip = model.snapshot.items.first(where: { $0.id == uuid }) else { throw MCPFailure("Item not found") }
                return clip
            }
            try model.synchronizeDurableHistory()
            guard let clip = try model.repository.loadItems(ids: [uuid]).first else { throw MCPFailure("Item not found") }
            return clip
        }
        switch name {
        case "search_history":
            guard arguments["query"] == nil || arguments["query"] is String else { throw MCPFailure("Invalid query") }
            let query = arguments["query"] as? String ?? ""
            guard query.count <= 500 else { throw MCPFailure("Query too long") }
            let offset = try integer("offset", default: 0, maximum: Int.max), limit = try integer("limit", default: 20, maximum: 50)
            guard limit > 0 else { throw MCPFailure("Limit must be positive") }
            let page: [ClipItem], total: Int
            if model.isDemo {
                let items = SnapshotOperations.filteredItems(in: model.snapshot, query: query, pinboardID: nil, filter: .init())
                page = Array(items.dropFirst(offset).prefix(limit)); total = items.count
            } else {
                try model.synchronizeDurableHistory()
                page = try model.repository.loadItems(limit: limit, offset: offset, query: query, includePayload: false)
                total = try model.repository.itemCount(query: query)
            }
            return ["items": page.map { ["id": $0.id.uuidString, "title": String($0.title.prefix(80)), "kind": $0.kind.rawValue, "preview": String($0.text.prefix(100))] }, "total": total, "nextOffset": offset < total && page.count < total - offset ? offset + page.count : NSNull()] as [String: Any]
        case "get_item":
            let clip = try item(), offset = try integer("offset", default: 0, maximum: 2_097_152), limit = try integer("limit", default: 2000, maximum: 4000)
            guard limit > 0 else { throw MCPFailure("Limit must be positive") }
            let text = String(clip.text.dropFirst(offset).prefix(limit))
            return ["id": clip.id.uuidString, "title": String(clip.title.prefix(100)), "kind": clip.kind.rawValue, "text": text, "totalCharacters": clip.text.count, "nextOffset": offset + text.count < clip.text.count ? offset + text.count : NSNull()] as [String: Any]
        case "list_pinboards":
            let offset = try integer("offset", default: 0, maximum: 100_000), limit = try integer("limit", default: 20, maximum: 50)
            guard limit > 0 else { throw MCPFailure("Limit must be positive") }
            let page = model.snapshot.pinboards.dropFirst(offset).prefix(limit)
            return ["pinboards": page.map { ["id": $0.id.uuidString, "name": String($0.name.prefix(100)), "count": $0.itemIDs.count] }, "total": model.snapshot.pinboards.count, "nextOffset": offset + page.count < model.snapshot.pinboards.count ? offset + page.count : NSNull()] as [String: Any]
        case "add_text":
            guard model.storageError == nil, let text = arguments["text"] as? String, !text.isEmpty, text.count <= 8192, text.utf8.count <= 32_768,
                  arguments["title"] == nil || arguments["title"] is String else { throw MCPFailure("Invalid text or storage unavailable") }
            let title = arguments["title"] as? String ?? ""
            guard title.count <= 100 else { throw MCPFailure("Title too long") }
            guard model.saveText(text, title: title, item: nil) else { throw MCPFailure("App refused content admission") }
            model.statusMessage = "已通过 MCP 添加文本"
            return ["accepted": true]
        case "copy_item":
            guard arguments["plain_text"] == nil || (arguments["plain_text"] is NSNumber && CFGetTypeID(arguments["plain_text"] as! NSNumber) == CFBooleanGetTypeID()), !model.isPasting else { throw MCPFailure("Invalid flag or paste operation busy") }
            try model.bridge.write([try item()], plainText: arguments["plain_text"] as? Bool ?? false)
            model.statusMessage = "已通过 MCP 复制到剪贴板"
            return ["copied": true, "pasted": false]
        default: throw MCPFailure("Unknown tool")
        }
    }
}
