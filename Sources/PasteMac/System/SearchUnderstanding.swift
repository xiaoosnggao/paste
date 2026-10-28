import Foundation
import PasteCore

/// What the panel's search field understood from a plain-language query such as
/// “上周从微信复制的报价”: the structured filters that were peeled off, the words
/// still searched, and whether the on-device semantic index re-ranked the results.
/// Everything is computed locally; nothing leaves the Mac.
struct SearchUnderstanding: Equatable, Sendable {
    enum Ranking: Equatable, Sendable {
        /// Keyword results are showing; the local semantic pass has not finished yet.
        case pending
        /// Results blend keyword and meaning-based (on-device embedding) matches.
        case semantic
        /// The semantic index was unavailable for this query; keyword results only.
        case keywordOnly
        /// Only filters were given, nothing to rank.
        case filtersOnly
    }
    var filters: [String]
    var terms: String
    var ranking: Ranking

    init(filters: [String], terms: String, ranking: Ranking) {
        self.filters = filters; self.terms = terms; self.ranking = ranking
    }

    /// Returns nil for an empty query, so the hint disappears with the text.
    init?(plan: KnowledgeQueryPlan, rawQuery: String) {
        guard !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, plan.intent == .search else { return nil }
        filters = plan.understoodFilters
        terms = plan.query
        ranking = plan.query.isEmpty ? .filtersOnly : .pending
    }

    /// Show the hint only when it says something beyond the typed words.
    var isInformative: Bool { !filters.isEmpty || ranking == .semantic }

    var symbol: String {
        switch ranking {
        case .semantic: return "sparkles"
        case .keywordOnly: return "textformat.abc"
        case .pending: return "ellipsis"
        case .filtersOnly: return "line.3.horizontal.decrease"
        }
    }

    /// Short visible label, e.g. “昨天 · 图片 · 按意思”.
    var label: String {
        var parts = filters
        if ranking == .semantic { parts.append("按意思") }
        return parts.joined(separator: " · ")
    }

    var help: String {
        let scope = filters.isEmpty ? "" : "已识别条件：\(filters.joined(separator: "、"))。"
        let words = terms.isEmpty ? "" : "搜索“\(terms)”，"
        switch ranking {
        case .semantic: return scope + words + "并按意思在本机补充相近内容。"
        case .keywordOnly: return scope + words + "按关键词匹配（本机语义索引暂不可用）。"
        case .pending: return scope + words + "正在本机按意思补充结果…"
        case .filtersOnly: return scope + "显示符合条件的全部内容。"
        }
    }
}
