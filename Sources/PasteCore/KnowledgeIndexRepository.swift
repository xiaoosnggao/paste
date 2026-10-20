import Foundation
import CSQLite
import Accelerate

public struct KnowledgeIndexJob: Sendable {
    public let itemID: UUID
    public let fingerprint: String
    public let eligibleForClassification: Bool
}
public struct KnowledgeIndexedChunk: Sendable {
    public let ordinal: Int
    public let text: String
    public let vector: KnowledgeVector
    public init(ordinal: Int, text: String, vector: KnowledgeVector) { self.ordinal = ordinal; self.text = text; self.vector = vector }
}
public struct KnowledgeSearchHit: Sendable {
    public let itemID: UUID
    public let score: Double
    public let snippet: String
}
/// Rebuildable local indexes share the content database, but never become its source of truth.
public final class KnowledgeIndexRepository: Sendable {
    private let repository: SnapshotRepository
    public init(directory: URL) { repository = SnapshotRepository(directory: directory) }
    private func database<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try repository.withDatabase { db in
            try db.execute("CREATE TABLE IF NOT EXISTS knowledge_vectors(item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,ordinal INTEGER NOT NULL,namespace TEXT NOT NULL,vector BLOB NOT NULL,text TEXT NOT NULL,PRIMARY KEY(item_id,ordinal))")
            try db.execute("CREATE INDEX IF NOT EXISTS knowledge_vectors_namespace ON knowledge_vectors(namespace)")
            try db.execute("CREATE TABLE IF NOT EXISTS knowledge_memberships(item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,category_id TEXT NOT NULL,origin TEXT NOT NULL,revision TEXT NOT NULL,PRIMARY KEY(item_id,category_id))")
            try db.execute("CREATE TABLE IF NOT EXISTS knowledge_exclusions(item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,category_id TEXT NOT NULL,PRIMARY KEY(item_id,category_id))")
            return try body(db)
        }
    }
    public func resume() throws {
        try database { try $0.execute("UPDATE knowledge_jobs SET state='pending',error=NULL WHERE state='processing'") }
    }
    public func retryFailures() throws {
        try database { try $0.execute("UPDATE knowledge_jobs SET state='pending',error=NULL WHERE state='failed'") }
    }
    public func nextJob() throws -> KnowledgeIndexJob? {
        try database { db in
            try db.transaction {
                var job: KnowledgeIndexJob?
                try db.rows("SELECT item_id,fingerprint,eligible FROM knowledge_jobs WHERE state='pending' ORDER BY rowid LIMIT 1") {
                    if let id = UUID(uuidString: SQLiteDatabase.text($0, 0)) { job = .init(itemID: id, fingerprint: SQLiteDatabase.text($0, 1), eligibleForClassification: sqlite3_column_int64($0,2) != 0) }
                }
                if let job { try db.execute("UPDATE knowledge_jobs SET state='processing' WHERE item_id=? AND fingerprint=?", [.text(job.itemID.uuidString),.text(job.fingerprint)]) }
                return job
            }
        }
    }
    public func complete(_ job: KnowledgeIndexJob, chunks: [KnowledgeIndexedChunk]) throws -> Bool {
        try database { db in
            try db.transaction {
                var current = false
                try db.rows("SELECT 1 FROM knowledge_jobs j JOIN items i ON i.id=j.item_id WHERE j.item_id=? AND j.fingerprint=? AND j.state='processing'", [.text(job.itemID.uuidString),.text(job.fingerprint)]) { _ in current = true }
                guard current else { return false }
                try db.execute("DELETE FROM knowledge_vectors WHERE item_id=?", [.text(job.itemID.uuidString)])
                for chunk in chunks {
                    let values = chunk.vector.values.map(Float.init)
                    let bytes = values.withUnsafeBytes { Data($0) }
                    try db.execute("INSERT INTO knowledge_vectors(item_id,ordinal,namespace,vector,text) VALUES(?,?,?,?,?)", [.text(job.itemID.uuidString),.integer(Int64(chunk.ordinal)),.text(try namespaceKey(chunk.vector.namespace)),.blob(bytes),.text(chunk.text)])
                }
                try db.execute("UPDATE knowledge_jobs SET state='ready',error=NULL WHERE item_id=? AND fingerprint=?", [.text(job.itemID.uuidString),.text(job.fingerprint)])
                return true
            }
        }
    }
    public func isCurrentReady(_ job: KnowledgeIndexJob) throws -> Bool {
        try database { db in
            var current = false
            try db.rows("SELECT 1 FROM knowledge_jobs WHERE item_id=? AND fingerprint=? AND state='ready'", [.text(job.itemID.uuidString),.text(job.fingerprint)]) { _ in current = true }
            return current
        }
    }
    public func fail(_ job: KnowledgeIndexJob, message: String) throws {
        try database { try $0.execute("UPDATE knowledge_jobs SET state='failed',error=? WHERE item_id=? AND fingerprint=?", [.text(String(message.prefix(200))),.text(job.itemID.uuidString),.text(job.fingerprint)]) }
    }
    public func counts() throws -> (ready: Int, pending: Int, failed: Int) {
        try database { db in
            var ready = 0, pending = 0, failed = 0
            try db.rows("SELECT state,COUNT(*) FROM knowledge_jobs GROUP BY state") { row in
                let count = Int(sqlite3_column_int64(row, 1))
                switch SQLiteDatabase.text(row, 0) { case "ready": ready += count; case "failed": failed += count; default: pending += count }
            }
            return (ready,pending,failed)
        }
    }
    public func search(vector: KnowledgeVector, filter: ClipFilter = .init(), pinboardID: UUID? = nil, limit: Int = 100) throws -> [KnowledgeSearchHit] {
        try database { db in
            var sql = "SELECT v.item_id,v.vector,v.text FROM knowledge_vectors v JOIN items i ON i.id=v.item_id JOIN knowledge_jobs j ON j.item_id=i.id AND j.state='ready' WHERE v.namespace=?"
            var values: [SQLiteDatabase.Value] = [.text(try namespaceKey(vector.namespace))]
            if let kind = filter.kind { sql += " AND i.kind=?"; values.append(.text(kind.rawValue)) }
            if let source = filter.sourceBundleID { sql += " AND i.source=?"; values.append(.text(source)) }
            if let source = filter.sourceName, !source.isEmpty {
                let aliases = ["微信": "wechat", "飞书": "lark", "VS Code": "code", "Chrome": "chrome"]
                let alias = aliases[source] ?? source
                sql += " AND (instr(lower(i.source),lower(?))>0 OR instr(lower(json_extract(CAST(i.payload AS TEXT),'$.item.sourceName')),lower(?))>0 OR instr(lower(i.source),lower(?))>0 OR instr(lower(json_extract(CAST(i.payload AS TEXT),'$.item.sourceName')),lower(?))>0)"
                values += [.text(source),.text(source),.text(alias),.text(alias)]
            }
            if let since = filter.since { sql += " AND i.last_copied>=?"; values.append(.real(since.timeIntervalSince1970)) }
            if let until = filter.until { sql += " AND i.last_copied<?"; values.append(.real(until.timeIntervalSince1970)) }
            if let pinboardID {
                let board = try repository.metadata(db).pinboards.first { $0.id == pinboardID }
                guard let board else { return [] }
                sql += " AND i.id IN (SELECT value FROM json_each(?))"
                values.append(.text(String(decoding: try JSONEncoder().encode(board.itemIDs.map(\.uuidString)), as: UTF8.self)))
            }
            let needle = vector.values.map(Float.init), capacity = max(1,min(limit,500))
            var top: [KnowledgeSearchHit] = []
            try db.rows(sql, values) { row in
                try Task.checkCancellation()
                guard let id = UUID(uuidString: SQLiteDatabase.text(row,0)) else { return }
                let bytes = SQLiteDatabase.data(row,1)
                guard bytes.count == needle.count * MemoryLayout<Float>.size else { return }
                let score: Float = bytes.withUnsafeBytes { raw in
                    var dot: Float = 0
                    needle.withUnsafeBufferPointer { input in
                        if let a = input.baseAddress, let b = raw.bindMemory(to: Float.self).baseAddress { vDSP_dotpr(a,1,b,1,&dot,vDSP_Length(needle.count)) }
                    }
                    return dot
                }
                guard score.isFinite else { return }
                if let old = top.firstIndex(where: { $0.itemID == id }) {
                    guard Double(score) > top[old].score else { return }; top.remove(at: old)
                } else if top.count >= capacity, Double(score) <= (top.last?.score ?? -1) { return }
                top.append(.init(itemID:id,score:Double(score),snippet:String(SQLiteDatabase.text(row,2).prefix(220))))
                top.sort { $0.score > $1.score }
                if top.count > capacity { top.removeLast() }
            }
            return top
        }
    }
    public func assignments(itemID: UUID) throws -> (automatic: Set<UUID>, excluded: Set<UUID>) {
        try database { db in
            var automatic = Set<UUID>(), excluded = Set<UUID>()
            try db.rows("SELECT category_id FROM knowledge_memberships WHERE item_id=? AND origin='auto'", [.text(itemID.uuidString)]) { if let id = UUID(uuidString: SQLiteDatabase.text($0,0)) { automatic.insert(id) } }
            try db.rows("SELECT category_id FROM knowledge_exclusions WHERE item_id=?", [.text(itemID.uuidString)]) { if let id = UUID(uuidString: SQLiteDatabase.text($0,0)) { excluded.insert(id) } }
            return (automatic,excluded)
        }
    }
    public func recordAssignment(itemID: UUID, categoryID: UUID, automatic: Bool, revision: String = "") throws {
        try database { db in
            if automatic { try db.execute("DELETE FROM knowledge_memberships WHERE item_id=? AND origin='auto' AND category_id<>?", [.text(itemID.uuidString),.text(categoryID.uuidString)]) }
            try db.execute("INSERT INTO knowledge_memberships(item_id,category_id,origin,revision) VALUES(?,?,?,?) ON CONFLICT(item_id,category_id) DO UPDATE SET origin=excluded.origin,revision=excluded.revision", [.text(itemID.uuidString),.text(categoryID.uuidString),.text(automatic ? "auto" : "manual"),.text(revision)])
            if !automatic { try db.execute("DELETE FROM knowledge_exclusions WHERE item_id=? AND category_id=?", [.text(itemID.uuidString),.text(categoryID.uuidString)]) }
        }
    }
    public func exclude(itemID: UUID, categoryID: UUID) throws {
        try database { db in
            try db.transaction {
                try db.execute("INSERT OR IGNORE INTO knowledge_exclusions(item_id,category_id) VALUES(?,?)", [.text(itemID.uuidString),.text(categoryID.uuidString)])
                try db.execute("DELETE FROM knowledge_memberships WHERE item_id=? AND category_id=?", [.text(itemID.uuidString),.text(categoryID.uuidString)])
            }
        }
    }
    private func namespaceKey(_ value: KnowledgeNamespace) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
