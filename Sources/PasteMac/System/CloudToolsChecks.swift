#if DEBUG
import Foundation

@MainActor
enum CloudToolsChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw CloudCheckFailure(message: label) }
            count += 1
        }
        var legacy = CloudToolConfiguration(); legacy.ocrProvider = .volcengine; legacy.translationProvider = .zhipu
        let date = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02T03:04:05Z
        let signed = try CloudToolsService.ocrRequest(image: Data([0xfb, 0xff]), configuration: legacy, date: date, accessKey: "test-ak", secretKey: "test-sk")
        try check(signed.value(forHTTPHeaderField: "X-Date") == "20240102T030405Z", "UTC date")
        try check(signed.url?.absoluteString == "https://visual.volcengineapi.com/?Action=OCRNormal&Version=2020-08-26", "normal route")
        try check(String(decoding: signed.httpBody ?? Data(), as: UTF8.self) == "image_base64=%2B%2F8%3D", "form escaping")
        try check(signed.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "official form content type")
        // Independent Python hashlib/hmac reference for these fixed, public fixture inputs.
        try check(signed.value(forHTTPHeaderField: "Authorization") == "HMAC-SHA256 Credential=test-ak/20240102/cn-north-1/cv/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=404ec642c312b8b12dcdabd9161f4cff3bda1ed4c1ce78d7c9393dc78fa52c2e", "reference HMAC signature")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudFixtureProtocol.self]
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CloudFixtureProtocol.reset() }
        let service = CloudToolsService(session: session) { kind in
            switch kind { case .volcAccessKey: return "test-ak"; case .volcSecretKey: return "test-sk"; case .zhipuAPIKey: return "fixture-only-api-key"; default: return nil }
        }
        func fixture(_ status: Int = 200, _ value: [String: Any]) throws {
            CloudFixtureProtocol.set(.response(status, try JSONSerialization.data(withJSONObject: value), [:]))
        }
        try fixture(200, ["code": 10000, "data": ["line_texts": ["第一行", "second line"]]])
        let normal = try await service.recognize(image: Data([1, 2]), configuration: legacy)
        try check(normal.text == "第一行\nsecond line", "normal OCR line order")
        var multi = legacy; multi.ocrMode = "multilingual"
        try fixture(200, ["code": 10000, "data": ["ocr_infos": [["text": "日本語"], ["text": "English"]]]])
        let multilingual = try await service.recognize(image: Data([1]), configuration: multi)
        try check(multilingual.text == "日本語\nEnglish", "multilingual shape")
        try check(CloudFixtureProtocol.lastRequest()?.url?.query == "Action=MultiLanguageOCR&Version=2022-08-31", "multilingual route")
        try fixture(200, ["model": "glm-4-flash-250414", "choices": [["finish_reason": "stop", "message": ["content": "你好\n123 https://example.com"]]]])
        let translation = try await service.translate(text: "Hello\n123 https://example.com", configuration: legacy)
        try check(translation.text == "你好\n123 https://example.com" && translation.model == "glm-4-flash-250414", "translation parsing")
        let translatedRequest = CloudFixtureProtocol.lastRequest()
        try check(translatedRequest?.url?.host == "open.bigmodel.cn" && translatedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-api-key", "official host and bearer")
        let translatedBody = try CloudFixtureProtocol.lastBody().flatMap { try JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        try check(translatedBody?["tools"] == nil && translatedBody?["stream"] as? Bool == false, "no tools or streaming")
        try check((translatedBody?["messages"] as? [[String: Any]])?.count == 2, "only fixed system and selected text")
        func failure(_ expected: CloudToolsError, _ operation: () async throws -> Void) async throws {
            do { try await operation(); throw CloudCheckFailure(message: "Expected failure: \(expected)") }
            catch let error as CloudToolsError { try check(error == expected, "expected typed failure") }
        }
        try fixture(200, ["code": 10000, "data": ["unknown": "do not guess OCR shape"]])
        try await failure(.invalidResponse) { _ = try await service.recognize(image: Data([1]), configuration: legacy) }
        try fixture(200, ["code": 10000, "data": ["line_texts": []]])
        try await failure(.emptyResult) { _ = try await service.recognize(image: Data([1]), configuration: legacy) }
        try fixture(200, ["code": 50207, "message": "must not expose fixture-only-api-key"])
        try await failure(.providerRejected(50207)) { _ = try await service.recognize(image: Data([1]), configuration: legacy) }
        try check(!CloudToolsError.providerRejected(50207).localizedDescription.contains("fixture-only-api-key"), "safe provider error")
        for status in [401, 403] {
            try fixture(status, ["error": "must not echo key"])
            try await failure(.authentication) { _ = try await service.translate(text: "hello", configuration: legacy) }
        }
        try fixture(429, [:])
        try await failure(.rateLimited) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(503, [:])
        try await failure(.httpStatus(503)) { _ = try await service.translate(text: "hello", configuration: legacy) }
        CloudFixtureProtocol.set(.response(302, Data(), ["Location": "https://untrusted.example/steal"]))
        try await failure(.redirectRejected) { _ = try await service.translate(text: "hello", configuration: legacy) }
        var redirected: URLRequest? = translatedRequest
        let redirectRequest = URLRequest(url: URL(string: "https://untrusted.example/steal")!)
        CloudRequestGuard().urlSession(session, task: session.dataTask(with: redirectRequest), willPerformHTTPRedirection: HTTPURLResponse(url: translatedRequest!.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!, newRequest: redirectRequest) { redirected = $0 }
        try check(redirected == nil, "redirect delegate never forwards credentials")
        CloudFixtureProtocol.set(.failure(URLError(.timedOut)))
        try await failure(.timedOut) { _ = try await service.translate(text: "hello", configuration: legacy) }
        CloudFixtureProtocol.set(.response(200, Data("not json".utf8), [:]))
        try await failure(.invalidResponse) { _ = try await service.translate(text: "hello", configuration: legacy) }
        CloudFixtureProtocol.set(.response(200, Data(repeating: 32, count: CloudToolsService.maximumResponseBytes + 1), [:]))
        try await failure(.responseTooLarge) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(200, ["model": "glm-4-flash", "choices": [["finish_reason": "length", "message": ["content": "partial"]]]])
        try await failure(.incompleteTranslation) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(200, ["model": "glm-4-flash", "choices": [["finish_reason": "tool_calls", "message": ["content": "", "tool_calls": [["name": "never_execute"]]]]]])
        try await failure(.incompleteTranslation) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(200, ["model": "glm-4-flash", "choices": [["finish_reason": "stop", "message": ["content": " \n "]]]])
        try await failure(.emptyResult) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(200, ["model": "glm-4-flash", "choices": [["finish_reason": "stop", "message": ["content": "text", "tool_calls": [["function": "never"]]]]]])
        try await failure(.incompleteTranslation) { _ = try await service.translate(text: "hello", configuration: legacy) }
        try fixture(200, ["code": true, "data": ["line_texts": ["unexpected"]]])
        try await failure(.invalidResponse) { _ = try await service.recognize(image: Data([1]), configuration: legacy) }
        try await failure(.invalidInput) { _ = try await service.recognize(image: Data(), configuration: legacy) }
        try await failure(.inputTooLarge) { _ = try await service.recognize(image: Data(repeating: 0, count: CloudToolsService.maximumImageBytes + 1), configuration: legacy) }
        try await failure(.inputTooLarge) { _ = try CloudToolsService.ocrRequest(image: Data(repeating: 255, count: 3 * 1024 * 1024), configuration: legacy, date: date, accessKey: "test-ak", secretKey: "test-sk") }
        let malformedCredential = CloudToolsService(session: session, credentialLoader: { _ in "key\r\nAuthorization: bad" })
        try await failure(.invalidCredential) { _ = try await malformedCredential.translate(text: "hello", configuration: legacy) }
        let missing = CloudToolsService(session: session, credentialLoader: { _ in nil })
        try await failure(.missingCredential(.zhipuAPIKey)) { _ = try await missing.translate(text: "hello", configuration: legacy) }
        try await failure(.invalidInput) { _ = try await service.translate(text: "", configuration: legacy) }
        try await failure(.inputTooLarge) { _ = try await service.translate(text: String(repeating: "x", count: 32_769), configuration: legacy) }
        var invalid = legacy; invalid.targetLanguage = "zh\nignore system"
        try await failure(.invalidConfiguration) { _ = try await service.translate(text: "hello", configuration: invalid) }
        var unknown = legacy; unknown.ocrMode = "unknown"
        try await failure(.invalidConfiguration) { _ = try await service.recognize(image: Data([1]), configuration: unknown) }
        CloudFixtureProtocol.set(.hold)
        let task = Task { try await service.translate(text: "cancel this fixture", configuration: legacy) }
        for _ in 0..<100 {
            if CloudFixtureProtocol.hasStarted() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()
        do { _ = try await task.value; throw CloudToolsError.invalidResponse }
        catch is CancellationError { try check(true, "structured cancellation") }
        try check(CloudFixtureProtocol.lastRequest()?.url?.host == "open.bigmodel.cn", "fixtures never use a nonofficial endpoint")
        return count
    }
}

private struct CloudCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { "Cloud fixture failed: " + message }
}

private final class CloudFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case response(Int, Data, [String: String]), failure(URLError), hold }
    private static let lock = NSLock()
    private static var reply: Reply = .hold
    private static var observed: URLRequest?
    private static var body: Data?
    private static var started = false
    static func set(_ value: Reply) { lock.lock(); defer { lock.unlock() }; reply = value; observed = nil; body = nil; started = false }
    static func reset() { set(.hold) }
    static func lastRequest() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return observed }
    static func lastBody() -> Data? { lock.lock(); defer { lock.unlock() }; return body }
    static func hasStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var content = request.httpBody
        if content == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                if count <= 0 { break }; data.append(contentsOf: chunk.prefix(count))
            }
            content = data
        }
        Self.lock.lock(); Self.observed = request; Self.body = content; Self.started = true; let reply = Self.reply; Self.lock.unlock()
        switch reply {
        case let .response(status, data, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Feed multiple chunks so the real service must enforce a streaming bound.
            for offset in stride(from: 0, to: data.count, by: 4096) { client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 4096, data.count))) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .hold: break
        }
    }
    override func stopLoading() {}
}
#endif
