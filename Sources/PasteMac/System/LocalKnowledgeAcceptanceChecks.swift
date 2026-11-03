#if DEBUG
import Foundation
import NaturalLanguage
import PasteCore

@MainActor
enum LocalKnowledgeAcceptanceChecks {
    @MainActor private final class Receipt {
        var outcomes: [LocalKnowledgeCoordinator.Outcome] = []
        var finishedDrains = 0
        func outcome(_ value: LocalKnowledgeCoordinator.Outcome) { outcomes.append(value) }
        func status(_ value: String?) { if value == nil { finishedDrains += 1 } }
    }
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Local knowledge acceptance: \(message)") }; count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-acceptance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = LocalKnowledgeEmbeddingProvider()
        let automaticallyDetected: KnowledgeVector
        do {
            automaticallyDetected = try await provider.embed("乘坐火车去海边旅行，提前预订酒店房间。")
        } catch LocalKnowledgeEmbeddingProvider.Failure.modelUnavailable {
            // Every acceptance step below indexes real local vectors; availability is a host property.
            print("SKIP: local knowledge acceptance checks (local sentence-embedding model unavailable)")
            return count
        }
        let explicitlyTraditional = try await provider.embed("資料庫遷移之前需要備份。", languageCode: "zh-Hant")
        try check(automaticallyDetected.namespace.language.hasPrefix("zh"), "short Chinese detection lost the available local model")
        if NLEmbedding.sentenceEmbedding(for: .traditionalChinese) == nil {
            try check(explicitlyTraditional.namespace.language == "zh-Hans", "Chinese fallback did not record its actual model namespace")
        } else {
            try check(explicitlyTraditional.namespace.language == "zh-Hant", "installed traditional model was not preserved")
        }
        let repository = SnapshotRepository(directory: directory)
        let index = KnowledgeIndexRepository(directory: directory)
        let receipt = Receipt()
        let coordinator = LocalKnowledgeCoordinator(directory: directory, onOutcome: { outcome in
            await receipt.outcome(outcome)
        }, onStatus: { status in await receipt.status(status) })
        defer { Task { await coordinator.stop() } }
        let englishDatabase = ClipItem(text: "Database migration requires a backup before changing the schema.", kind: .text, sourceName: "Fixture")
        let chineseDatabase = ClipItem(text: "数据库迁移之前需要备份，修改表结构前先保存数据。", kind: .text, sourceName: "Fixture")
        let oldItems = [englishDatabase, chineseDatabase,
            ClipItem(text: "Baking bread in the kitchen requires flour and yeast.", kind: .text, sourceName: "Fixture"),
            ClipItem(text: "厨房制作面包需要面粉和酵母，先揉面再烘焙。", kind: .text, sourceName: "Fixture"),
            ClipItem(text: "Travel by train to the seaside and reserve a hotel.", kind: .text, sourceName: "Fixture"),
            ClipItem(text: "乘坐火车去海边旅行，提前预订酒店房间。", kind: .text, sourceName: "Fixture")]
        var databaseBoard = Pinboard(name: "数据库")
        databaseBoard.classificationDescription = "数据库迁移、表结构与备份"
        databaseBoard.classificationKeywords = ["数据库", "备份"]
        var metadata = ClipboardSnapshot(items: oldItems, pinboards: [databaseBoard, Pinboard(name: "厨房烘焙")])
        try repository.save(metadata)
        await coordinator.start(classify: true)
        try await waitForDrain(receipt, index: index, count: 1)
        try check(try index.counts().ready == oldItems.count, "old history did not receive real local vectors")
        try check(receipt.outcomes.isEmpty, "indexing old history silently classified existing records")
        let exactEnglish = try await coordinator.search(englishDatabase.text, filter: .init(), board: nil)
        let exactChinese = try await coordinator.search(chineseDatabase.text, filter: .init(), board: nil)
        try check(exactEnglish.first?.itemID == englishDatabase.id, "English exact semantic query did not return its vector")
        try check(exactChinese.first?.itemID == chineseDatabase.id, "Chinese exact semantic query did not return its vector")
        try check(exactEnglish.count == 3 && exactChinese.count == 3, "different language model namespaces were compared")
        for (language, query, expected) in [("en", "Back up the database before changing its schema", englishDatabase.id), ("zh-Hans", "修改数据库结构前先保存备份", chineseDatabase.id)] {
            let hits = try await coordinator.search(query, filter: .init(), board: nil)
            let rank = hits.firstIndex(where: { $0.itemID == expected }).map { $0 + 1 }
            print("Local semantic fixture language=\(language) related_rank=\(rank.map(String.init) ?? "missing") candidates=\(hits.count) top_score=\(hits.first?.score ?? -1)")
            // This small offline smoke set is not a claim of calibrated semantic accuracy.
            try check(rank != nil, "related local vector was missing from its language index")
        }
        let newItem = ClipItem(text: "数据库索引验收：迁移前完成备份。", kind: .text, sourceName: "Fixture")
        try repository.applyChanges(metadata: metadata, upserting: [newItem], deleting: [])
        await coordinator.start(classify: true)
        try await waitForDrain(receipt, index: index, count: 2)
        try check(receipt.outcomes.contains { $0.itemID == newItem.id && $0.categoryID == databaseBoard.id }, "new Chinese content did not match a local category rule")
        try index.recordAssignment(itemID: newItem.id, categoryID: databaseBoard.id, automatic: true, revision: "fixture")
        try index.exclude(itemID: newItem.id, categoryID: databaseBoard.id)
        var updated = newItem
        updated.enrichment = .init(ocr: .init(text: "数据库备份已完成，等待验收。", provider: "Fixture"))
        try repository.applyChanges(metadata: metadata, upserting: [updated], deleting: [])
        await coordinator.start(classify: true)
        try await waitForDrain(receipt, index: index, count: 3)
        let updates = receipt.outcomes.filter { $0.itemID == newItem.id }
        try check(updates.count == 2 && updates.last?.categoryID != databaseBoard.id, "OCR reindex overrode a manual category exclusion")
        try check(try index.assignments(itemID: newItem.id).excluded.contains(databaseBoard.id), "manual exclusion was not durable")
        await coordinator.setClassification(false)
        let paused = ClipItem(text: "数据库备份暂停分类测试。", kind: .text, sourceName: "Fixture")
        try repository.applyChanges(metadata: metadata, upserting: [paused], deleting: [])
        await coordinator.start(classify: false)
        try await waitForDrain(receipt, index: index, count: 4)
        try check(!receipt.outcomes.contains { $0.itemID == paused.id }, "classification switch did not pause assignments")
        try check(try index.counts().ready == 8, "classification pause also stopped local vector indexing")
        for size in [101, 1000] {
            let profiles = (0..<size).map { KnowledgeCategoryProfile(id: UUID(), revision: "fixture", label: String(format: "项目资料-%04d", $0), vectors: [], manualExampleCount: 0) }
            let expected = profiles.last!
            let match = KnowledgeLocalRules.classify(text: "\(expected.label) 的会议记录", profiles: profiles)
            try check(match == expected.id, "specific category-name match failed among \(size) categories")
            try check(KnowledgeLocalRules.classify(text: "未指定项目的会议记录", profiles: profiles) == nil, "unrelated content was assigned among \(size) categories")
        }
        await coordinator.stop()
        metadata.items = [] // Keep test documents out of any accidental diagnostic dump.
        return count
    }
    private static func waitForDrain(_ receipt: Receipt, index: KnowledgeIndexRepository, count: Int) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let counts = try index.counts()
            if counts.failed > 0 { throw SystemChecks.Failure(message: "Local knowledge fixture failed on-device embedding") }
            if counts.pending == 0 && receipt.finishedDrains >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SystemChecks.Failure(message: "Local knowledge fixture timed out")
    }
}
#endif
