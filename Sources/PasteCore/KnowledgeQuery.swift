import Foundation

public enum KnowledgeQueryIntent: String, Codable, Sendable { case search, previewDelete, previewCategorize, previewSummarize }
public struct KnowledgeQueryPlan: Equatable, Sendable {
    public let query: String
    public let source: String?
    public let kind: String?
    public let timeRange: DateInterval?
    public let intent: KnowledgeQueryIntent
    public let category: String?
    /// The time phrase that became `timeRange`, for the “已理解” hint (e.g. “昨天”).
    public var timeLabel: String? = nil

    /// Human-readable filters the parser understood, in display order.
    public var understoodFilters: [String] {
        var chips: [String] = []
        if let timeLabel { chips.append(timeLabel) }
        if let source { chips.append("来自 " + source) }
        if let kind, let value = ClipKind(rawValue: kind) { chips.append(value.displayName) }
        return chips
    }

    /// Parses only explicit local syntax. Unrecognized words remain searchable; no SQL is generated.
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current, availableSources: [String] = []) -> Self {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: String?, kind: String?, timeRange: DateInterval?, category: String?, timeLabel: String?
        var intent = KnowledgeQueryIntent.search
        func consumeFilter(_ word: String) {
            // Only the particle immediately attached to a recognized filter is syntax.
            // Keep substantive phrases such as “我的数据库” intact.
            query = query.replacingOccurrences(of: word + "的", with: " ")
                .replacingOccurrences(of: word, with: " ")
        }
        if query.hasPrefix("删除") { intent = .previewDelete; query.removeFirst(2) }
        else if query.hasPrefix("总结") { intent = .previewSummarize; query.removeFirst(2) }
        else if query.hasPrefix("把"), let range = query.range(of: "归到"), range.upperBound < query.endIndex {
            intent = .previewCategorize; category = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            query = String(query[query.index(after: query.startIndex)..<range.lowerBound])
        }
        if let expression = try? NSRegularExpression(pattern: "(?:最近|过去)([0-9]+)(天|周|小时|个月)"),
           let match = expression.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let countRange = Range(match.range(at: 1), in: query),
           let unitRange = Range(match.range(at: 2), in: query),
           let phraseRange = Range(match.range, in: query),
           let count = Int(query[countRange]), count > 0, count <= 10_000 {
            let units: [String: Calendar.Component] = ["天": .day, "周": .weekOfYear, "小时": .hour, "个月": .month]
            if let component = units[String(query[unitRange])],
               let start = calendar.date(byAdding: component, value: -count, to: now) {
                timeRange = DateInterval(start: start, end: now)
                timeLabel = String(query[phraseRange])
                consumeFilter(String(query[phraseRange]))
            }
        }
        for (word, component, offset) in [("上周", Calendar.Component.weekOfYear, -1), ("前天", .day, -2), ("昨天", .day, -1), ("今天", .day, 0), ("本周", .weekOfYear, 0), ("这周", .weekOfYear, 0), ("上个月", .month, -1), ("本月", .month, 0), ("这个月", .month, 0), ("去年", .year, -1), ("今年", .year, 0)] where timeRange == nil {
            if query.contains(word), let date = calendar.date(byAdding: component, value: offset, to: now) {
                timeRange = calendar.dateInterval(of: component, for: date)
                timeLabel = word
                consumeFilter(word); break
            }
        }
        let knownSources = availableSources + ["Visual Studio Code", "VS Code", "Chrome", "微信", "WeChat", "Lark", "飞书", "Safari", "Xcode", "Codex"]
        for name in Set(knownSources).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            if let range = query.range(of: name, options: .caseInsensitive) {
                source = name
                if query[..<range.lowerBound].hasSuffix("从") {
                    let start = query.index(before: range.lowerBound)
                    query.removeSubrange(start..<range.upperBound)
                } else { query.removeSubrange(range) }; break
            }
        }
        for (word, value) in [("图片", "image"), ("截图", "image"), ("照片", "image"), ("链接", "link"), ("网址", "link"), ("文件", "file"), ("颜色", "color"), ("色值", "color")] where query.contains(word) {
            kind = value; consumeFilter(word); break
        }
        for filler in ["刚才找到的", "复制过来的", "复制的", "帮我找", "找一下", "查找", "搜索", "我之前", "之前", "有关", "相关的", "那个", "那张", "那条"] { query = query.replacingOccurrences(of: filler, with: " ") }
        if query.hasPrefix("找") { query.removeFirst() }
        query = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var plan = Self(query: query, source: source, kind: kind, timeRange: timeRange, intent: intent, category: category)
        plan.timeLabel = timeLabel
        return plan
    }
}
