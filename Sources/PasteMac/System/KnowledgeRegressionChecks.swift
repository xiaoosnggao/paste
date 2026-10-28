#if DEBUG
import AppKit
import PasteCore

/// Real paged AppModel/storage boundaries, with isolated databases and a private pasteboard.
/// No monitoring, native paste dispatch, embedding, cloud calls, or personal history is accessed.
@MainActor
enum KnowledgeRegressionChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Knowledge regression: " + message) }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-regression-\(UUID())")
        let suite = "knowledge-regression-\(UUID())", board = NSPasteboard.withUniqueName()
        let defaults = UserDefaults(suiteName: suite)!
        var models: [AppModel] = []
        defer {
            for model in models {
                model.corruptStore = true
                model.historyQueryTask?.cancel()
                model.suggestionSessionActive = false
                model.flushPersistence()
            }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func make(_ items: [ClipItem], pinboards: [Pinboard] = [], incremental: Bool = false) throws -> AppModel {
            let directory = root.appendingPathComponent(UUID().uuidString)
            let repository = SnapshotRepository(directory: directory)
            if incremental {
                try repository.save(.init(pinboards: pinboards))
                try repository.applyChanges(metadata: repository.loadMetadata(), upserting: items, deleting: [])
            } else { try repository.save(.init(items: items, pinboards: pinboards)) }
            let model = AppModel(storageDirectory: directory, bridge: ClipboardBridge(pasteboard: board), toolDefaults: defaults,
                                 pasteEngine: PasteEngine(trackApplications: false))
            model.undoManager.groupsByEvent = false
            models.append(model)
            return model
        }
        func transaction(_ model: AppModel, _ operation: () -> Void) {
            model.undoManager.beginUndoGrouping()
            operation()
            model.undoManager.endUndoGrouping()
        }
        func settled(_ model: AppModel) async throws {
            model.flushPersistence()
            // Drain the main-queue acknowledgement before waiting for its scheduled query.
            try await Task.sleep(nanoseconds: 5_000_000)
            await model.historyQueryTask?.value
            model.flushPersistence()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let rich = ClipItem(title: "富文本原件", text: "原始正文", kind: .text,
                            sourceBundleID: "fixture.rich", sourceName: "Synthetic",
                            representations: [
                                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("原始正文".utf8)),
                                .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1\\ansi\\b Original formatted text}".utf8))
                            ])
        let filler = (0..<60).map { ClipItem(text: "page-fixture-\($0)", kind: .text) }

        // A metadata projection cannot be used as the durable inverse of a deletion.
        let deletion = try make([rich] + filler)
        let projected = try require(deletion.snapshot.items.first { $0.id == rich.id }, "rich fixture missing from first page")
        try check(projected.representations.isEmpty, "fixture bypassed the metadata-only paging path")
        deletion.select(projected)
        transaction(deletion) { deletion.deleteSelected() }
        try await settled(deletion)
        try check(try deletion.repository.loadItems(ids: [rich.id]).isEmpty, "deletion did not reach storage")
        deletion.undo()
        try await settled(deletion)
        let restored = try require(try deletion.repository.loadItems(ids: [rich.id]).first, "undo did not restore deleted rich text")
        try check(restored.representations == rich.representations && restored.text == rich.text,
                  "delete/undo replaced full rich-text payload with an empty projection")
        try check(try deletion.repository.itemCount() == filler.count + 1, "undo changed unrelated rows")

        // An edit must remain undoable even when its card has left the current page.
        let editing = try make([rich] + filler)
        var changed = rich; changed.title = "编辑后的标题"; changed.text = "编辑后的正文"
        transaction(editing) {
            _ = editing.commit(SnapshotOperations.replaceItem(changed, in: editing.snapshot), action: "fixture rich edit")
        }
        try await settled(editing)
        try check(try editing.repository.loadItems(ids: [rich.id]).first?.text == changed.text, "edit fixture was not persisted")
        editing.selectedIDs = []
        let lastPage = try editing.repository.loadItems(limit: 10, offset: 50, includePayload: false)
        editing.installHistoryPage(lastPage, offset: 50, total: filler.count + 1)
        try check(!editing.snapshot.items.contains { $0.id == rich.id }, "fixture did not evict the edited row")
        editing.undo()
        try await settled(editing)
        let undone = try require(try editing.repository.loadItems(ids: [rich.id]).first, "cross-page undo lost its item")
        try check(undone.text == rich.text && undone.title == rich.title, "undo ignored an edited row evicted by pagination")
        try check(undone.representations == rich.representations, "cross-page edit undo erased the original formats")

        // A query that read old content cannot overwrite a newer unsaved item on the main actor.
        let dirty = try make([rich] + filler)
        let stalePage = try dirty.repository.loadItems(limit: 50, includePayload: false)
        var latest = rich; latest.text = "尚未提交的最新编辑"
        dirty.snapshot.items = dirty.snapshot.items.map { $0.id == rich.id ? latest : $0 }
        try check(dirty.dirtyHistoryItems[rich.id]?.text == latest.text, "fixture edit failed to enter the dirty overlay")
        dirty.installHistoryPage(stalePage, offset: 0, total: filler.count + 1)
        try check(dirty.snapshot.items.first { $0.id == rich.id } == latest, "old query page replaced the dirty content or formats")
        try check(dirty.dirtyHistoryItems[rich.id] == latest, "page installation cleared unsaved changes")
        dirty.persist()
        try await settled(dirty)
        try check(try dirty.repository.loadItems(ids: [rich.id]).first == latest, "dirty overlay failed to save after page replacement")

        // An outcome can arrive after the new content has saved and cleared the dirty dictionary.
        let source = ClipItem(text: "旧版本数据库报价", kind: .text), category = Pinboard(name: "数据库报价")
        let classification = try make([source], pinboards: [category], incremental: true)
        let index = KnowledgeIndexRepository(directory: classification.storageDirectory)
        let oldJob = try require(try index.nextJob(), "classification fixture has no original job")
        try check(try index.complete(oldJob, chunks: []), "classification fixture could not mark original job ready")
        var newSource = source; newSource.text = "新版本晚餐菜单"
        transaction(classification) {
            _ = classification.commit(SnapshotOperations.replaceItem(newSource, in: classification.snapshot), action: "fixture newer content")
        }
        try await settled(classification)
        try check(classification.dirtyHistoryItems[source.id] == nil, "fixture did not pass the dirty-acknowledgement boundary")
        let revision = LocalKnowledgeCoordinator.revision(category)
        transaction(classification) {
            classification.receiveLocalClassification(.init(itemID: source.id, categoryID: category.id,
                candidates: [category.id], categoryRevision: revision, job: oldJob))
        }
        try check(classification.snapshot.pinboards.first?.itemIDs.isEmpty == true, "stale classification changed the new record's category")
        try check(classification.suggestedCategories[source.id] == nil, "stale classification published old candidates")
        let currentJob = try require(try index.nextJob(), "new content has no indexing job")
        try check(try index.complete(currentJob, chunks: []), "new job could not become ready")
        transaction(classification) {
            classification.receiveLocalClassification(.init(itemID: source.id, categoryID: category.id,
                candidates: [category.id], categoryRevision: revision, job: currentJob))
        }
        try check(classification.snapshot.pinboards.first?.itemIDs == [source.id], "current job was rejected together with stale jobs")
        try await settled(classification)

        let image = ClipItem(title: "原图", text: "", kind: .image, representations: [.init(type: "public.png", data: Data([1,2,3,4]))])
        let preview = try make([image])
        preview.retainHistory([image.id], for: "preview")
        preview.selectedIDs = []
        preview.releaseDisplayPayload(image.id)
        try check(preview.snapshot.items.first?.representations == image.representations, "scrolling released the active preview image")
        preview.releaseHistory(for: "preview")
        preview.toolItemID = image.id
        preview.releaseDisplayPayload(image.id)
        try check(preview.snapshot.items.first?.representations == image.representations, "scrolling released the active tool image")

        // Migration is index-only; only subsequent new captures are eligible for automatic assignment.
        let legacyDirectory = root.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = ClipItem(text: "已有历史：尚未归类", kind: .text)
        try JSONEncoder().encode(ClipboardSnapshot(items: [legacy])).write(to: legacyDirectory.appendingPathComponent("clipboard.json"))
        let migrated = SnapshotRepository(directory: legacyDirectory)
        _ = try migrated.loadMetadata()
        let migratedIndex = KnowledgeIndexRepository(directory: legacyDirectory)
        let migratedJob = try require(try migratedIndex.nextJob(), "migration failed to enqueue indexing")
        try check(!migratedJob.eligibleForClassification, "migration silently opted old history into automatic classification")
        _ = try migratedIndex.complete(migratedJob, chunks: [])
        let captured = ClipItem(text: "新捕获：可以自动归类", kind: .text)
        try migrated.applyChanges(metadata: migrated.loadMetadata(), upserting: [captured], deleting: [])
        let captureJob = try require(try migratedIndex.nextJob(), "new capture did not enqueue indexing")
        try check(captureJob.itemID == captured.id && captureJob.eligibleForClassification, "new capture was incorrectly restricted to index-only processing")
        // Management previews must resolve the same application aliases as visible search.
        let larkItem = ClipItem(text: "报价 alias fixture", kind: .text, sourceBundleID: "com.bytedance.lark", sourceName: "Lark")
        let management = try make([larkItem])
        management.queryString = "删除从飞书复制的报价"
        try await settled(management)
        let visibleIDs = Set(management.visibleItems.map(\.id))
        await management.prepareHistoryManagementPreview()
        try check(visibleIDs == [larkItem.id], "source alias search fixture did not resolve Lark")
        try check(management.historyManagementPreview?.itemIDs == visibleIDs, "management source alias differs from visible search")
        // An unrelated nearest neighbor must never widen a bulk deletion's explicit scope.
        let scopeQuery = "The project invoice is due tomorrow and the payment requires approval."
        let invoice = ClipItem(text: scopeQuery, kind: .text)
        let unrelated = ClipItem(text: "garden plants", kind: .text)
        let scoped = try make([invoice, unrelated])
        let scopeDirectory = scoped.repository.databaseURL.deletingLastPathComponent()
        let scopeIndex = KnowledgeIndexRepository(directory: scopeDirectory)
        let vector: KnowledgeVector
        do {
            vector = try await LocalKnowledgeEmbeddingProvider().embed(scopeQuery, languageCode: "en")
        } catch LocalKnowledgeEmbeddingProvider.Failure.modelUnavailable {
            print("SKIP: semantic deletion scope check (local sentence-embedding model unavailable)")
            return count
        }
        while let job = try scopeIndex.nextJob() {
            _ = try scopeIndex.complete(job, chunks: [.init(ordinal: 0, text: "fixture", vector: vector)])
        }
        let coordinator = LocalKnowledgeCoordinator(directory: scopeDirectory, onOutcome: { _ in }, onStatus: { _ in })
        scoped.knowledgeCoordinator = coordinator
        let neighbors = try await coordinator.search(scopeQuery, filter: .init(), board: nil)
        try check(neighbors.contains { $0.itemID == unrelated.id }, "semantic scope fixture lacks unrelated neighbor")
        scoped.queryString = "删除" + scopeQuery
        try await settled(scoped)
        await scoped.prepareHistoryManagementPreview()
        try check(scoped.historyManagementPreview?.itemIDs == [invoice.id], "bulk deletion widened to unrelated semantic neighbors")
        try check(try scoped.repository.itemCount() == 2, "preparing a management preview mutated history")
        return count
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SystemChecks.Failure(message: "Knowledge regression: " + message) }
        return value
    }
}
#endif
