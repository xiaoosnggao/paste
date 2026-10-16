import Foundation
import Security
import LocalAuthentication

// Separate from history, backup JSON, environment variables, and other apps' credentials.
enum CloudCredentialKind: String, CaseIterable, Sendable {
    case volcAccessKey, volcSecretKey, zhipuAPIKey
    case tencentSecretID, tencentSecretKey, baiduAPIKey, baiduSecretKey, googleOCRAPIKey, openAIOCRAPIKey
    case openAITranslationAPIKey, youdaoAppKey, youdaoAppSecret, googleTranslationAPIKey, microsoftTranslationKey
    var title: String {
        switch self {
        case .volcAccessKey: return "火山 Access Key"
        case .volcSecretKey: return "火山 Secret Key"
        case .zhipuAPIKey: return "智谱 API Key"
        case .tencentSecretID: return "腾讯 Secret ID"
        case .tencentSecretKey: return "腾讯 Secret Key"
        case .baiduAPIKey: return "百度 API Key"
        case .baiduSecretKey: return "百度 Secret Key"
        case .googleOCRAPIKey: return "Google Vision API Key"
        case .openAIOCRAPIKey: return "OpenAI 兼容 OCR API Key"
        case .openAITranslationAPIKey: return "OpenAI 兼容翻译 API Key"
        case .youdaoAppKey: return "有道应用 ID"
        case .youdaoAppSecret: return "有道应用密钥"
        case .googleTranslationAPIKey: return "Google 翻译 API Key"
        case .microsoftTranslationKey: return "Microsoft 翻译密钥"
        }
    }
}

enum CloudToolCredentials {
    private static let service = "com.gaoxs.pasteboard.cloud-tools"
    static func read(_ kind: CloudCredentialKind) -> String? {
        var query = baseQuery(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // A changed app signature must not trigger an unsolicited Keychain prompt.
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, data.count <= 4096 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, kind: CloudCredentialKind) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 4096,
              cleaned.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CloudCredentialError.invalidValue }
        let query = baseQuery(kind)
        let updates: [String: Any] = [kSecValueData as String: Data(cleaned.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CloudCredentialError.keychain(updated) }
        var item = query
        item[kSecValueData as String] = Data(cleaned.utf8)
        item[kSecAttrLabel as String] = "Pasteboard 云端工具：\(kind.rawValue)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CloudCredentialError.keychain(added) }
    }
    static func delete(_ kind: CloudCredentialKind) throws {
        let result = SecItemDelete(baseQuery(kind) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudCredentialError.keychain(result) }
    }
    private static func baseQuery(_ kind: CloudCredentialKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: kind.rawValue]
    }
}
enum CloudCredentialError: LocalizedError {
    case invalidValue, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidValue: return "密钥不能为空，不能含空格、换行等空白字符，长度不能超过 4096 字节。"
        case .keychain(let status): return "无法保存或删除密钥（错误 \(status)），请确认钥匙串已解锁。"
        }
    }
}
