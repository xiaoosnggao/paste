import Foundation

/// What a streamed chat request produced. Providers that ignore `stream: true`
/// answer with one ordinary JSON body, which callers parse as before.
enum CloudStreamOutcome: Sendable {
    case streamed(content: String, finishReason: String?)
    case body(Data)
}

/// Incremental server-sent-events reader for OpenAI-compatible chat completions.
struct ChatStreamAccumulator: Sendable {
    private(set) var content = ""
    private(set) var finishReason: String?
    private(set) var done = false

    /// Feeds one line of the event stream. Returns true when `content` grew.
    @discardableResult
    mutating func feed(line raw: String) throws -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return false }
        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if value == "[DONE]" { done = true; return false }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first else { return false }
        if let finish = choice["finish_reason"] as? String { finishReason = finish }
        if let delta = choice["delta"] as? [String: Any] {
            if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty { throw CloudToolsError.incompleteTranslation }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                content += piece
                guard content.utf8.count <= CloudToolsService.maximumResultBytes else { throw CloudToolsError.responseTooLarge }
                return true
            }
        }
        return false
    }
}

extension CloudToolsService {
    /// Sends a chat request with `stream: true`. Each time new text arrives, `onContent`
    /// receives everything streamed so far. A plain JSON reply is returned unparsed.
    func performStreaming(_ request: URLRequest,
                          onContent: @escaping @Sendable (String) async -> Void) async throws -> CloudStreamOutcome {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CloudToolsError.invalidResponse }
            guard let scheme = http.url?.scheme,
                  (scheme == "https" || (scheme == "http" && (http.url?.host == "localhost" || http.url?.host == "127.0.0.1"))),
                  http.url?.host == request.url?.host else { throw CloudToolsError.redirectRejected }
            switch http.statusCode {
            case 200: break
            case 300..<400: throw CloudToolsError.redirectRejected
            case 401, 403: throw CloudToolsError.authentication
            case 429: throw CloudToolsError.rateLimited
            default: throw CloudToolsError.httpStatus(http.statusCode)
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("text/event-stream") {
                var accumulator = ChatStreamAccumulator()
                var total = 0
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    total += line.utf8.count + 1
                    guard total <= Self.maximumResponseBytes else { throw CloudToolsError.responseTooLarge }
                    if try accumulator.feed(line: line) { await onContent(accumulator.content) }
                    if accumulator.done { break }
                }
                try Task.checkCancellation()
                return .streamed(content: accumulator.content, finishReason: accumulator.finishReason)
            }
            var result = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard result.count < Self.maximumResponseBytes else { throw CloudToolsError.responseTooLarge }
                result.append(byte)
            }
            try Task.checkCancellation()
            return .body(result)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CloudToolsError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw CloudToolsError.timedOut }
            throw CloudToolsError.network(error.errorCode)
        } catch { if Task.isCancelled { throw CancellationError() }; throw CloudToolsError.invalidResponse }
    }
}
