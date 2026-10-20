import Foundation
import PasteCore

extension AppModel {
    var suggestionAdditionalHeight: CGFloat {
        guard selectedIDs.count > 1 else { return 0 }
        return 102 + (multiCardSummaryExpanded ? min(160, CGFloat(multiCardSummary?.facts.count ?? 0) * 22 + 28) : 0)
    }
    func startLocalKnowledge() {
        guard !isDemo else { return }
        automaticClassificationEnabled = toolDefaults.object(forKey: "local.autoClassification") as? Bool ?? true
        knowledgeCoordinator = LocalKnowledgeCoordinator(directory: storageDirectory, onOutcome: { [weak self] outcome in
            await self?.receiveLocalClassification(outcome)
        }, onStatus: { [weak self] status in await self?.updateLocalIndexStatus(status) })
        if let coordinator = knowledgeCoordinator { Task { await coordinator.start(classify: automaticClassificationEnabled) } }
    }
    private func updateLocalIndexStatus(_ status: String?) { localIndexStatus = status }
    func setAutomaticClassification(_ value: Bool) {
        automaticClassificationEnabled = value
        toolDefaults.set(value, forKey: "local.autoClassification")
        if let coordinator = knowledgeCoordinator { Task { await coordinator.setClassification(value) } }
    }
    func retryLocalKnowledge() {
        guard let coordinator = knowledgeCoordinator else { return }
        Task { do { try await coordinator.retry() } catch { localIndexStatus = "本地索引暂不可用，可重试" } }
    }
    func indexSavedItems(_ items: [ClipItem], deleted: Set<UUID>) {
        guard let coordinator = knowledgeCoordinator else { return }
        for id in deleted { suggestedCategories.removeValue(forKey: id) }
        Task { await coordinator.start(classify: automaticClassificationEnabled) }
    }
    func receiveLocalClassification(_ outcome: LocalKnowledgeCoordinator.Outcome) {
        guard automaticClassificationEnabled, !deletedHistoryIDs.contains(outcome.itemID) else { return }
        guard (try? KnowledgeIndexRepository(directory: storageDirectory).isCurrentReady(outcome.job)) == true, dirtyHistoryItems[outcome.itemID] == nil else { return }
        suggestedCategories[outcome.itemID] = outcome.candidates
        guard let id = outcome.categoryID,
              let board = snapshot.pinboards.first(where: { $0.id == id }), board.automaticClassification != false,
              LocalKnowledgeCoordinator.revision(board) == outcome.categoryRevision else { return }
        do {
            let state = KnowledgeIndexRepository(directory: storageDirectory)
            let memberships = try state.assignments(itemID: outcome.itemID)
            guard !memberships.excluded.contains(id), !snapshot.pinboards.contains(where: { $0.itemIDs.contains(outcome.itemID) && !memberships.automatic.contains($0.id) }) else { return }
            guard let item = try repository.loadItems(ids: [outcome.itemID], includePayload: false).first else { return }
            // If the content changed again while classification ran, the persisted ready job is no longer current.
            guard dirtyHistoryItems[outcome.itemID] == nil else { return }
            var next = snapshot
            next.pinboards = next.pinboards.map { value in
                var updated = value
                if memberships.automatic.contains(value.id) && value.id != id { updated.itemIDs.removeAll { $0 == item.id } }
                if value.id == id && !value.itemIDs.contains(item.id) { updated.itemIDs.append(item.id) }
                return updated
            }
            if commit(next, action: "自动分类") {
                try state.recordAssignment(itemID: item.id, categoryID: id, automatic: true, revision: outcome.categoryRevision ?? "")
            }
        } catch { localIndexStatus = "自动分类暂不可用，可重试" }
    }
    func recordManualClassification(ids: [UUID], categoryID: UUID, removing: Bool) {
        guard !isDemo else { return }
        let store = KnowledgeIndexRepository(directory: storageDirectory)
        do {
            persistence.flush()
            for id in ids {
                if removing { try store.exclude(itemID: id, categoryID: categoryID) }
                else { try store.recordAssignment(itemID: id, categoryID: categoryID, automatic: false) }
            }
            if let coordinator = knowledgeCoordinator { Task { await coordinator.refreshProfiles() } }
        } catch { localIndexStatus = "分类记录未保存，可重试" }
    }
    func setClassificationDetails(_ id: UUID, description: String, enabled: Bool, keywords: [String] = []) {
        var next = snapshot
        next.pinboards = next.pinboards.map { board in
            var value = board
            if board.id == id { value.classificationDescription = String(description.prefix(500)); value.classificationKeywords = keywords.map { String($0.prefix(80)) }; value.automaticClassification = enabled }
            return value
        }
        if commit(next, action: "分类设置"), let coordinator = knowledgeCoordinator { Task { await coordinator.refreshProfiles() } }
    }
    func categories(for itemID: UUID) -> [Pinboard] { snapshot.pinboards.filter { $0.itemIDs.contains(itemID) } }

