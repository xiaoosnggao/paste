import Foundation

public struct KnowledgeNamespace: Codable, Hashable, Sendable {
    public let provider: String
    public let model: String
    public let revision: Int
    public let dimension: Int
    public let language: String
    public init(provider: String, model: String, revision: Int, dimension: Int, language: String) {
        self.provider = provider; self.model = model; self.revision = revision
        self.dimension = dimension; self.language = language
    }
}

public enum KnowledgeVectorError: Error { case invalidVector }
public struct KnowledgeVector: Codable, Equatable, Sendable {
    public let namespace: KnowledgeNamespace
    public let values: [Double]
    public init(namespace: KnowledgeNamespace, values: [Double]) throws {
        guard namespace.dimension > 0, namespace.dimension <= 8192, namespace.revision >= 0, !namespace.provider.isEmpty, !namespace.model.isEmpty, !namespace.language.isEmpty, values.count == namespace.dimension, values.allSatisfy(\.isFinite) else { throw KnowledgeVectorError.invalidVector }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw KnowledgeVectorError.invalidVector }
        self.namespace = namespace; self.values = values.map { $0 / norm }
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(namespace: fields.decode(KnowledgeNamespace.self, forKey: .namespace), values: fields.decode([Double].self, forKey: .values))
    }
    public func similarity(to other: Self) -> Double? {
        guard namespace == other.namespace else { return nil }
        return min(1, max(-1, zip(values, other.values).reduce(0) { $0 + $1.0 * $1.1 }))
    }
}

public struct KnowledgeTextChunk: Equatable, Sendable {
    public let ordinal: Int
    public let text: String
}
public enum KnowledgeTextChunks {
    /// Every character is retained, including whitespace; callers persist each chunk separately.
    public static func split(_ text: String, maximumCharacters: Int = 512) -> [KnowledgeTextChunk] {
        let maximum = max(1, maximumCharacters)
        var chunks: [KnowledgeTextChunk] = [], start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximum, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(.init(ordinal: chunks.count, text: String(text[start..<end])))
            start = end
        }
        return chunks
    }
}

public struct KnowledgeCategoryProfile: Sendable {
    public let id: UUID
    public let revision: String
    public let label: String
    public let vectors: [KnowledgeVector]
    public let manualExampleCount: Int
    public init(id: UUID, revision: String, label: String, vectors: [KnowledgeVector], manualExampleCount: Int) {
        self.id = id; self.revision = revision; self.label = label; self.vectors = vectors; self.manualExampleCount = manualExampleCount
    }
}
public struct KnowledgeCategoryCandidate: Equatable, Sendable {
    public let categoryID: UUID
    public let profileRevision: String
    /// Cosine similarity, not a probability.
    public let score: Double
}
public struct KnowledgeClassification: Sendable {
    public let automaticCategoryID: UUID?
    public let candidates: [KnowledgeCategoryCandidate]
}
public enum KnowledgeClassifier {
    /// Thresholds are deliberately conservative. Manual removals and assignments always win.
    public static func classify(vector: KnowledgeVector, profiles: [KnowledgeCategoryProfile], manualCategoryIDs: Set<UUID> = [], excludedCategoryIDs: Set<UUID> = []) -> KnowledgeClassification {
        guard manualCategoryIDs.isEmpty else { return .init(automaticCategoryID: nil, candidates: []) }
        let ranked = profiles.filter { !excludedCategoryIDs.contains($0.id) }.compactMap { profile -> (KnowledgeCategoryCandidate, Int)? in
            let scores = profile.vectors.compactMap { vector.similarity(to: $0) }
            guard !scores.isEmpty else { return nil }
            // Average prevents one attractive example overwhelming a contradictory category profile.
            let score = scores.reduce(0, +) / Double(scores.count)
            return (.init(categoryID: profile.id, profileRevision: profile.revision, score: score), profile.manualExampleCount)
        }.sorted { $0.0.score == $1.0.score ? $0.0.categoryID.uuidString < $1.0.categoryID.uuidString : $0.0.score > $1.0.score }
        guard let best = ranked.first else { return .init(automaticCategoryID: nil, candidates: []) }
        let margin = best.0.score - (ranked.dropFirst().first?.0.score ?? 0)
        let threshold = best.1 > 0 ? 0.88 : 0.96
        // On-device Chinese sentence vectors are strongly anisotropic in our probe.
        // Ranking is useful, but automatic assignment needs a calibrated decision model.
        let calibrated = vector.namespace.provider != "apple-natural-language" || !vector.namespace.language.hasPrefix("zh")
        let automatic = calibrated && best.0.score >= threshold && margin >= 0.12 ? best.0.categoryID : nil
        return .init(automaticCategoryID: automatic, candidates: ranked.map(\.0).filter { $0.score >= 0.50 }.prefix(3).map { $0 })
    }
}

public struct KnowledgeCategoryRule: Sendable {
    public let categoryID: UUID
    public let profileRevision: String
    public let requiredPhrases: [String]
    public init(categoryID: UUID, profileRevision: String, requiredPhrases: [String]) {
        self.categoryID = categoryID; self.profileRevision = profileRevision; self.requiredPhrases = requiredPhrases
    }
}
public enum KnowledgeLocalRules {
    /// User-defined phrases are explicit deterministic rules. Conflicting matches abstain.
    /// Category-name matching is allowed only for specific names, never broad one-character labels.
    public static func classify(text: String, profiles: [KnowledgeCategoryProfile], rules: [KnowledgeCategoryRule] = [], manualCategoryIDs: Set<UUID> = [], excludedCategoryIDs: Set<UUID> = []) -> UUID? {
        guard manualCategoryIDs.isEmpty else { return nil }
        let allowed = profiles.filter { !excludedCategoryIDs.contains($0.id) }
        let ruleMatches = rules.filter { rule in
            allowed.contains { $0.id == rule.categoryID && $0.revision == rule.profileRevision } &&
            !rule.requiredPhrases.isEmpty && rule.requiredPhrases.allSatisfy { phraseMatches($0, text: text) }
        }.map(\.categoryID)
        if !ruleMatches.isEmpty { return Set(ruleMatches).count == 1 ? ruleMatches.first : nil }
        let labels = allowed.filter { profile in
            let label = profile.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasCJK = label.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
            let genericNames: Set<String> = ["工作", "学习", "生活", "其他", "收藏", "资料", "work", "other", "notes"]
            return !genericNames.contains(label.lowercased()) && label.count >= (hasCJK ? 2 : 4) && phraseMatches(label, text: text)
        }.map(\.id)
        return labels.count == 1 ? labels.first : nil
    }
    private static func phraseMatches(_ phrase: String, text: String) -> Bool {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return false }
        let hasCJK = phrase.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
        if hasCJK { return text.range(of: phrase, options: .caseInsensitive) != nil }
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}_])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
