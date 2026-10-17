import Foundation

public enum AIVendor: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek = "deepseek"
    case openai = "openai"
    case moonshot = "moonshot"
    case zhipu = "zhipu"
    case claude = "claude"
    case ollama = "ollama"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .moonshot: return "Kimi (月之暗面)"
        case .zhipu: return "智谱清言 (GLM)"
        case .claude: return "Claude (兼容)"
        case .ollama: return "Ollama (本地)"
        case .custom: return "自定义 (OpenAI 兼容)"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .moonshot: return "https://api.moonshot.cn/v1/chat/completions"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/chat/completions"
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        }
    }

    public var defaultTranslationModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .claude: return "claude-haiku-5-5"
        case .ollama: return "qwen2.5:7b"
        case .custom: return "gpt-4o-mini"
        }
    }

    public var defaultOCRModel: String {
        switch self {
        case .deepseek: return ""
        case .openai: return "gpt-4o"
        case .moonshot: return ""
        case .zhipu: return "glm-4v-flash"
        case .claude: return "claude-sonnet-5-5"
        case .ollama: return "llava"
        case .custom: return ""
        }
    }

    public var apiKeyHelpURL: URL? {
        switch self {
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .moonshot: return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .zhipu: return URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        default: return nil
        }
    }
}

public struct AIServiceConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var vendor: AIVendor
    public var endpoint: String
    public var translationModel: String
    public var ocrModel: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        vendor: AIVendor = .deepseek,
        endpoint: String = "",
        translationModel: String = "",
        ocrModel: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name.isEmpty ? vendor.title : name
        self.vendor = vendor
        self.endpoint = endpoint.isEmpty ? vendor.defaultEndpoint : endpoint
        self.translationModel = translationModel.isEmpty ? vendor.defaultTranslationModel : translationModel
        self.ocrModel = ocrModel.isEmpty ? vendor.defaultOCRModel : ocrModel
        self.isEnabled = isEnabled
    }
}

public enum ToolSelectionItem: Hashable, Identifiable {
    case builtin(String)
    case aiService(UUID)

    public var id: String {
        switch self {
        case .builtin(let s): return "builtin_\(s)"
        case .aiService(let id): return "ai_\(id.uuidString)"
        }
    }
}
