import Foundation
import CryptoKit

extension CloudToolsService {
    static func jsonRequest(_ endpoint: String, body: Any, headers: [String: String] = [:]) throws -> URLRequest {
        var request = try baseRequest(endpoint)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard request.httpBody!.count <= maximumFormBytes else { throw CloudToolsError.inputTooLarge }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    static func baseRequest(_ endpoint: String) throws -> URLRequest {
        guard let components = URLComponents(string: endpoint), components.scheme == "https", let host = components.host,
              !host.isEmpty, components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil, endpoint.utf8.count <= 2048, let url = components.url else { throw CloudToolsError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 60; request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    static func formRequest(_ endpoint: String, fields: [String: String]) throws -> URLRequest {
        var request = try baseRequest(endpoint)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try formBody(fields)
        return request
    }
    static func formBody(_ fields: [String: String]) throws -> Data {
        let fields = try fields.sorted { $0.key < $1.key }.map { try percentEncode($0.key) + "=" + percentEncode($0.value) }
        let data = Data(fields.joined(separator: "&").utf8)
        guard data.count <= maximumFormBytes else { throw CloudToolsError.inputTooLarge }; return data
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CloudToolsError.invalidResponse }; return object
    }
    static func resultText(_ text: String?) throws -> String {
        guard let text else { throw CloudToolsError.invalidResponse }
        guard text.utf8.count <= maximumResultBytes else { throw CloudToolsError.responseTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudToolsError.emptyResult }; return text
    }
    static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    static func language(_ code: String, provider: TranslationProvider) -> String {
        switch (code.lowercased(), provider) {
        case ("zh", .youdao), ("zh-hans", .youdao): return "zh-CHS"
        case ("zh-hant", .youdao), ("zh-tw", .youdao): return "zh-CHT"
        case ("zh", .microsoft): return "zh-Hans"
        case ("zh-hant", .google): return "zh-TW"
        case ("zh", .google), ("zh-hans", .google): return "zh-CN"
        default: return code
        }
    }
}
