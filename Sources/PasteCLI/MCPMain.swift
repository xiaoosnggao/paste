import Foundation
import CryptoKit
import Security
import Darwin
import PasteCore

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class HTTPRelay {
    let port: Int
    let sessionID = UUID().uuidString
    var token: String?
    private let session: URLSession
    init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    func post(_ path: String, _ object: [String: Any]) throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let signal = DispatchSemaphore(value: 0)
        var output: (Int, Data)?; var failure: Error?
        let task = session.dataTask(with: request) { data, response, error in
            failure = error
            if let response = response as? HTTPURLResponse { output = (response.statusCode, data ?? Data()) }
            signal.signal()
        }
        task.resume()
        guard signal.wait(timeout: .now() + 10) == .success else { task.cancel(); throw MCPFailure("Local IPC timed out") }
        if let failure { throw failure }
        guard let output, output.1.count <= 262_144 else { throw MCPFailure("Invalid local response") }
        return output
    }
    func close() { _ = try? post("/close", ["session": sessionID]); session.invalidateAndCancel() }
}

@main
struct MCPMain {
    static func main() {
        do { try run() }
        catch { log("Pasteboard MCP: \(error.localizedDescription)"); exit(1) }
    }
    private static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            log("PasteboardMCP --client-name NAME [--credential-file PATH]\nEnable MCP in the running Pasteboard app and approve permissions. Protocol versions: 2025-11-25, 2025-06-18.")
            return
        }
        var name = "MCP 客户端", explicitCredential: String?
        var index = 0
        while index < args.count {
            guard index + 1 < args.count else { throw MCPFailure("Missing argument value") }
            switch args[index] {
            case "--client-name": name = args[index + 1]
            case "--credential-file": explicitCredential = args[index + 1]
            default: throw MCPFailure("Unknown argument")
            }
            index += 2
        }
        guard !name.isEmpty, name.count <= 80 else { throw MCPFailure("Client name length must be 1–80") }
        let directory: URL
        if let root = ProcessInfo.processInfo.environment["PASTEBOARD_MCP_DIRECTORY"] { directory = URL(fileURLWithPath: root, isDirectory: true) }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pasteboard/MCP", isDirectory: true) }
        let endpointData = try Data(contentsOf: directory.appendingPathComponent("endpoint.json"))
        guard endpointData.count < 1024, let endpoint = (try JSONSerialization.jsonObject(with: endpointData)) as? [String: Any], let port = endpoint["port"] as? Int, (1024...65535).contains(port) else { throw MCPFailure("Invalid endpoint; enable MCP in the main app") }
        let relay = HTTPRelay(port: port)
        defer { relay.close() }
        let nameHash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let credential = explicitCredential.map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("stdio-\(nameHash).json")
        if let token = ProcessInfo.processInfo.environment["PASTEBOARD_MCP_TOKEN"] { relay.token = token }
        else if FileManager.default.fileExists(atPath: credential.path) {
            try privateDirectory(credential.deletingLastPathComponent())
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: credential.path)) == nil else { throw MCPFailure("Credential must not be a symlink") }
            let attributes = try FileManager.default.attributesOfItem(atPath: credential.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw MCPFailure("Credential file must have 0600 permissions") }
            let data = try Data(contentsOf: credential)
            guard data.count < 1024, let value = (try JSONSerialization.jsonObject(with: data)) as? [String: String] else { throw MCPFailure("Invalid credential") }
            relay.token = value["token"]
        }
        if relay.token == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPFailure("Secure randomness failed") }
            let ticket = bytes.map { String(format: "%02x", $0) }.joined()
            log("Waiting for human approval in Pasteboard Settings → MCP. Client display name: \(name)")
            let deadline = Date().addingTimeInterval(170)
            while relay.token == nil && Date() < deadline {
                let reply = try relay.post("/pair", ["ticket": ticket, "name": name, "permissions": ["read", "write", "copy"]])
                if reply.0 == 200, let value = (try JSONSerialization.jsonObject(with: reply.1)) as? [String: Any], let token = value["token"] as? String {
                    relay.token = token
                    let data = try JSONSerialization.data(withJSONObject: ["token": token])
                    try saveCredential(data, to: credential)
                    log("Approved. Credential saved privately; starting stdio MCP.")
                } else if reply.0 == 202 { Thread.sleep(forTimeInterval: 1) }
                else { throw MCPFailure("Pairing rejected or service stopped") }
            }
        }
        guard let token = relay.token, token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { throw MCPFailure("No valid approved credential; pairing timed out") }
        var buffer = Data(); var oversized = false
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 10 {
                    if oversized { output(MCPSession.error(nil, -32600, "Message too large")) }
                    else if !buffer.isEmpty {
                        if let message = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] {
                            let reply = try relay.post("/rpc", ["session": relay.sessionID, "message": message])
                            if reply.0 == 200 { output(reply.1) }
                            else if reply.0 != 204 {
                                output(MCPSession.error(message["id"], -32001, "App service unavailable or authorization revoked"))
                                throw MCPFailure("IPC refused request (\(reply.0)); check service and authorization")
                            }
                        } else { output(MCPSession.error(nil, -32700, "Invalid JSON object")) }
                    }
                    buffer.removeAll(keepingCapacity: true); oversized = false
                } else if !oversized {
                    if buffer.count < MCPSession.maximumMessageBytes { buffer.append(byte) }
                    else { oversized = true; buffer.removeAll(keepingCapacity: true) }
                }
            }
        }
        // Incomplete final lines are not requests. EOF closes the GUI session.
    }
    private static func privateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.resolvingSymlinksInPath().path)
        guard (attributes[.posixPermissions] as? NSNumber).map({ $0.intValue & 0o077 == 0 }) == true,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw MCPFailure("Credential parent directory must be privately owned with no group/other access (0700)") }
    }
    private static func saveCredential(_ data: Data, to file: URL) throws {
        let parent = file.deletingLastPathComponent()
        try privateDirectory(parent)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw MCPFailure("Credential must not be a symlink") }
        let temporary = parent.appendingPathComponent(".credential-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw MCPFailure("Cannot create private credential") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw MCPFailure("Cannot commit private credential") }
    }
    private static func output(_ data: Data) { FileHandle.standardOutput.write(data + Data([10])) }
}
