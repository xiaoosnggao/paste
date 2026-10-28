import AppKit
import PasteCore

extension AppModel {
    func validateCurrentWindow(_ value: ClipboardSnapshot) throws {
        if isDemo { try repository.validate(value) }
        else { try repository.validatePartial(value) }
    }

    func trackStorageChanges(from old: ClipboardSnapshot) {
        guard !isDemo, !loadingHistoryWindow else { return }
        let prior = Dictionary(old.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(snapshot.items.map(\.id))
        for item in snapshot.items where prior[item.id] != item {
            dirtyHistoryItems[item.id] = item
            deletedHistoryIDs.remove(item.id)
        }
        for id in Set(prior.keys).subtracting(currentIDs) {
            dirtyHistoryItems.removeValue(forKey: id)
            deletedHistoryIDs.insert(id)
        }
        // Captured records appear immediately while the database commit runs in the background.
        let added = snapshot.items.filter { prior[$0.id] == nil }.map(\.id)
        historyResultIDs = added + historyResultIDs.filter { !added.contains($0) && currentIDs.contains($0) }
    }

    func scheduleHistoryQuery() {
        guard !isDemo, !corruptStore else { return }
        historyQueryTask?.cancel()
        let generation = UUID(); historyQueryGeneration = generation
        let query = queryString, board = selectedPinboardID, currentFilter = filter
        let repository = repository, persistence = persistence
        historyQueryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let page = try await Task.detached(priority: .userInitiated) {
                    persistence.flush()
                    let plan = KnowledgeQueryPlan.parse(query)
                    var effective = currentFilter
                    if let kind = plan.kind { effective.kind = ClipKind(rawValue: kind) }
                    if let source = plan.source { effective.sourceName = source }
                    if let interval = plan.timeRange { effective.since = interval.start; effective.until = interval.end }
                    let rows = try repository.loadItems(limit: 50, offset: 0, query: plan.query,
                                                        pinboardID: board, filter: effective, includePayload: false)
                    let sourceRows = rows
                    return (sourceRows, try repository.itemCount(), plan, effective)
                }.value
                try Task.checkCancellation()
                guard let self, self.historyQueryGeneration == generation else { return }
                self.installHistoryPage(page.0, offset: 0, total: page.1)
                self.historyHasMore = page.0.count == 50
                self.historyPageOffset = 0
                self.searchUnderstanding = SearchUnderstanding(plan: page.2, rawQuery: query)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await self.enrichHistorySearch(plan: page.2, filter: page.3, generation: generation)
                }
            } catch is CancellationError { }
            catch { self?.statusMessage = "搜索失败：\(error.localizedDescription)" }
        }
    }

    func installHistoryPage(_ items: [ClipItem], offset: Int, total: Int) {
        loadingHistoryWindow = true
        let keep = Set(stackItems.map(\.id)).union(dirtyHistoryItems.keys).union(activeHistoryReferences.values.flatMap { $0 }).union(toolItemID.map { [$0] } ?? [])
        let incomingIDs = Set(items.map(\.id))
        let retained = snapshot.items.filter { keep.contains($0.id) && !incomingIDs.contains($0.id) }
        var seen = Set<UUID>()
        var next = snapshot
        let incoming = items.map { item in dirtyHistoryItems[item.id] ?? snapshot.items.first(where: { $0.id == item.id && $0.fingerprint == item.fingerprint && !$0.representations.isEmpty }) ?? item }
        next.items = (incoming + retained + Array(dirtyHistoryItems.values)).filter { seen.insert($0.id).inserted && !deletedHistoryIDs.contains($0.id) }
        snapshot = next
        historyResultIDs = items.filter { !deletedHistoryIDs.contains($0.id) }.map(\.id)
        historyTotalCount = total
        historyPageOffset = offset
        loadingHistoryWindow = false
        selectFirstIfNeeded()
    }

    func loadNextHistoryPage(after id: UUID) {
        guard !isDemo, historyHasMore, !historyLoading,
              historyResultIDs.suffix(8).contains(id) else { return }
        loadHistoryPage(offset: historyPageOffset + 50)
    }

    func loadPreviousHistoryPage() {
        guard !isDemo, historyPageOffset > 0, !historyLoading else { return }
        loadHistoryPage(offset: max(0, historyPageOffset - 50))
    }

    private func loadHistoryPage(offset: Int) {
        historyLoading = true
        let generation = historyQueryGeneration, query = queryString, board = selectedPinboardID, currentFilter = filter
        let repository = repository
        Task { @MainActor [weak self] in
            defer { self?.historyLoading = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let plan = KnowledgeQueryPlan.parse(query)
                    var effective = currentFilter
                    if let kind = plan.kind { effective.kind = ClipKind(rawValue: kind) }
                    if let source = plan.source { effective.sourceName = source }
                    if let range = plan.timeRange { effective.since = range.start; effective.until = range.end }
                    let rows = try repository.loadItems(limit: 50, offset: offset, query: plan.query, pinboardID: board, filter: effective, includePayload: false)
                    return (rows, try repository.itemCount())
                }.value
                guard let self, self.historyQueryGeneration == generation else { return }
                self.installHistoryPage(result.0, offset: offset, total: result.1)
                self.historyHasMore = result.0.count == 50
            } catch { self?.statusMessage = "读取失败：\(error.localizedDescription)" }
        }
    }

    func materializedItems(_ items: [ClipItem]) -> [ClipItem] {
        guard !isDemo else {
            let existing = Set(snapshot.items.map(\.id))
            return items.filter { existing.contains($0.id) }
        }
        do {
            let loaded = Dictionary(try repository.loadItems(ids: items.map(\.id)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return items.compactMap { dirtyHistoryItems[$0.id] ?? loaded[$0.id] }
        } catch { statusMessage = "读取内容失败：\(error.localizedDescription)"; return [] }
    }

    func loadDisplayPayload(_ id: UUID) {
        guard !isDemo, let summary = snapshot.items.first(where: { $0.id == id }),
              summary.kind == .image, summary.representations.isEmpty else { return }
        let repository = repository
        Task { @MainActor [weak self] in
            do {
                let loaded = try await Task.detached(priority: .utility) { try repository.loadItems(ids: [id]).first }.value
                guard let self, let loaded, self.snapshot.items.contains(where: { $0.id == id && $0.fingerprint == summary.fingerprint }), self.dirtyHistoryItems[id] == nil else { return }
                self.loadingHistoryWindow = true
                self.snapshot.items = self.snapshot.items.map { $0.id == id ? loaded : $0 }
                self.loadingHistoryWindow = false
            } catch { self?.statusMessage = "读取图片失败：\(error.localizedDescription)" }
        }
    }

    func releaseDisplayPayload(_ id: UUID) {
        guard !isDemo, !selectedIDs.contains(id), dirtyHistoryItems[id] == nil,
              !activeHistoryReferences.values.contains(where: { $0.contains(id) }), toolItemID != id,
              !processingImageIDs.contains(id), !stackItems.contains(where: { $0.id == id }) else { return }
        loadingHistoryWindow = true
        snapshot.items = snapshot.items.map { $0.id == id ? $0.metadataOnly() : $0 }
        loadingHistoryWindow = false
    }
}

extension AppModel {
    func ensureHistoryItemsLoaded(_ ids: Set<UUID>) {
        guard !isDemo else { return }
        do {
            let existing = Set(snapshot.items.map(\.id))
            let rows = try repository.loadItems(ids: Array(ids.subtracting(existing)))
            loadingHistoryWindow = true
            snapshot.items += rows.filter { !deletedHistoryIDs.contains($0.id) }
            loadingHistoryWindow = false
        } catch { statusMessage = "读取历史失败：\(error.localizedDescription)" }
    }
    func retainHistory(_ ids: [UUID], for window: String) {
        activeHistoryReferences[window] = Set(ids)
        guard !isDemo else { return }
        do {
            let loaded = try repository.loadItems(ids: ids, includePayload: window != "suggestion")
            let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loadingHistoryWindow = true
            snapshot.items = snapshot.items.map { dirtyHistoryItems[$0.id] ?? byID[$0.id] ?? $0 }
            let existing = Set(snapshot.items.map(\.id))
            snapshot.items += loaded.filter { !existing.contains($0.id) }
            loadingHistoryWindow = false
        } catch { statusMessage = "读取来源失败：\(error.localizedDescription)" }
    }
    func releaseHistory(for window: String) { activeHistoryReferences.removeValue(forKey: window) }
}
