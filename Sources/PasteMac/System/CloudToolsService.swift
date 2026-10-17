import Foundation
import CryptoKit
import CoreFoundation

struct CloudOCRResponse: Equatable, Sendable {
    let text: String
    var provider: String = "火山 OCR"
}
struct CloudTranslationResponse: Equatable, Sendable {
    let text: String
    let model: String
    var provider: String = "智谱 GLM"
}

enum CloudToolsError: LocalizedError, Equatable {
    case missingCredential(CloudCredentialKind), invalidCredential, invalidInput, inputTooLarge, invalidConfiguration
    case authentication, rateLimited, timedOut, network(Int), httpStatus(Int), redirectRejected
    case responseTooLarge, invalidResponse, emptyResult, providerRejected(Int), incompleteTranslation
    case providerInputLimit(Int)
    var errorDescription: String? {
        switch self {
        case .missingCredential(let kind):
            return "无法读取 \(kind.title)。请在设置中补全服务凭证，并确认钥匙串已解锁。"
        case .invalidCredential: return "密钥格式无效，请删除其中的空格、换行等空白字符。"
        case .invalidInput: return "待处理内容不能为空。"
        case .inputTooLarge: return "内容超过服务限制。图片上限为 4 MB，翻译文本上限为 8192 字符或 32 KB。"
        case .providerInputLimit(let limit): return "当前翻译服务每次最多支持 \(limit) 个字符，请缩短文本。"
        case .invalidConfiguration: return "服务设置无效，请检查识别模式、模型名称和语言代码。"
        case .authentication: return "服务认证失败，请检查密钥、账号权限及服务开通状态。"
        case .rateLimited: return "请求过于频繁或服务额度不足，请稍后重试或检查服务额度。"
        case .timedOut: return "服务处理超时，请重试。"
        case .network(let code): return "网络请求失败（错误 \(code)），请检查网络连接。"
        case .httpStatus(let code): return "服务请求失败（HTTP \(code)），请检查账号和服务设置，或稍后重试。"
        case .redirectRejected: return "服务地址发生跳转，请检查设置中的接口地址。为保护密钥，请求已停止。"
        case .responseTooLarge: return "返回内容过大，请缩小图片或缩短文本后重试。"
        case .invalidResponse: return "无法读取服务返回的结果，请重试或更换服务。"
        case .emptyResult: return "服务未返回文字，请检查原始内容或更换服务。"
        case .providerRejected(let code): return "识别失败（错误 \(code)），请检查图片及服务权限。"
        case .incompleteTranslation: return "服务未返回完整译文，请缩短文本或更换模型后重试。"
        }
    }
}

