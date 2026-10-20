import Foundation
import CryptoKit
import CSQLite

extension SnapshotRepository {
    private struct StoredItem: Codable {
        var item: ClipItem
        var assets: [Asset]
        var fingerprint: String?
    }
    private struct Asset: Codable {
        var digest: String
        var type: String
        var itemIndex: Int
        var original: Bool
    }
    func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA synchronous=FULL")
        try database.execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,payload BLOB NOT NULL,sort REAL NOT NULL,last_copied REAL NOT NULL,kind TEXT NOT NULL,source TEXT NOT NULL,fingerprint TEXT NOT NULL,search_text TEXT NOT NULL)")
        try database.execute("CREATE INDEX IF NOT EXISTS items_sort ON items(sort DESC,id)")
        try database.execute("CREATE INDEX IF NOT EXISTS items_fingerprint ON items(fingerprint)")
        try database.execute("CREATE INDEX IF NOT EXISTS items_source ON items(source,last_copied)")
        try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')")
        try database.execute("CREATE TABLE IF NOT EXISTS knowledge_jobs(item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,fingerprint TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',error TEXT,eligible INTEGER NOT NULL DEFAULT 0)")
        var hasEligibility = false
        try database.rows("PRAGMA table_info(knowledge_jobs)") { if SQLiteDatabase.text($0, 1) == "eligible" { hasEligibility = true } }
        if !hasEligibility {
            try database.transaction {
                var present = false
                try database.rows("PRAGMA table_info(knowledge_jobs)") { if SQLiteDatabase.text($0, 1) == "eligible" { present = true } }
                if !present { try database.execute("ALTER TABLE knowledge_jobs ADD COLUMN eligible INTEGER NOT NULL DEFAULT 0") }
            }
        }
        // The marker and imported rows commit together. A failed migration is safe to retry.
        var initialized = false
        try database.rows("SELECT 1 FROM settings WHERE key='metadata'") { _ in initialized = true }
        if !initialized {
            try database.transaction {
                var initializedByAnotherConnection = false
                try database.rows("SELECT 1 FROM settings WHERE key='metadata'") { _ in initializedByAnotherConnection = true }
                guard !initializedByAnotherConnection else { return }
                let snapshot = manager.fileExists(atPath: storeURL.path) ? try read(storeURL) : ClipboardSnapshot()
                if manager.fileExists(atPath: storeURL.path) {
                    let backup = directory.appendingPathComponent("clipboard.pre-sqlite.json")
                    if !manager.fileExists(atPath: backup.path) { try manager.copyItem(at: storeURL, to: backup) }
                    // Never overwrite an existing recovery backup. Original JSON remains untouched as well.
                }
                for (index, item) in snapshot.items.enumerated() { try upsert(item, sort: Double(snapshot.items.count - index), database: database) }
                var count = 0
                try database.rows("SELECT COUNT(*) FROM items") { count = Int(sqlite3_column_int64($0, 0)) }
                guard count == snapshot.items.count else { throw SnapshotRepositoryError.invalidData("迁移校验失败，原数据已保留") }
                for item in snapshot.items {
                    var restored: ClipItem?
                    try database.rows("SELECT payload FROM items WHERE id=?", [.text(item.id.uuidString)]) { restored = try decodeItem(SQLiteDatabase.data($0, 0)) }
                    guard restored == item else { throw SnapshotRepositoryError.invalidData("迁移内容校验失败，原数据已保留") }
                }
                try saveMetadata(snapshot, database: database)
            }
        }
        try database.transaction {
            var layoutCurrent = false
            try database.rows("SELECT 1 FROM settings WHERE key='fts-rowid-layout-v1'") { _ in layoutCurrent = true }
            if !layoutCurrent {
                try database.execute("DELETE FROM items_fts")
                try database.execute("INSERT INTO items_fts(rowid,id,content) SELECT rowid,id,search_text FROM items")
                try database.execute("INSERT INTO settings(key,value) VALUES('fts-rowid-layout-v1',X'31')")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        for suffix in ["-wal", "-shm"] where manager.fileExists(atPath: databaseURL.path + suffix) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path + suffix)
        }
        return try body(database)
    }
    func metadata(_ database: SQLiteDatabase) throws -> ClipboardSnapshot {
        var value = ClipboardSnapshot()
        try database.rows("SELECT value FROM settings WHERE key='metadata'") { value = try JSONDecoder().decode(ClipboardSnapshot.self, from: SQLiteDatabase.data($0, 0)) }
        return value
    }
    func saveMetadata(_ snapshot: ClipboardSnapshot, database: SQLiteDatabase) throws {
        var value = snapshot; value.items = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try database.execute("INSERT INTO settings(key,value) VALUES('metadata',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE settings.value<>excluded.value", [.blob(try encoder.encode(value))])
    }
    func validateReferences(_ snapshot: ClipboardSnapshot, database: SQLiteDatabase) throws {
        let references = snapshot.pinboards.flatMap(\.itemIDs) + (snapshot.session?.stackItemIDs ?? [])
        var missing = false
        if !references.isEmpty {
            let encoded = String(decoding: try JSONEncoder().encode(references.map(\.uuidString)), as: UTF8.self)
            try database.rows("SELECT 1 FROM json_each(?) AS reference LEFT JOIN items ON items.id=reference.value WHERE items.id IS NULL LIMIT 1", [.text(encoded)]) { _ in missing = true }
        }
        guard !missing, Set(snapshot.pinboards.map(\.id)).count == snapshot.pinboards.count,
              snapshot.pinboards.allSatisfy({ Set($0.itemIDs).count == $0.itemIDs.count && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 4096 && $0.colorHex.utf8.count <= 64 && ($0.classificationDescription?.utf8.count ?? 0) <= 16_384 }) else {
            throw SnapshotRepositoryError.invalidData("分类或连续粘贴引用无效")
        }
        if let session = snapshot.session {
            guard Set(session.stackItemIDs).count == session.stackItemIDs.count,
                  session.pauseUntil?.timeIntervalSince1970.isFinite ?? true,
                  !session.pauseIndefinitely || session.pauseUntil == nil else { throw SnapshotRepositoryError.invalidData("连续粘贴状态无效") }
        }
    }
    func upsert(_ item: ClipItem, sort: Double, database: SQLiteDatabase, classifyNew: Bool = false) throws {
        let payload = try encodeItem(item)
        let search = [item.title,item.text,item.sourceName,item.enrichment?.ocr?.text ?? "",item.enrichment?.translation?.sourceText ?? "",item.enrichment?.translation?.translatedText ?? ""] + item.filePaths
        let searchable = search.joined(separator: "\n")
        var changed = true, existing = false
        try database.rows("SELECT payload FROM items WHERE id=?", [.text(item.id.uuidString)]) { existing = true; changed = SQLiteDatabase.data($0, 0) != payload }
        try database.execute("INSERT INTO items(id,payload,sort,last_copied,kind,source,fingerprint,search_text) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,sort=excluded.sort,last_copied=excluded.last_copied,kind=excluded.kind,source=excluded.source,fingerprint=excluded.fingerprint,search_text=excluded.search_text WHERE items.payload<>excluded.payload OR items.sort<>excluded.sort", [.text(item.id.uuidString),.blob(payload),.real(sort),.real(item.lastCopiedAt.timeIntervalSince1970),.text(item.kind.rawValue),.text(item.sourceBundleID),.text(item.fingerprint),.text(searchable)])
        if changed {
            let contentVersion = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            try database.execute("INSERT INTO knowledge_jobs(item_id,fingerprint,state,error,eligible) VALUES(?,?,'pending',NULL,?) ON CONFLICT(item_id) DO UPDATE SET fingerprint=excluded.fingerprint,state='pending',error=NULL,eligible=MAX(knowledge_jobs.eligible,excluded.eligible)", [.text(item.id.uuidString),.text(contentVersion),.integer(classifyNew && !existing ? 1 : 0)])
            try database.execute("DELETE FROM items_fts WHERE rowid=(SELECT rowid FROM items WHERE id=?)", [.text(item.id.uuidString)])
            try database.execute("INSERT INTO items_fts(rowid,id,content) SELECT rowid,id,? FROM items WHERE id=?", [.text(searchable),.text(item.id.uuidString)])
        }
    }
    func remove(_ id: String, database: SQLiteDatabase) throws {
        try database.execute("DELETE FROM items_fts WHERE rowid=(SELECT rowid FROM items WHERE id=?)", [.text(id)])
        try database.execute("DELETE FROM items WHERE id=?", [.text(id)])
    }
    func items(_ database: SQLiteDatabase, limit: Int?, offset: Int = 0, query: String = "", pinboardID: UUID? = nil, filter: ClipFilter = .init(), includePayload: Bool = true) throws -> [ClipItem] {
        var clauses: [String] = [], values: [SQLiteDatabase.Value] = []
        if let kind = filter.kind { clauses.append("kind=?"); values.append(.text(kind.rawValue)) }
        if let source = filter.sourceBundleID { clauses.append("source=?"); values.append(.text(source)) }
        if let source = filter.sourceName, !source.isEmpty {
            let aliases = ["微信": "wechat", "飞书": "lark", "VS Code": "code", "Chrome": "chrome"]
            let alias = aliases[source] ?? source
            clauses.append("(instr(lower(json_extract(CAST(items.payload AS TEXT),'$.item.sourceName')),lower(?))>0 OR instr(lower(items.source),lower(?))>0 OR instr(lower(json_extract(CAST(items.payload AS TEXT),'$.item.sourceName')),lower(?))>0 OR instr(lower(items.source),lower(?))>0)")
            values += [.text(source),.text(source),.text(alias),.text(alias)]
        }
        if let since = filter.since { clauses.append("last_copied>=?"); values.append(.real(since.timeIntervalSince1970)) }
        if let until = filter.until { clauses.append("last_copied<?"); values.append(.real(until.timeIntervalSince1970)) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            // FTS word search plus literal substring fallback covers Chinese short queries and code punctuation.
            clauses.append("(items.id IN (SELECT id FROM items_fts WHERE items_fts MATCH ?) OR instr(lower(search_text),lower(?))>0)")
            values += [.text("\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""), .text(term)]
        }
        var source = "items", order = "items.sort DESC,items.id"
        if let pinboardID {
            let ids = try metadata(database).pinboards.first { $0.id == pinboardID }?.itemIDs.map(\.uuidString) ?? []
            source += " JOIN json_each(?) AS membership ON items.id=membership.value"
            values.insert(.text(String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)), at: 0)
            order = "CAST(membership.key AS INTEGER)"
        }
        var sql = "SELECT items.id,items.payload FROM " + source + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY " + order
        if let limit { sql += " LIMIT ? OFFSET ?"; values += [.integer(Int64(limit)),.integer(Int64(offset))] }
        var result: [ClipItem] = []
        try database.rows(sql, values) { result.append(try decodeItem(SQLiteDatabase.data($0, 1), includePayload: includePayload)) }
        return result
    }
    private func encodeItem(_ item: ClipItem) throws -> Data {
        var stored = item, assets: [Asset] = []
        let directory = directory.appendingPathComponent("assets", isDirectory: true)
        for (original, representations) in [(false,item.representations),(true,item.originalRepresentations ?? [])] {
            for representation in representations {
                let digest = SHA256.hash(data: representation.data).map { String(format: "%02x", $0) }.joined()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(digest)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try representation.data.write(to: url, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    let handle = try FileHandle(forWritingTo: url)
                    do { try handle.synchronize(); try handle.close() }
                    catch { try? handle.close(); throw error }
                }
                assets.append(.init(digest: digest, type: representation.type, itemIndex: representation.itemIndex, original: original))
            }
        }
        stored.representations = []
        if stored.originalRepresentations != nil { stored.originalRepresentations = [] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(StoredItem(item: stored, assets: assets, fingerprint: item.fingerprint))
    }
    func decodeItem(_ data: Data, includePayload: Bool = true) throws -> ClipItem {
        let stored = try JSONDecoder().decode(StoredItem.self, from: data)
        var item = stored.item
        guard includePayload else { return item.metadataOnly(fingerprint: stored.fingerprint) }
        var representations: [PasteboardRepresentation] = []
        var originals: [PasteboardRepresentation] = []
        for asset in stored.assets {
            guard asset.digest.count == 64, asset.digest.allSatisfy({ $0.isHexDigit }) else { throw SnapshotRepositoryError.invalidData("附件路径无效") }
            let bytes = try Data(contentsOf: directory.appendingPathComponent("assets").appendingPathComponent(asset.digest))
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == asset.digest else { throw SnapshotRepositoryError.invalidData("附件校验失败") }
            let representation = PasteboardRepresentation(type: asset.type, data: bytes, itemIndex: asset.itemIndex)
            if asset.original { originals.append(representation) }
            else { representations.append(representation) }
        }
        item.representations = representations
        if item.originalRepresentations != nil || !originals.isEmpty { item.originalRepresentations = originals }
        return item
    }
}
