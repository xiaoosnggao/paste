import Foundation
import NaturalLanguage
import PasteCore

/// Uses only the sentence models installed with macOS. No network client, external app,
/// automatic model download or lexical stand-in exists on this path.
actor LocalKnowledgeEmbeddingProvider {
    enum Failure: Error, LocalizedError {
        case emptyText, inputTooLong, unsupportedLanguage, modelUnavailable(String), vectorUnavailable
        var errorDescription: String? {
            switch self {
            case .emptyText: return "内容为空"
            case .inputTooLong: return "请分段建立索引"
            case .unsupportedLanguage: return "暂不支持此语言的本地语义索引"
            case .modelUnavailable: return "本机语义模型不可用，关键词搜索仍可使用"
            case .vectorUnavailable: return "本地语义索引失败，可重试"
            }
        }
    }
    private var models: [String: NLEmbedding] = [:]

    func embed(_ text: String, languageCode: String? = nil) throws -> KnowledgeVector {
        try Task.checkCancellation()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyText }
        guard text.count <= 1024 else { throw Failure.inputTooLong }
        let language: NLLanguage
        if let languageCode { language = NLLanguage(rawValue: languageCode) }
        else {
            guard let detected = NLLanguageRecognizer.dominantLanguage(for: text), detected != .undetermined else { throw Failure.unsupportedLanguage }
            language = detected
        }
        // macOS can identify short simplified text as zh-Hant even when only the
        // zh-Hans sentence model is installed. Resolve only within Chinese scripts,
        // and persist the actual model language so incomparable spaces never mix.
        let chinese = language == .simplifiedChinese || language == .traditionalChinese
        let alternatives: [NLLanguage] = chinese
            ? [language, language == .simplifiedChinese ? .traditionalChinese : .simplifiedChinese]
            : [language]
        var resolved: (NLLanguage, NLEmbedding)?
        for candidate in alternatives {
            if let cached = models[candidate.rawValue] { resolved = (candidate, cached); break }
            if let installed = NLEmbedding.sentenceEmbedding(for: candidate) {
                if models.count >= 4 { models.removeAll(keepingCapacity: true) }
                models[candidate.rawValue] = installed
                resolved = (candidate, installed); break
            }
        }
        guard let (resolvedLanguage, model) = resolved else { throw Failure.modelUnavailable(language.rawValue) }
        let actualLanguage = model.language ?? resolvedLanguage
        guard let values = model.vector(for: text) else { throw Failure.vectorUnavailable }
        try Task.checkCancellation()
        return try KnowledgeVector(namespace: .init(provider: "apple-natural-language", model: "sentence-embedding", revision: model.revision, dimension: model.dimension, language: actualLanguage.rawValue), values: values)
    }

    /// A category name and description are always included; only manually assigned examples
    /// should be supplied, never previous automatic assignments.
    func profile(id: UUID, revision: String, label: String, description: String, manualExamples: [String], languageCode: String? = nil) throws -> KnowledgeCategoryProfile {
        let name = [label, description].filter { !$0.isEmpty }.joined(separator: "\n")
        var vectors = [try embed(String(name.prefix(1024)), languageCode: languageCode)]
        // Profile sampling is a disclosed computation budget, not history deletion.
        let sampled = manualExamples.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(12)
        for example in sampled {
            try Task.checkCancellation()
            vectors.append(try embed(String(example.prefix(1024)), languageCode: languageCode))
        }
        return .init(id: id, revision: revision, label: label, vectors: vectors, manualExampleCount: sampled.count)
    }
}
