import Foundation
import CryptoKit

extension SnapshotRepository {
    /// Isolates damaged files, validates the replacement, and restores originals if replacement fails.
    /// The legacy JSON remains at its original path after success as a separate recovery source.
    public func recoverCorruptStore(with snapshot: ClipboardSnapshot) throws {
        try validate(snapshot)
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        let backup = directory.appendingPathComponent("Damaged Store Recovery", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let candidates = [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm"), storeURL]
        var moved: [(original: URL, backup: URL)] = []
        var beganReplacement = false
        do {
            for original in candidates where manager.fileExists(atPath: original.path) {
                let destination = backup.appendingPathComponent(original.lastPathComponent)
                try manager.moveItem(at: original, to: destination)
                moved.append((original, destination))
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            beganReplacement = true
            try save(snapshot)
            guard try load() == snapshot else { throw SnapshotRepositoryError.invalidData("导入内容校验失败") }
            if let legacy = moved.first(where: { $0.original == storeURL }) {
                try manager.copyItem(at: legacy.backup, to: legacy.original)
            }
        } catch {
            var rollbackFailures: [String] = []
            if beganReplacement {
                for file in candidates where manager.fileExists(atPath: file.path) {
                    do { try manager.removeItem(at: file) }
                    catch { rollbackFailures.append(file.lastPathComponent) }
                }
            }
            for file in moved.reversed() {
                do { try manager.moveItem(at: file.backup, to: file.original) }
                catch { rollbackFailures.append(file.original.lastPathComponent) }
            }
            if !rollbackFailures.isEmpty { throw SnapshotRepositoryError.invalidData("导入失败。原文件保存在 \(backup.path)，请保留该目录以恢复数据") }
            throw error
        }
    }

    /// Saves raw database rows for undo. Attachments remain content-addressed and are never loaded here.
    public func archiveItems(ids: Set<UUID>) throws -> String {
        let token = UUID().uuidString
        return try withDatabase { database in
            try database.transaction {
                try prepareItemRecovery(database)
                let encoded = String(decoding: try JSONEncoder().encode(ids.map(\.uuidString).sorted()), as: UTF8.self)
                try database.execute("INSERT INTO item_recovery(token,item_id,payload,sort,last_copied,kind,source,fingerprint,search_text,job_fingerprint) SELECT ?,items.id,items.payload,items.sort,items.last_copied,items.kind,items.source,items.fingerprint,items.search_text,knowledge_jobs.fingerprint FROM items JOIN json_each(?) AS selected ON selected.value=items.id LEFT JOIN knowledge_jobs ON knowledge_jobs.item_id=items.id", [.text(token),.text(encoded)])
            }
            return token
        }
    }

    /// Restores only missing records: newer edits and captures always take precedence over an old undo.
    @discardableResult
    public func restoreArchivedItems(token: String) throws -> [UUID] {
        guard UUID(uuidString: token) != nil else { throw SnapshotRepositoryError.invalidData("恢复记录无效") }
        return try withDatabase { database in
            try database.transaction {
                try prepareItemRecovery(database)
                try database.execute("CREATE TEMP TABLE restoring_items(item_id TEXT PRIMARY KEY)")
                try database.execute("INSERT INTO restoring_items SELECT item_id FROM item_recovery WHERE token=? AND NOT EXISTS(SELECT 1 FROM items WHERE items.id=item_recovery.item_id)", [.text(token)])
                try database.execute("INSERT INTO items(id,payload,sort,last_copied,kind,source,fingerprint,search_text) SELECT item_id,payload,sort,last_copied,kind,source,fingerprint,search_text FROM item_recovery WHERE token=? AND item_id IN(SELECT item_id FROM restoring_items)", [.text(token)])
                try database.execute("INSERT INTO items_fts(rowid,id,content) SELECT items.rowid,items.id,items.search_text FROM items WHERE id IN(SELECT item_id FROM item_recovery WHERE token=? AND item_id IN(SELECT item_id FROM restoring_items))", [.text(token)])
                var restored: [UUID] = []
                try database.rows("SELECT item_id,payload,job_fingerprint FROM item_recovery WHERE token=? AND item_id IN(SELECT item_id FROM restoring_items) ORDER BY sort DESC,item_id", [.text(token)]) { statement in
                    let id = SQLiteDatabase.text(statement, 0)
                    guard let uuid = UUID(uuidString: id) else { throw SnapshotRepositoryError.invalidData("恢复卡片 ID 无效") }
                    var stamp = SQLiteDatabase.text(statement, 2)
                    if stamp.isEmpty { stamp = SHA256.hash(data: SQLiteDatabase.data(statement, 1)).map { String(format: "%02x", $0) }.joined() }
                    try database.execute("INSERT INTO knowledge_jobs(item_id,fingerprint,state,error,eligible) VALUES(?,?,'pending',NULL,0) ON CONFLICT(item_id) DO UPDATE SET fingerprint=excluded.fingerprint,state='pending',error=NULL,eligible=0", [.text(id),.text(stamp)])
                    restored.append(uuid)
                }
                return restored
            }
        }
    }

    private func prepareItemRecovery(_ database: SQLiteDatabase) throws {
        try database.execute("CREATE TABLE IF NOT EXISTS item_recovery(token TEXT NOT NULL,item_id TEXT NOT NULL,payload BLOB NOT NULL,sort REAL NOT NULL,last_copied REAL NOT NULL,kind TEXT NOT NULL,source TEXT NOT NULL,fingerprint TEXT NOT NULL,search_text TEXT NOT NULL,job_fingerprint TEXT,PRIMARY KEY(token,item_id))")
    }
}