    func enrichHistorySearch(plan: KnowledgeQueryPlan, filter: ClipFilter, generation: UUID) async {
        guard let coordinator = knowledgeCoordinator, !plan.query.isEmpty else { return }
        do {
            let hits = try await coordinator.search(plan.query, filter: filter, board: selectedPinboardID)
            guard !Task.isCancelled, historyQueryGeneration == generation else { return }
            let lexical = historyResultIDs
            var ranked: [UUID: Double] = [:]
            for (offset,id) in lexical.enumerated() { ranked[id,default:0] += 2.0 / Double(60 + offset) }
            for (offset,hit) in hits.enumerated() { ranked[hit.itemID,default:0] += 1.0 / Double(60 + offset) }
            let ids = ranked.keys.sorted { ranked[$0,default:0] > ranked[$1,default:0] }.prefix(100).map { $0 }
            let repository = repository
            let items = try await Task.detached(priority: .userInitiated) { try repository.loadItems(ids: ids, includePayload: false) }.value
            guard historyQueryGeneration == generation, !Task.isCancelled else { return }
            let byID = Dictionary(items.map { ($0.id,$0) },uniquingKeysWith:{first,_ in first})
            installHistoryPage(ids.compactMap { byID[$0] }, offset: 0, total: historyTotalCount)
        } catch is CancellationError { }
        catch {
            // Local models may not support this query language. Keyword results remain usable.
            localIndexStatus = "当前语言暂不支持语义搜索"
        }
    }
    func finishHistoryReplacement() {
        corruptStore = false; storageError = nil
        dirtyHistoryItems.removeAll(); deletedHistoryIDs.removeAll()
        if let coordinator = knowledgeCoordinator { Task { await coordinator.stop() }; startLocalKnowledge() }
        scheduleHistoryQuery()
    }
    func applyHistoryManagement(ids: Set<UUID>, intent: KnowledgeQueryIntent, categoryID: UUID?) async throws {
        guard !ids.isEmpty else { return }
        let existingIDs = Set(try repository.loadItems(ids: Array(ids), includePayload: false).map(\.id))
        guard existingIDs == ids else { throw SnapshotRepositoryError.invalidData("部分内容已更改，请重新搜索") }
        switch intent {
        case .previewDelete:
            try deleteHistoryBatch(ids: ids)
        case .previewCategorize:
            guard let categoryID, snapshot.pinboards.contains(where: { $0.id == categoryID }) else { throw SnapshotRepositoryError.invalidData("分类已删除") }
            var next = snapshot
            next.pinboards = next.pinboards.map { board in
                var value = board
                if value.id == categoryID { value.itemIDs += ids.subtracting(Set(value.itemIDs)).sorted { $0.uuidString < $1.uuidString } }
                return value
            }
            if commit(next, action: "归类搜索结果") { recordManualClassification(ids: Array(ids), categoryID: categoryID, removing: false) }
        case .previewSummarize:
            ensureHistoryItemsLoaded(ids)
            historyResultIDs = snapshot.items.filter { ids.contains($0.id) }.map(\.id)
            selectedIDs = ids
            scheduleContextSuggestions()
        case .search: break
        }
    }
}

extension AppModel {
    func submitHistorySearch() {
        if KnowledgeQueryPlan.parse(queryString).intent == .search { activateSelected() }
        else { Task { await prepareHistoryManagementPreview() } }
    }
    func captureInHistory(_ item: ClipItem) -> ClipboardSnapshot {
        if !isDemo, !snapshot.items.contains(where: { $0.fingerprint == item.fingerprint && $0.derivation == item.derivation }) {
            do {
                if let prior = try repository.item(matchingFingerprint: item.fingerprint, derivation: item.derivation) {
                    loadingHistoryWindow = true
                    snapshot.items.append(prior)
                    loadingHistoryWindow = false
                }
            } catch { statusMessage = "读取重复内容失败：\(error.localizedDescription)" }
        }
        return SnapshotOperations.capture(item, in: snapshot)
    }
}
