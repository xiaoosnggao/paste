import XCTest
import CSQLite
@testable import PasteCore

final class KnowledgePerformanceTests: XCTestCase {
    /// Explicit opt-in scale benchmark. Every row is a synthetic fixture, never personal content.
    func testLocalDatabaseScale() throws {
        guard ProcessInfo.processInfo.environment["PASTE_KNOWLEDGE_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in synthetic database benchmark") }
        let count = Int(ProcessInfo.processInfo.environment["PASTE_KNOWLEDGE_BENCH_ROWS"] ?? "100000") ?? 100000
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-scale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        try repository.save(.init())
        let namespace = KnowledgeNamespace(provider: "benchmark", model: "synthetic", revision: 1, dimension: 640, language: "zh-Hans")
        let vector = try KnowledgeVector(namespace: namespace, values: [1] + Array(repeating: 0.01, count: 639))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = String(decoding: try encoder.encode(namespace), as: UTF8.self)
        let bytes = vector.values.map(Float.init).withUnsafeBytes { Data($0) }
        let started = Date()
        // Populate via the real repository in bounded batches. No full-history array is retained.
        for start in stride(from: 0, to: count, by: 1000) {
            let rows = (start..<min(count,start+1000)).map { (i: Int) -> ClipItem in
                let date = Date(timeIntervalSince1970: Double(i))
                let keyword: String = i % 100 == 0 ? "目标检索词" : "普通内容"
                let isWeChat = i % 2 == 0
                return ClipItem(createdAt: date, lastCopiedAt: date,
                                title: "合成记录 \(i)", text: "项目报价与交付安排 fixture \(i) \(keyword)", kind: .text,
                                sourceBundleID: isWeChat ? "fixture.wechat" : "fixture.lark", sourceName: isWeChat ? "微信" : "飞书")
            }
            try repository.applyChanges(metadata: .init(), upserting: rows, deleting: [])
        }
        let index = KnowledgeIndexRepository(directory: directory)
        _ = try index.counts()
        try repository.withDatabase { db in
            try db.transaction {
                try db.execute("INSERT INTO knowledge_vectors(item_id,ordinal,namespace,vector,text) SELECT id,0,?,?,search_text FROM items", [.text(key),.blob(bytes)])
                try db.execute("UPDATE knowledge_jobs SET state='ready'")
            }
        }
        func sample(_ operation: () throws -> Void) throws -> Double {
            try operation()
            var times: [Double] = []
            for _ in 0..<12 {
                let before = DispatchTime.now().uptimeNanoseconds
                try operation()
                times.append(Double(DispatchTime.now().uptimeNanoseconds-before)/1_000_000)
            }
            return times.sorted()[11]
        }
        let page = try sample { XCTAssertEqual(try repository.loadItems(limit:50,includePayload:false).count,50) }
        let lexical = try sample { XCTAssertFalse(try repository.loadItems(limit:50,query:"目标检索词",includePayload:false).isEmpty) }
        let semantic = try sample { XCTAssertEqual(try index.search(vector:vector,limit:50).count,50) }
        var source = ClipFilter(); source.sourceName = "微信"
        let filtered = try sample { XCTAssertTrue(try repository.loadItems(limit:50,query:"目标检索词",filter:source,includePayload:false).allSatisfy { $0.sourceName == "微信" }) }
        let report: [String: Any] = ["rows":count,"dimensions":640,"fixture":"synthetic equal vectors; complete full index scan", "p95_ms":["page":page,"keyword":lexical,"vector":semantic,"source_keyword":filtered],"setup_seconds":Date().timeIntervalSince(started)]
        print("KNOWLEDGE_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: report,options:[.sortedKeys]),as:UTF8.self))
        XCTAssertEqual(try repository.itemCount(),count)
        XCTAssertLessThan(page,500,"Paged loading exceeded interactive budget")
        XCTAssertLessThan(lexical,150,"Keyword search exceeded target")
        if count <= 100000 { XCTAssertLessThan(semantic,800,"Full local vector search exceeded target") }
    }
}
