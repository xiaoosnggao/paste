import Foundation
import PasteCore

struct HistoryManagementPreview: Identifiable, Sendable {
    let id = UUID()
    let query: String
    let intent: KnowledgeQueryIntent
    let itemIDs: Set<UUID>
    let categoryName: String?
    let categoryID: UUID?
    let error: String?
    let examples: [String]
    var title: String {
        switch intent {
        case .previewDelete: return "删除搜索结果"
        case .previewCategorize: return "归类搜索结果"
        case .previewSummarize: return "总结搜索结果"
        case .search: return "搜索结果"
        }
    }
}

extension AppModel {
    /// Resolves the complete result set, rather than acting only on the loaded display page.
    /// No mutation or AI request happens until the preview's explicit apply action.
    func prepareHistoryManagementPreview() async {
        let query = queryString, generation = historyQueryGeneration
        let plan = KnowledgeQueryPlan.parse(query)
        guard plan.intent != .search else { historyManagementPreview = nil; return }
        let repository = repository, persistence = persistence
        let boardID = selectedPinboardID
        var effective = filter
        if let kind = plan.kind { effective.kind = ClipKind(rawValue: kind) }
        if let range = plan.timeRange { effective.since = range.start; effective.until = range.end }
        if let source = plan.source { effective.sourceName = source }
        let searchFilter = effective
        do {
            let collection = Task.detached(priority: .userInitiated) {
                persistence.flush()
                var ids = Set<UUID>(), offset = 0
                while true {
                    try Task.checkCancellation()
                    let rows = try repository.loadItems(limit: 50, offset: offset, query: plan.query, pinboardID: boardID, filter: searchFilter, includePayload: false)
                    ids.formUnion(rows.map(\.id))
                    guard rows.count == 50 else { break }
                    offset += 50
                }
                return ids
            }
            let ids = try await withTaskCancellationHandler {
                try await collection.value
            } onCancel: { collection.cancel() }
            // Nearest-neighbor results are recommendations, not an explicit operation scope.
            // Bulk mutations use only the complete lexical/structured match set above.
            try Task.checkCancellation()
            guard queryString == query, historyQueryGeneration == generation else { return }
            let categoryID = plan.category.flatMap { name in snapshot.pinboards.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }?.id }
            let error: String?
            if ids.isEmpty { error = "没有匹配的内容" }
            else if plan.intent == .previewCategorize && categoryID == nil { error = "未找到“\(plan.category ?? "")”分类" }
            else { error = nil }
            let examples = try repository.loadItems(ids: Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(8)), includePayload: false).map { String(($0.title.isEmpty ? $0.text : $0.title).prefix(100)) }
            let preview = HistoryManagementPreview(query: query, intent: plan.intent, itemIDs: ids, categoryName: plan.category, categoryID: categoryID, error: error, examples: examples)
            historyManagementPreview = preview
            onHistoryManagementPreview?(preview)
        } catch is CancellationError { }
        catch { statusMessage = "无法准备操作：\(error.localizedDescription)" }
    }
}
