import Foundation
import CryptoKit
import PasteCore

actor LocalKnowledgeCoordinator {
    struct Outcome: Sendable {
        let itemID: UUID
        let categoryID: UUID?
        let candidates: [UUID]
        let categoryRevision: String?
        let job: KnowledgeIndexJob
    }
    private let repository: SnapshotRepository
    private let index: KnowledgeIndexRepository
    private let embedding = LocalKnowledgeEmbeddingProvider()
    private let onOutcome: @Sendable (Outcome) async -> Void
    private let onStatus: @Sendable (String?) async -> Void
    private var worker: Task<Void, Never>?
    private var profiles: [String: KnowledgeCategoryProfile] = [:]
    private var enabled = true
    private var drainRequested = false
    private var workerGeneration = UUID()

    init(directory: URL, onOutcome: @escaping @Sendable (Outcome) async -> Void,
         onStatus: @escaping @Sendable (String?) async -> Void) {
        repository = SnapshotRepository(directory: directory)
        index = KnowledgeIndexRepository(directory: directory)
        self.onOutcome = onOutcome; self.onStatus = onStatus
    }
    func start(classify: Bool) {
        enabled = classify
        drainRequested = true
        guard worker == nil else { return }
        let generation = UUID(); workerGeneration = generation
        worker = Task { await drain(generation: generation) }
    }
    func stop() { workerGeneration = UUID(); drainRequested = false; worker?.cancel(); worker = nil }
    func setClassification(_ value: Bool) { enabled = value; profiles.removeAll() }
    func refreshProfiles() { profiles.removeAll() }
    func retry() throws { try index.retryFailures(); start(classify: enabled) }
    func search(_ query: String, filter: ClipFilter, board: UUID?) async throws -> [KnowledgeSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let chunks = KnowledgeTextChunks.split(query)
        var merged: [UUID: KnowledgeSearchHit] = [:]
        for chunk in chunks {
            let vector = try await embedding.embed(chunk.text)
            for hit in try index.search(vector: vector, filter: filter, pinboardID: board, limit: 100) {
                if (merged[hit.itemID]?.score ?? -2) < hit.score { merged[hit.itemID] = hit }
            }
        }
        return merged.values.sorted { $0.score > $1.score }
    }
    private func drain(generation: UUID) async {
        drainRequested = false
        defer {
            if workerGeneration == generation {
                worker = nil
                if drainRequested && !Task.isCancelled { start(classify: enabled) }
            }
        }
        do {
            try index.resume()
            var processed = 0
            while !Task.isCancelled, let job = try index.nextJob() {
                do {
                    if ProcessInfo.processInfo.isLowPowerModeEnabled { try await Task.sleep(nanoseconds: 150_000_000) }
                    guard let item = try repository.loadItems(ids: [job.itemID], includePayload: false).first else { continue }
                    let text = Self.documentText(item)
                    var chunks: [KnowledgeIndexedChunk] = []
                    for chunk in KnowledgeTextChunks.split(text) where !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try Task.checkCancellation()
                        let vector = try await embedding.embed(chunk.text)
                        chunks.append(.init(ordinal: chunk.ordinal, text: chunk.text, vector: vector))
                        await Task.yield()
                    }
                    try Task.checkCancellation()
                    guard workerGeneration == generation, try index.complete(job, chunks: chunks) else { continue }
                    if enabled, job.eligibleForClassification, let vector = chunks.first?.vector {
                        do { try await classify(item, text: text, vector: vector, job: job) }
                        catch { await onStatus("自动分类暂不可用，可重试") }
                    }
                    processed += 1
                    if processed % 10 == 0 {
                        let counts = try index.counts()
                        await onStatus(counts.pending > 0 ? "正在整理 \(counts.pending) 项内容" : nil)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { try index.fail(job, message: error.localizedDescription) }
            }
            let counts = try index.counts()
            await onStatus(counts.failed > 0 ? "\(counts.failed) 项内容待重试" : nil)
        } catch is CancellationError { }
        catch { await onStatus("本地索引暂不可用，可重试") }
    }
    nonisolated static func documentText(_ item: ClipItem) -> String {
        var seen = Set<String>()
        return [item.title,item.text,item.enrichment?.ocr?.text ?? "",item.enrichment?.translation?.sourceText ?? "",item.enrichment?.translation?.translatedText ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    }
    nonisolated static func revision(_ board: Pinboard) -> String {
        let text = board.id.uuidString + board.name + (board.classificationDescription ?? "") + (board.classificationKeywords ?? []).joined(separator: ",") + board.itemIDs.map(\.uuidString).joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x",$0) }.joined()
    }
    private func classify(_ item: ClipItem, text: String, vector: KnowledgeVector, job: KnowledgeIndexJob) async throws {
        let metadata = try repository.loadMetadata()
        let assignments = try index.assignments(itemID: item.id)
        let manual = Set(metadata.pinboards.filter { $0.itemIDs.contains(item.id) && !assignments.automatic.contains($0.id) }.map(\.id))
        guard manual.isEmpty else { return }
        let boards = metadata.pinboards.filter { $0.automaticClassification != false && !assignments.excluded.contains($0.id) }
        var candidates: [KnowledgeCategoryProfile] = []
        for board in boards {
            try Task.checkCancellation()
            let revision = Self.revision(board)
            let key = revision + ":" + vector.namespace.language
            if let cached = profiles[key] { candidates.append(cached); continue }
            let sampleRows = try repository.loadItems(ids: Array(board.itemIDs.prefix(24)), includePayload: false)
            var samples: [String] = []
            for sample in sampleRows {
                let membership = try index.assignments(itemID: sample.id)
                if !membership.automatic.contains(board.id) { samples.append(String(Self.documentText(sample).prefix(1024))) }
                if samples.count == 12 { break }
            }
            do {
                let profile = try await embedding.profile(id: board.id, revision: revision, label: board.name,
                    description: board.classificationDescription ?? "", manualExamples: samples, languageCode: vector.namespace.language)
                if profiles.count >= 4096 { profiles.removeAll(keepingCapacity: true) }
                profiles[key] = profile; candidates.append(profile)
            } catch { continue }
        }
        let rules = boards.filter { !($0.classificationKeywords ?? []).isEmpty }.map { KnowledgeCategoryRule(categoryID: $0.id, profileRevision: Self.revision($0), requiredPhrases: $0.classificationKeywords ?? []) }
        let rule = KnowledgeLocalRules.classify(text: text, profiles: candidates, rules: rules, manualCategoryIDs: manual, excludedCategoryIDs: assignments.excluded)
        let result = KnowledgeClassifier.classify(vector: vector, profiles: candidates, manualCategoryIDs: manual, excludedCategoryIDs: assignments.excluded)
        let category = rule ?? result.automaticCategoryID
        await onOutcome(.init(itemID: item.id, categoryID: category, candidates: result.candidates.map(\.categoryID),
                              categoryRevision: category.flatMap { id in candidates.first { $0.id == id }?.revision }, job: job))
    }
}
