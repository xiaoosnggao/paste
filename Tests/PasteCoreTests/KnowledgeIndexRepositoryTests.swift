import XCTest
@testable import PasteCore

final class KnowledgeIndexRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-index-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func namespace(language: String = "zh", revision: Int = 1, model: String = "fixture") -> KnowledgeNamespace {
        .init(provider: "fixture-local", model: model, revision: revision, dimension: 3, language: language)
    }
    private func vector(_ values: [Double] = [1, 0, 0], language: String = "zh", revision: Int = 1, model: String = "fixture") throws -> KnowledgeVector {
        try .init(namespace: namespace(language: language, revision: revision, model: model), values: values)
    }
    private func chunk(_ text: String, ordinal: Int = 0, values: [Double] = [1, 0, 0], language: String = "zh", revision: Int = 1, model: String = "fixture") throws -> KnowledgeIndexedChunk {
        .init(ordinal: ordinal, text: text, vector: try vector(values, language: language, revision: revision, model: model))
    }

    func testCommittedCaptureCreatesPendingJobAndClaimIsExclusiveAndResumable() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let item = ClipItem(text: "事务中的中文记录", kind: .text)
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        XCTAssertEqual(try index.counts().pending, 1)
        let job = try XCTUnwrap(index.nextJob())
        XCTAssertEqual(job.itemID, item.id)
        XCTAssertNil(try KnowledgeIndexRepository(directory: folder).nextJob(), "A processing job must not be claimed twice")
        try index.resume()
        let resumed = try XCTUnwrap(index.nextJob())
        XCTAssertEqual(resumed.itemID, job.itemID)
        XCTAssertEqual(resumed.fingerprint, job.fingerprint)
        XCTAssertTrue(try index.complete(resumed, chunks: [chunk(item.text)]))
        XCTAssertEqual(try index.counts().ready, 1)
        XCTAssertNil(try index.nextJob())
        var invalidMetadata = try store.loadMetadata()
        invalidMetadata.pinboards = [.init(name: "invalid reference", itemIDs: [UUID()])]
        XCTAssertThrowsError(try store.applyChanges(metadata: invalidMetadata, upserting: [.init(text: "rolled back", kind: .text)], deleting: []))
        XCTAssertEqual(try index.counts().ready, 1)
        XCTAssertEqual(try index.counts().pending, 0, "An aborted capture must not leave an indexing job")
    }

    func testEditImmediatelyHidesOldVectorsAndRejectsEarlierTextJob() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        var item = ClipItem(text: "旧报价10元", kind: .text)
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        let old = try XCTUnwrap(index.nextJob())
        XCTAssertTrue(try index.complete(old, chunks: [chunk("旧报价10元")]))
        XCTAssertEqual(try index.search(vector: vector()).map(\.itemID), [item.id])
        item.text = "新报价12元"
        try store.applyChanges(metadata: store.loadMetadata(), upserting: [item], deleting: [])
        XCTAssertTrue(try index.search(vector: vector()).isEmpty, "Old ready vectors must disappear as soon as the content is edited")
        XCTAssertFalse(try index.complete(old, chunks: [chunk("stale worker must not publish")]))
        let latest = try XCTUnwrap(index.nextJob())
        XCTAssertNotEqual(latest.fingerprint, old.fingerprint)
        XCTAssertTrue(try index.complete(latest, chunks: [chunk(item.text)]))
        XCTAssertEqual(try index.search(vector: vector()).first?.snippet, "新报价12元")
    }

    func testOCRAndTranslationEditsRejectOldJobEvenWhenClipboardFingerprintIsUnchanged() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        var item = ClipItem(text: "原始截图", kind: .image, enrichment: .init(ocr: .init(text: "旧识别")))
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        let old = try XCTUnwrap(index.nextJob()), clipboardFingerprint = item.fingerprint
        item.enrichment = .init(ocr: .init(text: "新识别与尾部条件"))
        XCTAssertEqual(item.fingerprint, clipboardFingerprint)
        try store.applyChanges(metadata: store.loadMetadata(), upserting: [item], deleting: [])
        XCTAssertFalse(try index.complete(old, chunks: [chunk("旧识别")]), "Clipboard dedup identity is insufficient to version OCR/index jobs")
        let newOCR = try XCTUnwrap(index.nextJob())
        XCTAssertTrue(try index.complete(newOCR, chunks: [chunk("新识别与尾部条件")]))
        item.enrichment?.translation = .init(sourceText: "新识别与尾部条件", translatedText: "Updated translation", sourceLanguage: "zh", targetLanguage: "en", model: "fixture")
        try store.applyChanges(metadata: store.loadMetadata(), upserting: [item], deleting: [])
        XCTAssertFalse(try index.complete(newOCR, chunks: [chunk("没有译文的旧任务")]), "Translation completion must invalidate a prior indexing job")
        let translated = try XCTUnwrap(index.nextJob())
        XCTAssertTrue(try index.complete(translated, chunks: [chunk("Updated translation")]))
        item.title = "更新的标题"
        try store.applyChanges(metadata: store.loadMetadata(), upserting: [item], deleting: [])
        XCTAssertTrue(try index.search(vector: vector()).isEmpty)
        XCTAssertFalse(try index.complete(translated, chunks: [chunk("旧标题")]), "Searchable title changes must invalidate a prior indexing job")
    }

    func testFailedJobsRetryAndDeletedJobsCannotResurrectVectorsOrAssignments() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let item = ClipItem(text: "删除测试", kind: .text), category = UUID()
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        let first = try XCTUnwrap(index.nextJob())
        try index.fail(first, message: "fixture failure")
        XCTAssertEqual(try index.counts().failed, 1)
        XCTAssertNil(try index.nextJob())
        try index.retryFailures()
        let retried = try XCTUnwrap(index.nextJob())
        XCTAssertTrue(try index.complete(retried, chunks: [chunk("删除测试")]))
        try index.recordAssignment(itemID: item.id, categoryID: category, automatic: true, revision: "fixture-1")
        try index.exclude(itemID: item.id, categoryID: UUID())
        try store.applyChanges(metadata: store.loadMetadata(), upserting: [], deleting: [item.id])
        XCTAssertTrue(try index.search(vector: vector()).isEmpty)
        XCTAssertFalse(try index.complete(retried, chunks: [chunk("cannot resurrect")]))
        XCTAssertEqual(try index.counts().ready, 0)
        let state = try index.assignments(itemID: item.id)
        XCTAssertTrue(state.automatic.isEmpty && state.excluded.isEmpty)
        let database = try SQLiteDatabase(url: store.databaseURL)
        for table in ["knowledge_vectors", "knowledge_jobs", "knowledge_memberships", "knowledge_exclusions"] {
            var count = -1
            try database.rows("SELECT COUNT(*) FROM \(table)") { count = Int(SQLiteDatabase.text($0, 0)) ?? -1 }
            XCTAssertEqual(count, 0, "Deletion failed to cascade through \(table)")
        }
    }

    func testDuplicateChunkOrdinalRollsBackWholeCompletion() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let item = ClipItem(text: "原子向量写入", kind: .text)
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        let job = try XCTUnwrap(index.nextJob())
        XCTAssertThrowsError(try index.complete(job, chunks: [chunk("first", ordinal: 0), chunk("duplicate", ordinal: 0)]))
        XCTAssertTrue(try index.search(vector: vector()).isEmpty)
        XCTAssertEqual(try index.counts().ready, 0)
        let database = try SQLiteDatabase(url: store.databaseURL)
        var rows = -1
        try database.rows("SELECT COUNT(*) FROM knowledge_vectors") { rows = Int(SQLiteDatabase.text($0, 0)) ?? -1 }
        XCTAssertEqual(rows, 0, "A failed completion must not expose or retain partial vectors")
        XCTAssertTrue(try index.complete(job, chunks: [chunk("retry succeeded")]))
        XCTAssertEqual(try index.search(vector: vector()).first?.snippet, "retry succeeded")
    }

    func testRawFloatNeighborsAreRankedPerItemAndNeverCrossNamespaces() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let exact = ClipItem(text: "中文精确邻居", kind: .text), similar = ClipItem(text: "中文相近邻居", kind: .text)
        let opposite = ClipItem(text: "相反向量", kind: .text), english = ClipItem(text: "English exact vector", kind: .text)
        let revision = ClipItem(text: "different revision", kind: .text), model = ClipItem(text: "different model", kind: .text)
        try store.save(.init(items: [exact, similar, opposite, english, revision, model]))
        let index = KnowledgeIndexRepository(directory: folder)
        while let job = try index.nextJob() {
            let chunks: [KnowledgeIndexedChunk]
            switch job.itemID {
            case exact.id: chunks = [try chunk("lower scoring chunk", values: [0.5, 0.5, 0]), try chunk("best source snippet", ordinal: 1)]
            case similar.id: chunks = [try chunk("similar", values: [0.95, 0.10, 0])]
            case opposite.id: chunks = [try chunk("opposite", values: [-1, 0, 0])]
            case english.id: chunks = [try chunk("English", language: "en")]
            case revision.id: chunks = [try chunk("revision", revision: 2)]
            default: chunks = [try chunk("model", model: "other")]
            }
            XCTAssertTrue(try index.complete(job, chunks: chunks))
        }
        let hits = try index.search(vector: vector())
        XCTAssertEqual(hits.map(\.itemID), [exact.id, similar.id, opposite.id])
        XCTAssertEqual(hits[0].snippet, "best source snippet")
        XCTAssertEqual(hits[0].score, 1, accuracy: 0.00001)
        XCTAssertEqual(hits[1].score, 0.95 / sqrt(0.95 * 0.95 + 0.1 * 0.1), accuracy: 0.00001)
        XCTAssertEqual(hits[2].score, -1, accuracy: 0.00001)
        XCTAssertEqual(try index.search(vector: vector(language: "en")).map(\.itemID), [english.id])
        XCTAssertEqual(try index.search(vector: vector(revision: 2)).map(\.itemID), [revision.id])
        XCTAssertEqual(try index.search(vector: vector(model: "other")).map(\.itemID), [model.id])
        XCTAssertEqual(try index.search(vector: vector(), limit: 1).map(\.itemID), [exact.id])
    }

    func testSearchBindsLiteralApplicationFiltersAndCollectionMembership() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let wanted = ClipItem(text: "目标应用内容", kind: .text, sourceBundleID: "fixture.app", sourceName: "企业_%团队")
        let other = ClipItem(text: "另一个应用", kind: .text, sourceBundleID: "fixture.other", sourceName: "企业AB团队")
        let category = Pinboard(name: "仅目标", itemIDs: [wanted.id])
        try store.save(.init(items: [wanted, other], pinboards: [category]))
        let index = KnowledgeIndexRepository(directory: folder)
        while let job = try index.nextJob() {
            XCTAssertTrue(try index.complete(job, chunks: [chunk("fixture snippet")]))
        }
        XCTAssertEqual(try index.search(vector: vector(), filter: .init(sourceBundleID: "fixture.app")).map(\.itemID), [wanted.id])
        XCTAssertEqual(try index.search(vector: vector(), filter: .init(sourceName: "_%")).map(\.itemID), [wanted.id], "LIKE metacharacters must remain literal user text")
        XCTAssertTrue(try index.search(vector: vector(), filter: .init(sourceBundleID: "x' OR 1=1 --")).isEmpty)
        XCTAssertEqual(try index.search(vector: vector(), pinboardID: category.id).map(\.itemID), [wanted.id])
        XCTAssertTrue(try index.search(vector: vector(), pinboardID: UUID()).isEmpty)
    }

    func testExclusionAndManualCorrectionPersistAcrossRepositoryRestart() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let item = ClipItem(text: "手动纠正的分类", kind: .text), category = UUID()
        try store.save(.init(items: [item]))
        let index = KnowledgeIndexRepository(directory: folder)
        try index.recordAssignment(itemID: item.id, categoryID: category, automatic: true, revision: "v1")
        XCTAssertEqual(try index.assignments(itemID: item.id).automatic, [category])
        try index.exclude(itemID: item.id, categoryID: category)
        let restarted = KnowledgeIndexRepository(directory: folder)
        XCTAssertEqual(try restarted.assignments(itemID: item.id).excluded, [category])
        XCTAssertTrue(try restarted.assignments(itemID: item.id).automatic.isEmpty)
        try restarted.recordAssignment(itemID: item.id, categoryID: category, automatic: false, revision: "manual")
        let afterManual = KnowledgeIndexRepository(directory: folder)
        XCTAssertTrue(try afterManual.assignments(itemID: item.id).excluded.isEmpty)
        XCTAssertTrue(try afterManual.assignments(itemID: item.id).automatic.isEmpty)
        let database = try SQLiteDatabase(url: store.databaseURL)
        var origin = "", revision = ""
        try database.rows("SELECT origin,revision FROM knowledge_memberships WHERE item_id=? AND category_id=?", [.text(item.id.uuidString), .text(category.uuidString)]) {
            origin = SQLiteDatabase.text($0, 0); revision = SQLiteDatabase.text($0, 1)
        }
        XCTAssertEqual(origin, "manual")
        XCTAssertEqual(revision, "manual")
    }

    func testSourceAliasesMatchTheSnapshotSearchFilters() throws {
        let folder = try directory(), store = SnapshotRepository(directory: folder)
        let weChat = ClipItem(text: "English WeChat source", kind: .text, sourceBundleID: "com.tencent.xinWeChat", sourceName: "WeChat")
        let localizedWeChat = ClipItem(text: "中文微信来源", kind: .text, sourceBundleID: "fixture.localized-chat", sourceName: "微信")
        let lark = ClipItem(text: "Lark source", kind: .text, sourceBundleID: "com.bytedance.Lark", sourceName: "Lark")
        let localizedLark = ClipItem(text: "中文飞书来源", kind: .text, sourceBundleID: "fixture.localized-lark", sourceName: "飞书")
        let code = ClipItem(text: "Code source", kind: .text, sourceBundleID: "com.microsoft.VSCode", sourceName: "Code")
        let localizedCode = ClipItem(text: "VS Code source", kind: .text, sourceBundleID: "fixture.editor", sourceName: "VS Code")
        let other = ClipItem(text: "Unrelated source", kind: .text, sourceBundleID: "fixture.other", sourceName: "Other")
        try store.save(.init(items: [weChat, localizedWeChat, lark, localizedLark, code, localizedCode, other]))
        let index = KnowledgeIndexRepository(directory: folder)
        while let job = try index.nextJob() {
            XCTAssertTrue(try index.complete(job, chunks: [chunk("fixture source alias")]))
        }
        for (source, expected) in [("微信", [weChat.id, localizedWeChat.id]), ("飞书", [lark.id, localizedLark.id]), ("VS Code", [code.id, localizedCode.id])] {
            let filter = ClipFilter(sourceName: source)
            let hits = Set(try index.search(vector: vector(), filter: filter).map(\.itemID))
            XCTAssertEqual(hits, Set(expected), source)
            XCTAssertEqual(hits, Set(try store.loadItems(limit: 100, filter: filter).map(\.id)), source)
        }
        XCTAssertTrue(try index.search(vector: vector(), filter: .init(sourceName: "%' OR 1=1 --")).isEmpty)
    }
}
