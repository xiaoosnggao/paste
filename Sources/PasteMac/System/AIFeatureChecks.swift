#if DEBUG
import AppKit
import CoreImage
import PasteCore

/// Self-test coverage for the pass-13 AI features: plain-language search parsing,
/// on-device image insights, and 多条合成一条.
@MainActor
enum AIFeatureChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: "AI features: " + message) }; count += 1
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        // 用大白话搜历史
        let plain = KnowledgeQueryPlan.parse("帮我找昨天从微信复制的图片", now: now, calendar: calendar)
        try check(plain.kind == "image" && plain.source == "微信" && plain.timeLabel == "昨天", "plain-language filters not parsed")
        try check(plain.understoodFilters == ["昨天", "来自 微信", "图片"], "understood filters wrong: \(plain.understoodFilters)")
        try check(plain.query.isEmpty, "filler words left in query: \(plain.query)")
        let older = KnowledgeQueryPlan.parse("前天的颜色", now: now, calendar: calendar)
        try check(older.kind == "color" && older.timeLabel == "前天", "前天/颜色 not parsed")
        if let range = older.timeRange, let expected = calendar.date(byAdding: .day, value: -2, to: now) {
            try check(range.contains(expected) && !range.contains(now), "前天 range wrong")
        } else { try check(false, "前天 range missing") }
        let topic = KnowledgeQueryPlan.parse("我之前那个关于报价的链接")
        try check(topic.kind == "link" && topic.query.contains("报价") && !topic.query.contains("之前"), "topic query not cleaned: \(topic.query)")
        try check(KnowledgeQueryPlan.parse("我的数据库").query == "我的数据库", "substantive phrase damaged")
        try check(KnowledgeQueryPlan.parse("最近3天的链接", now: now, calendar: calendar).timeLabel == "最近3天", "relative time label missing")
        try check(SearchUnderstanding(plan: .parse(""), rawQuery: "  ") == nil, "empty query produced a hint")
        try check(SearchUnderstanding(plan: .parse("删除昨天的截图"), rawQuery: "删除昨天的截图") == nil, "management query produced a search hint")
        let filtersOnly = SearchUnderstanding(plan: plain, rawQuery: "帮我找昨天从微信复制的图片")
        try check(filtersOnly?.ranking == .filtersOnly && filtersOnly?.isInformative == true, "filters-only hint wrong")
        var semantic = SearchUnderstanding(plan: .parse("报价"), rawQuery: "报价")
        try check(semantic?.ranking == .pending && semantic?.isInformative == false, "pending keyword hint should stay hidden")
        semantic?.ranking = .semantic
        try check(semantic?.label == "按意思" && semantic?.isInformative == true, "semantic hint label wrong")
        semantic?.ranking = .keywordOnly
        try check(semantic?.help.contains("关键词") == true, "keyword fallback not explained")

        // 图片智能识别: pure helpers
        let pixels = Array(repeating: (UInt8(255), UInt8(0), UInt8(0)), count: 70) + Array(repeating: (UInt8(0), UInt8(0), UInt8(255)), count: 30)
        try check(ImageInsights.dominantColors(pixels: pixels) == ["#FF0000", "#0000FF"], "dominant colors wrong")
        try check(ImageInsights.dominantColors(pixels: []).isEmpty, "empty image produced colors")
        func box(_ text: String, x: CGFloat, y: CGFloat) -> ImageInsights.TextBox { .init(text: text, rect: CGRect(x: x, y: y, width: 0.2, height: 0.04)) }
        let grid = [box("名称", x: 0.1, y: 0.8), box("价格", x: 0.5, y: 0.81), box("苹果", x: 0.1, y: 0.7), box("5", x: 0.5, y: 0.7),
                    box("香蕉", x: 0.11, y: 0.6), box("3", x: 0.51, y: 0.6), box("合计 8 元", x: 0.1, y: 0.4)]
        let rows = ImageInsights.rows(from: grid)
        try check(rows.count == 4 && rows[0].map(\.text) == ["名称", "价格"], "text rows not grouped")
        let table = ImageInsights.table(from: rows)
        try check(table == [["名称", "价格"], ["苹果", "5"], ["香蕉", "3"]], "table not rebuilt")
        let sample = ImageInsights(text: "", codes: [], table: table, colors: [])
        try check(sample.tableTSV == "名称\t价格\n苹果\t5\n香蕉\t3", "table TSV wrong")
        try check(sample.tableMarkdown?.hasPrefix("| 名称 | 价格 |\n| --- | --- |") == true, "table markdown wrong")
        let ragged = [box("a", x: 0.1, y: 0.8), box("b", x: 0.5, y: 0.8), box("c", x: 0.3, y: 0.7), box("d", x: 0.8, y: 0.7)]
        try check(ImageInsights.table(from: ImageInsights.rows(from: ragged)) == nil, "misaligned columns treated as a table")
        try check(ImageInsights.table(from: ImageInsights.rows(from: [box("单行", x: 0.1, y: 0.5)])) == nil, "prose treated as a table")

        // 图片智能识别: Vision on a generated QR code
        let payload = "https://example.com/pasteboard"
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent.insetBy(dx: -24, dy: -24)) else { throw Failure(message: "QR fixture failed") }
        let png = try ImageProcessing.png(cg)
        let insights = try await ImageInsights.analyze(png)
        try check(insights.codes.contains { $0.payload == payload && $0.kind == "二维码" && $0.isLink }, "QR code not detected")
        try check(!insights.colors.isEmpty && insights.colors.allSatisfy { $0.count == 7 && $0.hasPrefix("#") }, "QR colors missing")
        do { _ = try await ImageInsights.analyze(Data("not an image".utf8)); try check(false, "malformed image analyzed") }
        catch is ImageInsights.Failure { count += 1 }

        // 多条合成一条
        try check(ClipMergeMode.lines.join([" a ", "", "b"]) == "a\nb", "line join wrong")
        try check(ClipMergeMode.paragraphs.join(["a", "b"]) == "a\n\nb", "paragraph join wrong")
        try check(ClipMergeMode.bullets.join(["a\nb", "c"]) == "- a\n  b\n- c", "bullet join wrong")
        try check(ClipMergeMode.local.allSatisfy { !$0.usesAI && $0.suggestion == nil }, "local modes call AI")
        try check(ClipMergeMode.ai.count == 3 && ClipMergeMode.ai.allSatisfy { $0.suggestion?.instruction.contains("不编造") == true || $0.suggestion?.instruction.contains("注明来源") == true }, "AI mode instructions missing guardrails")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-merge-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, storageDirectory: root)
        let first = ClipItem(createdAt: Date(timeIntervalSince1970: 100), text: "第一段", kind: .text)
        let second = ClipItem(createdAt: Date(timeIntervalSince1970: 200), text: "第二段", kind: .text)
        let blankImage = ClipItem(createdAt: Date(timeIntervalSince1970: 300), text: "", kind: .image)
        model.snapshot = .init(items: [second, first, blankImage], pinboards: [])
        model.selectedIDs = [first.id]
        try check(!model.canMergeSelection, "single selection can merge")
        model.selectedIDs = [first.id, blankImage.id]
        try check(!model.canMergeSelection, "unrecognized image counted as mergeable")
        model.selectedIDs = [second.id, first.id, blankImage.id]
        try check(model.canMergeSelection && model.mergeableSelection.map(\.id) == [first.id, second.id], "merge order is not chronological")
        model.mergeSelection(.lines)
        let merged = model.snapshot.items.first { $0.derivation?.operation == .merge }
        try check(merged?.text == "第一段\n第二段", "merged card text wrong")
        try check(merged?.derivation?.sourceItemIDs == [first.id, second.id], "merged card lost its sources")
        try check(model.snapshot.items.contains { $0.id == first.id } && model.snapshot.items.contains { $0.id == second.id }, "merging removed the originals")
        try check(merged.map { model.selectedIDs == [$0.id] } == true, "merged card not selected")
        model.undo()
        try check(!model.snapshot.items.contains { $0.derivation?.operation == .merge }, "merge undo failed")
        model.selectedIDs = [first.id, second.id]
        model.mergeSelection(.minutes)
        try check(model.mergeInProgress == nil && !model.snapshot.items.contains { $0.derivation?.operation == .merge }, "AI merge ran without a configured service")
        return count
    }
}
#endif
