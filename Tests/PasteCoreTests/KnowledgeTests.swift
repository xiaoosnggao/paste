import XCTest
@testable import PasteCore

final class KnowledgeTests: XCTestCase {
    let space = KnowledgeNamespace(provider: "apple", model: "sentence", revision: 1, dimension: 2, language: "en")
    func testVectorValidationAndSpaceIsolation() throws {
        let vector = try KnowledgeVector(namespace: space, values: [3, 4])
        XCTAssertEqual(vector.values[0], 0.6, accuracy: 0.0001)
        XCTAssertThrowsError(try KnowledgeVector(namespace: space, values: [0, 0]))
        XCTAssertThrowsError(try KnowledgeVector(namespace: space, values: [.nan, 1]))
        XCTAssertThrowsError(try KnowledgeVector(namespace: space, values: [1]))
        let other = KnowledgeNamespace(provider: "apple", model: "sentence", revision: 2, dimension: 2, language: "en")
        XCTAssertNil(vector.similarity(to: try KnowledgeVector(namespace: other, values: [3, 4])))
        XCTAssertEqual(vector.similarity(to: vector)!, 1, accuracy: 0.0001)
    }
    func testClassificationNeedsMarginAndPreservesManualChoice() throws {
        let vector = try KnowledgeVector(namespace: space, values: [1, 0])
        let first = KnowledgeCategoryProfile(id: UUID(), revision: "a", label: "Code", vectors: [vector], manualExampleCount: 3)
        let second = KnowledgeCategoryProfile(id: UUID(), revision: "a", label: "Work", vectors: [vector], manualExampleCount: 3)
        XCTAssertNil(KnowledgeClassifier.classify(vector: vector, profiles: [first, second]).automaticCategoryID)
        XCTAssertEqual(KnowledgeClassifier.classify(vector: vector, profiles: [first]).automaticCategoryID, first.id)
        XCTAssertNil(KnowledgeClassifier.classify(vector: vector, profiles: [first], manualCategoryIDs: [second.id]).automaticCategoryID)
        XCTAssertNil(KnowledgeClassifier.classify(vector: vector, profiles: [first], excludedCategoryIDs: [first.id]).automaticCategoryID)
    }
    func testLocalChineseCategoryRulesAndManualExclusions() throws {
        let id = UUID()
        let profile = KnowledgeCategoryProfile(id: id, revision: "v1", label: "数据库", vectors: [], manualExampleCount: 0)
        XCTAssertEqual(KnowledgeLocalRules.classify(text: "数据库迁移备份", profiles: [profile]), id)
        XCTAssertNil(KnowledgeLocalRules.classify(text: "数据库迁移", profiles: [profile], excludedCategoryIDs: [id]))
        XCTAssertNil(KnowledgeLocalRules.classify(text: "数据库迁移", profiles: [profile], manualCategoryIDs: [UUID()]))
        let rule = KnowledgeCategoryRule(categoryID: id, profileRevision: "v1", requiredPhrases: ["SQL", "migration"])
        XCTAssertEqual(KnowledgeLocalRules.classify(text: "SQL migration plan", profiles: [profile], rules: [rule]), id)
        XCTAssertNil(KnowledgeLocalRules.classify(text: "PostgreSQL migrations", profiles: [profile], rules: [rule]))
        let chineseSpace = KnowledgeNamespace(provider: "apple-natural-language", model: "sentence-embedding", revision: 1, dimension: 2, language: "zh-Hans")
        let vector = try KnowledgeVector(namespace: chineseSpace, values: [1, 0])
        let semantic = KnowledgeCategoryProfile(id: id, revision: "v1", label: "数据库", vectors: [vector], manualExampleCount: 1)
        let result = KnowledgeClassifier.classify(vector: vector, profiles: [semantic])
        XCTAssertNil(result.automaticCategoryID)
        XCTAssertEqual(result.candidates.first?.categoryID, id)
    }
    func testDecodedVectorsCannotBypassValidation() {
        let encoded = #"{"namespace":{"provider":"test","model":"test","revision":1,"dimension":2,"language":"en"},"values":[0,0]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(KnowledgeVector.self, from: Data(encoded.utf8)))
    }
    func testQueryUsesCalendarIntervalsAndKeepsUnknownWords() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_729_339_200)
        let plan = KnowledgeQueryPlan.parse("找上周从微信复制的报价", now: now, calendar: calendar)
        XCTAssertEqual(plan.source, "微信")
        XCTAssertNotNil(plan.timeRange)
        XCTAssertTrue(plan.query.contains("报价"))
        XCTAssertEqual(plan.intent, .search)
        XCTAssertEqual(KnowledgeQueryPlan.parse("删除刚才找到的链接").intent, .previewDelete)
        XCTAssertEqual(KnowledgeQueryPlan.parse("把这些内容归到项目资料").intent, .previewCategorize)
        XCTAssertEqual(KnowledgeQueryPlan.parse("SQL delete from samples").intent, .search)
    }
    func testChunksKeepAllTextAndStableOffsets() {
        let text = String(repeating: "文字\n", count: 3000)
        let chunks = KnowledgeTextChunks.split(text, maximumCharacters: 512)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertEqual(chunks.map(\.ordinal), Array(chunks.indices))
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 512 })
    }
    func testExplicitChineseFiltersConsumeOnlyTheirOwnParticles() {
        let links = KnowledgeQueryPlan.parse("上周的链接")
        XCTAssertEqual(links.query, "")
        XCTAssertEqual(links.kind, "link")
        XCTAssertNotNil(links.timeRange)
        let deletion = KnowledgeQueryPlan.parse("删除昨天的截图")
        XCTAssertEqual(deletion.query, "")
        XCTAssertEqual(deletion.kind, "image")
        XCTAssertEqual(deletion.intent, .previewDelete)
        XCTAssertNotNil(deletion.timeRange)
        XCTAssertEqual(KnowledgeQueryPlan.parse("上周的我的数据库链接").query, "我的数据库")
        XCTAssertEqual(KnowledgeQueryPlan.parse("从头开始设计").query, "从头开始设计")
        XCTAssertEqual(KnowledgeQueryPlan.parse("我的数据库").query, "我的数据库")
        XCTAssertEqual(KnowledgeQueryPlan.parse("删除未知的记录").query, "未知的记录")
    }
    func testRollingIntervalsUseCalendarArithmeticAndRetainUnknownText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_729_339_200)
        let days = KnowledgeQueryPlan.parse("最近3天的链接", now: now, calendar: calendar)
        XCTAssertEqual(days.query, "")
        XCTAssertEqual(days.timeRange, DateInterval(start: calendar.date(byAdding: .day, value: -3, to: now)!, end: now))
        let weeks = KnowledgeQueryPlan.parse("过去2周的项目报价", now: now, calendar: calendar)
        XCTAssertEqual(weeks.query, "项目报价")
        XCTAssertEqual(weeks.timeRange, DateInterval(start: calendar.date(byAdding: .weekOfYear, value: -2, to: now)!, end: now))
        XCTAssertEqual(KnowledgeQueryPlan.parse("删除最近0天的记录").query, "最近0天的记录")
        XCTAssertEqual(KnowledgeQueryPlan.parse("最近999999999999999999999天的记录").query, "最近999999999999999999999天的记录")
    }
}
