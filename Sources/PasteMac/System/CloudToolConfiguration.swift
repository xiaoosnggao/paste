import Foundation

enum OCRProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, volcengine, tencent, baidu, google, openAICompatible
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统 OCR（本机）"
        case .volcengine: return "火山 OCR"
        case .tencent: return "腾讯云 OCR"
        case .baidu: return "百度 OCR"
        case .google: return "Google Cloud Vision"
        case .openAICompatible: return "OpenAI 兼容 OCR"
        }
    }
    var credentialKinds: [CloudCredentialKind] {
        switch self {
        case .system: return []
        case .volcengine: return [.volcAccessKey, .volcSecretKey]
        case .tencent: return [.tencentSecretID, .tencentSecretKey]
        case .baidu: return [.baiduAPIKey, .baiduSecretKey]
        case .google: return [.googleOCRAPIKey]
        case .openAICompatible: return [.openAIOCRAPIKey]
        }
    }
}
enum TranslationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, zhipu, openAICompatible, youdao, google, microsoft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统翻译"
        case .zhipu: return "智谱 GLM"
        case .openAICompatible: return "OpenAI 兼容翻译"
        case .youdao: return "有道翻译"
        case .google: return "Google 翻译"
        case .microsoft: return "Microsoft 翻译"
        }
    }
    var credentialKinds: [CloudCredentialKind] {
        switch self {
        case .system: return []
        case .zhipu: return [.zhipuAPIKey]
        case .openAICompatible: return [.openAITranslationAPIKey]
        case .youdao: return [.youdaoAppKey, .youdaoAppSecret]
        case .google: return [.googleTranslationAPIKey]
        case .microsoft: return [.microsoftTranslationKey]
        }
    }
}
struct CloudToolConfiguration: Codable, Equatable, Sendable {
    var ocrProvider: OCRProvider = .system
    var translationProvider: TranslationProvider = .system
    var ocrMode = "normal"
    var zhipuModel = "glm-4-flash-250414"
    var targetLanguage = "zh"
    var sourceLanguage = "auto"
    var tencentRegion = "ap-guangzhou"
    var tencentAction = "GeneralAccurateOCR"
    var baiduOCRMode = "general_basic"
    var openAIOCREndpoint = "https://api.openai.com/v1/chat/completions"
    var openAIOCRModel = "gpt-4o-mini"
    var openAITranslationEndpoint = "https://api.openai.com/v1/chat/completions"
    var openAITranslationModel = "gpt-4o-mini"
    var microsoftRegion = ""
    var aiServices: [AIServiceConfig] = []
    var translationAIServiceID: UUID? = nil
    var ocrAIServiceID: UUID? = nil
    var ocrProviderTitle: String {
        if let id = ocrAIServiceID, let service = aiServices.first(where: { $0.id == id }) {
            let modelPart = service.ocrModel.isEmpty ? "" : " · \(service.ocrModel)"
            return "\(service.name)\(modelPart)"
        }
        return ocrProvider.title
    }
    var translationProviderTitle: String {
        if let id = translationAIServiceID, let service = aiServices.first(where: { $0.id == id }) {
            let modelPart = service.translationModel.isEmpty ? "" : " · \(service.translationModel)"
            return "\(service.name)\(modelPart)"
        }
        return translationProvider.title
    }
    /// Compare only the selected service; editing another service must not invalidate work.
    func hasSameOCRSettings(as other: Self) -> Bool {
        guard ocrAIServiceID == other.ocrAIServiceID else { return false }
        if let id = ocrAIServiceID {
            func selection(_ config: Self) -> AIServiceConfig? {
                guard var service = config.aiServices.first(where: { $0.id == id }) else { return nil }
                service.translationModel = ""
                return service
            }
            return selection(self) == selection(other)
        }
        guard ocrProvider == other.ocrProvider else { return false }
        switch ocrProvider {
        case .system, .google: return true
        case .volcengine: return ocrMode == other.ocrMode
        case .tencent: return tencentRegion == other.tencentRegion && tencentAction == other.tencentAction
        case .baidu: return baiduOCRMode == other.baiduOCRMode
        case .openAICompatible: return openAIOCREndpoint == other.openAIOCREndpoint && openAIOCRModel == other.openAIOCRModel
        }
    }
    func hasSameTranslationSettings(as other: Self) -> Bool {
        guard sourceLanguage == other.sourceLanguage, targetLanguage == other.targetLanguage,
              translationAIServiceID == other.translationAIServiceID else { return false }
        if let id = translationAIServiceID {
            func selection(_ config: Self) -> AIServiceConfig? {
                guard var service = config.aiServices.first(where: { $0.id == id }) else { return nil }
                service.ocrModel = ""
                return service
            }
            return selection(self) == selection(other)
        }
        guard translationProvider == other.translationProvider else { return false }
        switch translationProvider {
        case .system, .youdao, .google: return true
        case .zhipu: return zhipuModel == other.zhipuModel
        case .openAICompatible: return openAITranslationEndpoint == other.openAITranslationEndpoint && openAITranslationModel == other.openAITranslationModel
        case .microsoft: return microsoftRegion == other.microsoftRegion
        }
    }
    func hasSameToolSettings(as other: Self) -> Bool {
        hasSameOCRSettings(as: other) && hasSameTranslationSettings(as: other)
    }
    init() {}
    enum CodingKeys: String, CodingKey {
        case ocrProvider, translationProvider, ocrMode, zhipuModel, targetLanguage, sourceLanguage
        case tencentRegion, tencentAction, baiduOCRMode, openAIOCREndpoint, openAIOCRModel
        case openAITranslationEndpoint, openAITranslationModel, microsoftRegion
        case aiServices, translationAIServiceID, ocrAIServiceID
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Existing users keep their explicitly configured Volc service; new installs start offline.
        ocrProvider = try c.decodeIfPresent(OCRProvider.self, forKey: .ocrProvider) ?? (c.contains(.ocrMode) ? .volcengine : .system)
        translationProvider = try c.decodeIfPresent(TranslationProvider.self, forKey: .translationProvider) ?? .zhipu
        ocrMode = try c.decodeIfPresent(String.self, forKey: .ocrMode) ?? ocrMode
        zhipuModel = try c.decodeIfPresent(String.self, forKey: .zhipuModel) ?? zhipuModel
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? sourceLanguage
        tencentRegion = try c.decodeIfPresent(String.self, forKey: .tencentRegion) ?? tencentRegion
        tencentAction = try c.decodeIfPresent(String.self, forKey: .tencentAction) ?? tencentAction
        baiduOCRMode = try c.decodeIfPresent(String.self, forKey: .baiduOCRMode) ?? baiduOCRMode
        openAIOCREndpoint = try c.decodeIfPresent(String.self, forKey: .openAIOCREndpoint) ?? openAIOCREndpoint
        openAIOCRModel = try c.decodeIfPresent(String.self, forKey: .openAIOCRModel) ?? openAIOCRModel
        openAITranslationEndpoint = try c.decodeIfPresent(String.self, forKey: .openAITranslationEndpoint) ?? openAITranslationEndpoint
        openAITranslationModel = try c.decodeIfPresent(String.self, forKey: .openAITranslationModel) ?? openAITranslationModel
        microsoftRegion = try c.decodeIfPresent(String.self, forKey: .microsoftRegion) ?? microsoftRegion
        aiServices = try c.decodeIfPresent([AIServiceConfig].self, forKey: .aiServices) ?? []
        translationAIServiceID = try c.decodeIfPresent(UUID.self, forKey: .translationAIServiceID)
        ocrAIServiceID = try c.decodeIfPresent(UUID.self, forKey: .ocrAIServiceID)
    }
}
