#if DEBUG
import Foundation
import PasteCore

@MainActor
enum LocalKnowledgeChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw CheckFailure(message: label) }; count += 1
        }
        let provider = LocalKnowledgeEmbeddingProvider()
        do { _ = try await provider.embed(" \n "); throw CheckFailure(message: "empty embedding accepted") }
        catch LocalKnowledgeEmbeddingProvider.Failure.emptyText { count += 1 }
        do { _ = try await provider.embed(String(repeating: "a", count: 1025)); throw CheckFailure(message: "oversized embedding accepted") }
        catch LocalKnowledgeEmbeddingProvider.Failure.inputTooLong { count += 1 }
        do { _ = try await provider.embed("sample", languageCode: "xx-invalid"); throw CheckFailure(message: "missing model silently replaced") }
        catch LocalKnowledgeEmbeddingProvider.Failure.modelUnavailable { count += 1 }
        for language in ["en", "zh-Hans"] {
            do {
                let vector = try await provider.embed(language == "en" ? "Database backup" : "数据库备份", languageCode: language)
                try check(vector.namespace.language == language && vector.namespace.provider == "apple-natural-language", "local language namespace")
                try check(vector.values.count == vector.namespace.dimension && vector.values.allSatisfy(\.isFinite), "finite system vector")
                try check(abs(vector.values.reduce(0) { $0 + $1 * $1 } - 1) < 0.00001, "unit norm")
            } catch LocalKnowledgeEmbeddingProvider.Failure.modelUnavailable {
                // Availability is a host property, not a reason to use a network fallback.
                count += 1
            }
        }
        return count
    }
    private struct CheckFailure: Error { let message: String }
}
#endif
