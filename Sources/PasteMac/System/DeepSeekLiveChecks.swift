#if DEBUG
import Foundation

/// Opt-in account integration check. Reads the configured Keychain item, never the clipboard/history.
@MainActor
enum DeepSeekLiveChecks {
    static func run() async throws -> Int {
        guard let data = UserDefaults.standard.data(forKey: "cloudToolConfiguration.v1") else { throw CloudToolsError.invalidConfiguration }
        var configuration = try JSONDecoder().decode(CloudToolConfiguration.self, from: data)
        guard let id = configuration.translationAIServiceID,
              let service = configuration.aiServices.first(where: { $0.id == id }), service.isEnabled,
              service.vendor == .deepseek, service.translationModel == "deepseek-flash",
              service.endpoint == AIVendor.deepseek.defaultEndpoint else { throw CloudToolsError.invalidConfiguration }
        let client = CloudToolsService()
        configuration.sourceLanguage = "zh"; configuration.targetLanguage = "en"
        let translated = try await client.translate(text: "你好，世界。", configuration: configuration)
        guard translated.text.lowercased().contains("hello") else { throw CloudToolsError.invalidResponse }
        print("DEEPSEEK LIVE translation: \(translated.text)")
        let input = ContextSuggestionInput(text: "{\"name\":\"Clipflow\",\"enabled\":true}", kind: "json",
                                           sourceName: "Visual Studio Code", sourceBundleID: "com.microsoft.VSCode",
                                           targetName: "TextEdit", targetBundleID: "com.apple.TextEdit")
        let suggestions = ContextSuggestionsService(client: client)
        let options = try await suggestions.suggest(input: input, service: service)
        guard (3...5).contains(options.count), options.allSatisfy({ !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.detail.count <= 80 }) else { throw CloudToolsError.invalidResponse }
        print("DEEPSEEK LIVE suggestions: \(options.map { "\($0.title)：\($0.detail)" }.joined(separator: " / "))")
        let formatted = try await suggestions.transform(input: input,
            suggestion: .init(id: "live-format", title: "格式化 JSON", instruction: "仅格式化为两空格缩进的 JSON，完整保留字段和值，不要代码围栏或解释。"), service: service)
        guard let body = formatted.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["name"] as? String == "Clipflow", object["enabled"] as? Bool == true else { throw CloudToolsError.invalidResponse }
        print("DEEPSEEK LIVE JSON transform: field values preserved")
        return 3
    }
}
#endif