/// Explicit user-triggered cloud operations. No retries, tools, key logging, or startup credential reads.
final class CloudToolsService: @unchecked Sendable {
    static let maximumImageBytes = 4 * 1024 * 1024
    static let maximumFormBytes = 8 * 1024 * 1024
    static let maximumResponseBytes = 1024 * 1024
    static let maximumResultBytes = 256 * 1024
    private let session: URLSession
    private let ownsSession: Bool
    private let credentialLoader: (CloudCredentialKind) -> String?
    private let aiServiceKeyLoader: (UUID) -> String?
    private let redirectGuard = CloudRequestGuard()
    init(session: URLSession = .shared, aiServiceKeyLoader: @escaping (UUID) -> String? = CloudToolCredentials.readAIServiceKey, credentialLoader: @escaping (CloudCredentialKind) -> String? = CloudToolCredentials.read) {
        self.credentialLoader = credentialLoader
        self.aiServiceKeyLoader = aiServiceKeyLoader
        ownsSession = session === URLSession.shared
        if ownsSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: configuration)
        } else { self.session = session }
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    func recognize(image: Data, configuration: CloudToolConfiguration) async throws -> CloudOCRResponse {
        try Task.checkCancellation()
        guard !image.isEmpty else { throw CloudToolsError.invalidInput }
        guard image.count <= (configuration.ocrProvider == .system && configuration.ocrAIServiceID == nil ? 32 * 1024 * 1024 : Self.maximumImageBytes) else { throw CloudToolsError.inputTooLarge }
        if configuration.ocrAIServiceID != nil { return try await recognizeProvider(image: image, configuration: configuration) }
        if configuration.ocrProvider == .system { return try await Self.systemOCR(image) }
        if configuration.ocrProvider == .volcengine {
            let request = try Self.ocrRequest(image: image, configuration: configuration, date: Date(), accessKey: credential(.volcAccessKey), secretKey: credential(.volcSecretKey))
            return try Self.parseOCR(await perform(request), mode: configuration.ocrMode)
        }
        return try await recognizeProvider(image: image, configuration: configuration)
    }
    func translate(text: String, configuration: CloudToolConfiguration) async throws -> CloudTranslationResponse {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudToolsError.invalidInput }
        guard text.count <= 8192, text.utf8.count <= 32_768 else { throw CloudToolsError.inputTooLarge }
        guard Self.validLanguage(configuration.sourceLanguage), Self.validLanguage(configuration.targetLanguage), configuration.targetLanguage != "auto" else { throw CloudToolsError.invalidConfiguration }
        return try await translateProvider(text: text, configuration: configuration)
    }
    func testAIService(config: AIServiceConfig, key: String) async throws {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw CloudToolsError.invalidConfiguration }
        let testModel = !config.translationModel.isEmpty ? config.translationModel : (!config.ocrModel.isEmpty ? config.ocrModel : "gpt-4o-mini")
        guard config.isEnabled, Self.validModel(testModel) else { throw CloudToolsError.invalidConfiguration }
        let headers = try Self.aiAuthorizationHeaders(key: key, vendor: config.vendor)
        let body: [String: Any] = [
            "model": testModel,
            "stream": false,
            "max_tokens": 64,
            "messages": [["role": "user", "content": "Reply with exactly OK."]]
        ]
        let request = try Self.jsonRequest(endpoint, body: body, headers: headers)
        let data = try await perform(request)
        _ = try Self.parseTranslation(data, allowTruncation: true)
    }
    func aiAuthorizationHeaders(for service: AIServiceConfig) throws -> [String: String] {
        try Self.aiAuthorizationHeaders(key: aiServiceKeyLoader(service.id) ?? "", vendor: service.vendor)
    }
    private static func aiAuthorizationHeaders(key: String, vendor: AIVendor) throws -> [String: String] {
        guard !key.isEmpty else {
            if vendor == .ollama { return [:] }
            throw CloudToolsError.authentication
        }
        guard key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CloudToolsError.invalidCredential }
        return ["Authorization": "Bearer " + key]
    }
    func credential(_ kind: CloudCredentialKind) throws -> String {
        guard let value = credentialLoader(kind), !value.isEmpty else { throw CloudToolsError.missingCredential(kind) }
        guard value.utf8.count <= 4096, value.utf8.allSatisfy({ (33...126).contains($0) }),
              kind != .volcAccessKey || Self.validIdentifier(value, maximum: 128) else { throw CloudToolsError.invalidCredential }
        return value
    }
    func perform(_ request: URLRequest) async throws -> Data {
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
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw CloudToolsError.responseTooLarge }
            var result = Data(); result.reserveCapacity(min(Self.maximumResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard result.count < Self.maximumResponseBytes else { throw CloudToolsError.responseTooLarge }
                result.append(byte)
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as CloudToolsError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw CloudToolsError.timedOut }
            throw CloudToolsError.network(error.errorCode)
        } catch { if Task.isCancelled { throw CancellationError() }; throw CloudToolsError.invalidResponse }
    }
    static func ocrRequest(image: Data, configuration: CloudToolConfiguration, date: Date, accessKey: String, secretKey: String) throws -> URLRequest {
        guard !image.isEmpty else { throw CloudToolsError.invalidInput }
        guard image.count <= maximumImageBytes else { throw CloudToolsError.inputTooLarge }
        let action: String, version: String
        switch configuration.ocrMode {
        case "normal": action = "OCRNormal"; version = "2020-08-26"
        case "multilingual": action = "MultiLanguageOCR"; version = "2022-08-31"
        default: throw CloudToolsError.invalidConfiguration
        }
        guard validIdentifier(accessKey, maximum: 128), !secretKey.isEmpty, secretKey.utf8.count <= 4096 else { throw CloudToolsError.invalidCredential }
        let encodedImage = try percentEncode(image.base64EncodedString())
        let body = Data(("image_base64=" + encodedImage).utf8)
        guard body.count <= maximumFormBytes else { throw CloudToolsError.inputTooLarge }
        let query = "Action=\(action)&Version=\(version)", host = "visual.volcengineapi.com", contentType = "application/x-www-form-urlencoded"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8))
        let hash = hex(SHA256.hash(data: body)), headers = "content-type;host;x-content-sha256;x-date"
        let canonical = "POST\n/\n\(query)\ncontent-type:\(contentType)\nhost:\(host)\nx-content-sha256:\(hash)\nx-date:\(stamp)\n\n\(headers)\n\(hash)"
        let scope = "\(day)/cn-north-1/cv/request"
        let signable = "HMAC-SHA256\n\(stamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        var key = Data(secretKey.utf8)
        for component in [day, "cn-north-1", "cv", "request"] { key = hmac(key, component) }
        let signature = hex(hmac(key, signable))
        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 45; request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(host, forHTTPHeaderField: "Host"); request.setValue(stamp, forHTTPHeaderField: "X-Date")
        request.setValue(hash, forHTTPHeaderField: "X-Content-Sha256"); request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(headers), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
    private static func parseOCR(_ data: Data, mode: String) throws -> CloudOCRResponse {
        guard data.count <= maximumResponseBytes, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["code"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, (-1_000_000...1_000_000).contains(number.intValue) else { throw CloudToolsError.invalidResponse }
        guard number.intValue == 10000 else { throw CloudToolsError.providerRejected(number.intValue) }
        guard let payload = object["data"] as? [String: Any] else { throw CloudToolsError.invalidResponse }
        let lines: [String]
        if mode == "normal" {
            guard let text = payload["line_texts"] as? [String] else { throw CloudToolsError.invalidResponse }; lines = text
        } else {
            guard let infos = payload["ocr_infos"] as? [[String: Any]], infos.allSatisfy({ $0["text"] is String }) else { throw CloudToolsError.invalidResponse }
            lines = infos.compactMap { $0["text"] as? String }
        }
        let text = lines.joined(separator: "\n")
        guard text.utf8.count <= maximumResultBytes else { throw CloudToolsError.responseTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudToolsError.emptyResult }
        return .init(text: text)
    }
    static func parseTranslation(_ data: Data, allowTruncation: Bool = false) throws -> CloudTranslationResponse {
        guard data.count <= maximumResponseBytes, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let model = object["model"] as? String, validModel(model),
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let finish = choice["finish_reason"] as? String, let message = choice["message"] as? [String: Any] else { throw CloudToolsError.invalidResponse }
        guard (finish == "stop" || (allowTruncation && finish == "length")), message["function_call"] == nil, message["tool_calls"] == nil || (message["tool_calls"] as? [Any])?.isEmpty == true else { throw CloudToolsError.incompleteTranslation }
        guard let text = message["content"] as? String else { throw CloudToolsError.invalidResponse }
        guard text.utf8.count <= maximumResultBytes else { throw CloudToolsError.responseTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudToolsError.emptyResult }
        return .init(text: text, model: model)
    }
    static func validLanguage(_ value: String) -> Bool {
        value.count >= 2 && value.count <= 32 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    static func percentEncode(_ value: String) throws -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var encoded = [UInt8](); encoded.reserveCapacity(min(maximumFormBytes, value.utf8.count + value.utf8.count / 8))
        for byte in value.utf8 {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) { encoded.append(byte) }
            else { encoded.append(37); encoded.append(digits[Int(byte >> 4)]); encoded.append(digits[Int(byte & 15)]) }
            guard encoded.count <= maximumFormBytes - 13 else { throw CloudToolsError.inputTooLarge }
        }
        return String(decoding: encoded, as: UTF8.self)
    }
    static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }
    static func hex<S: Sequence>(_ value: S) -> String where S.Element == UInt8 { value.map { String(format: "%02x", $0) }.joined() }
}

final class CloudRequestGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
