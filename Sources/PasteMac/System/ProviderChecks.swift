#if DEBUG
import Foundation

@MainActor
enum ProviderChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw ProviderCheckFailure(label: label) }; count += 1
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let fresh = CloudToolConfiguration()
        try check(fresh.ocrProvider == .system && fresh.translationProvider == .system, "fresh defaults offline system")
        let legacy = try JSONDecoder().decode(CloudToolConfiguration.self, from: Data(#"{"ocrMode":"normal","zhipuModel":"glm-4-flash","targetLanguage":"en","sourceLanguage":"auto"}"#.utf8))
        try check(legacy.ocrProvider == .volcengine && legacy.translationProvider == .zhipu, "legacy preserves providers")
        try check(try JSONDecoder().decode(CloudToolConfiguration.self, from: JSONEncoder().encode(fresh)) == fresh, "configuration round trip")
        try check(OCRProvider.allCases.count == 6 && TranslationProvider.allCases.count == 6, "complete provider catalogs")
        try check(OCRProvider.system.credentialKinds.isEmpty && TranslationProvider.system.credentialKinds.isEmpty, "system needs no credentials")
        for endpoint in ["http://example.com/v1/chat/completions", "https://name:secret@example.com/path", "https://example.com/path?api_key=secret", "https://example.com/path#part", "file:///tmp/api"] {
            do { _ = try CloudToolsService.baseRequest(endpoint); throw ProviderCheckFailure(label: "unsafe endpoint accepted") }
            catch CloudToolsError.invalidConfiguration { try check(true, "unsafe endpoint rejected") }
        }
        let protocolConfig = URLSessionConfiguration.ephemeral
        protocolConfig.protocolClasses = [ProviderFixtureProtocol.self]
        protocolConfig.connectionProxyDictionary = [:]
        let session = URLSession(configuration: protocolConfig)
        defer { session.invalidateAndCancel(); ProviderFixtureProtocol.clear() }
        let service = CloudToolsService(session: session, credentialLoader: { _ in "fixture-key" })
        var config = fresh
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x01])
        let tencent = try json(["Response": ["TextDetections": [["DetectedText": "中文"], ["DetectedText": "English"]]]])
        config.ocrProvider = .tencent
        ProviderFixtureProtocol.set([tencent])
        let tencentResult = try await service.recognize(image: bytes, configuration: config)
        try check(tencentResult.text == "中文\nEnglish" && tencentResult.provider == OCRProvider.tencent.title, "Tencent text and attribution")
        let tcRequest = ProviderFixtureProtocol.requests.last!
        try check(tcRequest.url?.host == "ocr.tencentcloudapi.com", "Tencent official endpoint")
        try check(tcRequest.value(forHTTPHeaderField: "X-TC-Action") == "GeneralAccurateOCR" && tcRequest.value(forHTTPHeaderField: "X-TC-Version") == "2018-11-19", "Tencent action/version")
        try check(tcRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("TC3-HMAC-SHA256 Credential=fixture-key/") == true, "Tencent TC3 signature")
        config.tencentAction = "GeneralBasicOCR"; ProviderFixtureProtocol.set([tencent])
        _ = try await service.recognize(image: bytes, configuration: config)
        try check(ProviderFixtureProtocol.requests.last?.value(forHTTPHeaderField: "X-TC-Action") == "GeneralBasicOCR", "Tencent basic mode")
        let reference = try CloudToolsService.tencentRequest(image: Data([1, 2]), configuration: fresh, date: Date(timeIntervalSince1970: 1_704_164_645), secretID: "test-id", secretKey: "test-sk")
        try check(reference.value(forHTTPHeaderField: "Authorization") == "TC3-HMAC-SHA256 Credential=test-id/2024-01-02/ocr/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=d69a3a40925d20aa6df53325948e37fee2ca4542a838a48d517baf5cbf6805dc", "Tencent independent signature")
        config = fresh; config.ocrProvider = .baidu
        ProviderFixtureProtocol.set([try json(["access_token": "fixture-token"]), try json(["words_result": [["words": "百度测试"]]])])
        let baidu = try await service.recognize(image: bytes, configuration: config)
        try check(baidu.text == "百度测试" && baidu.provider == OCRProvider.baidu.title, "Baidu response")
        try check(ProviderFixtureProtocol.requests.count == 2 && ProviderFixtureProtocol.requests.first?.url?.path == "/oauth/2.0/token", "Baidu token exchange")
        try check(ProviderFixtureProtocol.requests.last?.url?.query == "access_token=fixture-token", "Baidu authorized OCR request")
        try check(ProviderFixtureProtocol.bodies.first.map { String(decoding: $0, as: UTF8.self).contains("client_secret=fixture-key") } == true, "Baidu token credentials in POST body")
        config = fresh; config.ocrProvider = .google
        ProviderFixtureProtocol.set([try json(["responses": [["fullTextAnnotation": ["text": "Google text"]]]])])
        let googleOCR = try await service.recognize(image: bytes, configuration: config)
        try check(googleOCR.text == "Google text", "Google document OCR")
        try check(ProviderFixtureProtocol.requests.last?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "fixture-key" && ProviderFixtureProtocol.requests.last?.url?.query == nil, "Google key in header")
        let googleBody = try JSONSerialization.jsonObject(with: ProviderFixtureProtocol.bodies.last!) as? [String: Any]
        try check((googleBody?["requests"] as? [[String: Any]])?.count == 1, "Google single image")
        let completion = try json(["model": "vendor/model-v1", "choices": [["finish_reason": "stop", "message": ["content": "模型结果"]]]])
        config = fresh; config.ocrProvider = .openAICompatible; config.openAIOCREndpoint = "https://gateway.example.test/v1/chat/completions"; config.openAIOCRModel = "vendor/vision"
        ProviderFixtureProtocol.set([completion])
        let compatibleOCR = try await service.recognize(image: bytes, configuration: config)
        try check(compatibleOCR.text == "模型结果" && compatibleOCR.provider == OCRProvider.openAICompatible.title, "compatible vision result")
        try check(ProviderFixtureProtocol.requests.last?.url?.host == "gateway.example.test", "custom HTTPS endpoint")
        let imageBody = try JSONSerialization.jsonObject(with: ProviderFixtureProtocol.bodies.last!) as? [String: Any]
        let imageMessages = imageBody?["messages"] as? [[String: Any]]
        let imageContent = imageMessages?.first?["content"] as? [[String: Any]]
        let imageURL = imageContent?.last?["image_url"] as? [String: Any]
        try check(imageURL?["url"] as? String == "data:image/png;base64," + bytes.base64EncodedString(), "base64 vision message")
        config = fresh; config.translationProvider = .openAICompatible; config.openAITranslationModel = "vendor/text"
        ProviderFixtureProtocol.set([completion])
        let compatible = try await service.translate(text: "hello", configuration: config)
        try check(compatible.model == "vendor/model-v1" && compatible.provider == TranslationProvider.openAICompatible.title, "compatible translation attribution")
        config = fresh; config.translationProvider = .youdao
        ProviderFixtureProtocol.set([try json(["errorCode": "0", "translation": ["你好"]])])
        let youdao = try await service.translate(text: "Hello", configuration: config)
        try check(youdao.text == "你好" && youdao.model == "youdao-v3", "Youdao response")
        let youdaoBody = String(decoding: ProviderFixtureProtocol.bodies.last!, as: UTF8.self)
        try check(youdaoBody.contains("signType=v3") && youdaoBody.contains("to=zh-CHS"), "Youdao signature/language")
        let youdaoReference = try CloudToolsService.youdaoRequest(text: "1234567890abcdefghij中文🙂", configuration: fresh, date: Date(timeIntervalSince1970: 1_704_164_645), salt: "test-salt", appKey: "test-app", appSecret: "test-secret")
        try check(String(decoding: youdaoReference.httpBody!, as: UTF8.self).contains("sign=1da3c9615da610169b45174009a3f9f0aa2e40e023936ad3e82f7ef0bfd8c672"), "Youdao independent signature Unicode")
        config = fresh; config.translationProvider = .google
        ProviderFixtureProtocol.set([try json(["data": ["translations": [["translatedText": "你好"]]]])])
        let googleTranslation = try await service.translate(text: "Hello", configuration: config)
        try check(googleTranslation.text == "你好" && googleTranslation.provider == TranslationProvider.google.title, "Google translation")
        let googleTranslationBody = String(decoding: ProviderFixtureProtocol.bodies.last!, as: UTF8.self)
        try check(!googleTranslationBody.contains("source") && googleTranslationBody.contains("zh-CN"), "Google autodetect and Chinese language mapping")
        config = fresh; config.translationProvider = .microsoft; config.microsoftRegion = "eastasia"
        ProviderFixtureProtocol.set([try json([["translations": [["text": "你好", "to": "zh-Hans"]]]])])
        let microsoft = try await service.translate(text: "Hello", configuration: config)
        try check(microsoft.text == "你好" && microsoft.model == "microsoft-v3", "Microsoft response")
        try check(ProviderFixtureProtocol.requests.last?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region") == "eastasia", "Microsoft region header")
        try check(ProviderFixtureProtocol.requests.last?.url?.query?.contains("to=zh-Hans") == true && ProviderFixtureProtocol.requests.last?.url?.query?.contains("from=") == false, "Microsoft language/autodetect")
        for provider in OCRProvider.allCases where provider != .system && provider != .volcengine {
            do { _ = try CloudToolsService.parseProviderOCR(try json([:]), provider: provider); throw ProviderCheckFailure(label: "malformed OCR accepted") }
            catch is CloudToolsError { try check(true, "malformed OCR rejected") }
        }
        for provider in TranslationProvider.allCases where provider != .system {
            do { _ = try CloudToolsService.parseProviderTranslation(try json([:]), provider: provider); throw ProviderCheckFailure(label: "malformed translation accepted") }
            catch is CloudToolsError { try check(true, "malformed translation rejected") }
        }
        let missing = CloudToolsService(session: session, credentialLoader: { _ in nil })
        config = fresh; config.ocrProvider = .tencent
        do { _ = try await missing.recognize(image: bytes, configuration: config); throw ProviderCheckFailure(label: "missing Tencent key accepted") }
        catch CloudToolsError.missingCredential(.tencentSecretID) { try check(true, "missing credential type") }
        return count
    }
}
private struct ProviderCheckFailure: LocalizedError {
    let label: String
    var errorDescription: String? { "Provider fixture failed: " + label }
}
private final class ProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies: [Data] = []
    private static var seen: [URLRequest] = []
    private static var contents: [Data] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return contents }
    static func set(_ replies: [Data]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; seen = []; contents = [] }
    static func clear() { set([]) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        Self.lock.lock(); Self.seen.append(request); Self.contents.append(body)
        let response = Self.replies.isEmpty ? nil : Self.replies.removeFirst(); Self.lock.unlock()
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
