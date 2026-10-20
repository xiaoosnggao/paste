import Foundation
import CSQLite
import CryptoKit

public enum SnapshotRepositoryError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidData(String)
    case tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "备份版本 \(version) 不受支持。"
        case .invalidData(let reason): return "剪贴板数据无效：\(reason)"
        case .tooLarge: return "数据文件过大，无法导入。"
        }
    }
}

public final class SnapshotRepository: Sendable {
    let directory: URL
    var storeURL: URL { directory.appendingPathComponent("clipboard.json") }
    public init(directory: URL) { self.directory = directory }
    let lock = NSRecursiveLock()
    public var databaseURL: URL { directory.appendingPathComponent("clipboard.sqlite") }
    public func load() throws -> ClipboardSnapshot {
        try withDatabase { database in
            var snapshot = try metadata(database)
            snapshot.items = try items(database, limit: nil)
            return snapshot
        }
    }
    public func save(_ snapshot: ClipboardSnapshot) throws {
        try validate(snapshot)
        try withDatabase { database in
            try database.transaction {
                var existing = Set<String>()
                try database.rows("SELECT id FROM items") { existing.insert(SQLiteDatabase.text($0, 0)) }
                for (index, item) in snapshot.items.enumerated() {
                    try upsert(item, sort: Double(snapshot.items.count - index), database: database)
                    existing.remove(item.id.uuidString)
                }
                for id in existing { try remove(id, database: database) }
                // Full replacement is an import/restore, never a request to classify historical content.
                try database.execute("UPDATE knowledge_jobs SET eligible=0 WHERE eligible<>0")
                try saveMetadata(snapshot, database: database)
            }
        }
    }
    /// Validates the loaded window without requiring unloaded membership references.
    public func validatePartial(_ snapshot: ClipboardSnapshot) throws {
        var partial = snapshot; partial.pinboards = []; partial.session = nil
        try validate(partial)
    }
    public func loadMetadata() throws -> ClipboardSnapshot { try withDatabase { try metadata($0) } }
    public func itemCount() throws -> Int {
        try withDatabase { database in
            var count = 0
            try database.rows("SELECT COUNT(*) FROM items") { count = Int(sqlite3_column_int64($0, 0)) }
            return count
        }
    }
    public func itemCount(query: String) throws -> Int {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return try itemCount() }
        return try withDatabase { database in
            var count = 0
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try database.rows("SELECT COUNT(*) FROM items WHERE id IN (SELECT id FROM items_fts WHERE items_fts MATCH ?) OR instr(lower(search_text),lower(?))>0", [.text(phrase),.text(term)]) { count = Int(sqlite3_column_int64($0, 0)) }
            return count
        }
    }
    public func loadItems(limit: Int, offset: Int = 0, query: String = "", pinboardID: UUID? = nil, filter: ClipFilter = .init(), includePayload: Bool = true) throws -> [ClipItem] {
        try withDatabase { try items($0, limit: max(0, limit), offset: max(0, offset), query: query, pinboardID: pinboardID, filter: filter, includePayload: includePayload) }
    }
    public func loadItems(ids: [UUID], includePayload: Bool = true) throws -> [ClipItem] {
        try withDatabase { database in
            try ids.compactMap { id in
                var item: ClipItem?
                try database.rows("SELECT payload FROM items WHERE id=?", [.text(id.uuidString)]) { item = try decodeItem(SQLiteDatabase.data($0, 0), includePayload: includePayload) }
                return item
            }
        }
    }
    public func item(matchingFingerprint fingerprint: String, derivation: ClipDerivation?) throws -> ClipItem? {
        try withDatabase { database in
            var result: ClipItem?
            try database.rows("SELECT payload FROM items WHERE fingerprint=? ORDER BY sort DESC", [.text(fingerprint)]) {
                let item = try decodeItem(SQLiteDatabase.data($0, 0))
                if result == nil && item.derivation == derivation { result = item }
            }
            return result
        }
    }
    public func allItemIDs(pinboardID: UUID? = nil, unfiledOnly: Bool = false) throws -> [UUID] {
        try withDatabase { database in
            let meta = try metadata(database)
            let boardIDs = pinboardID.flatMap { id in meta.pinboards.first { $0.id == id }?.itemIDs }
            if pinboardID != nil { return boardIDs ?? [] }
            let filed = Set(meta.pinboards.flatMap(\.itemIDs))
            var result: [UUID] = []
            try database.rows("SELECT id FROM items ORDER BY sort DESC,id") {
                if let id = UUID(uuidString: SQLiteDatabase.text($0, 0)), !unfiledOnly || !filed.contains(id) { result.append(id) }
            }
            return result
        }
    }
    /// Applies explicit deltas, preserving every unloaded row. Metadata contains complete boards/session.
    public func applyChanges(metadata snapshot: ClipboardSnapshot, upserting: [ClipItem], deleting: Set<UUID>) throws {
        var partial = snapshot; partial.items = upserting
        try validatePartial(partial)
        try withDatabase { database in
            try database.transaction {
                for id in deleting { try remove(id.uuidString, database: database) }
                var nextSort = 0.0
                try database.rows("SELECT COALESCE(MAX(sort),0) FROM items") { nextSort = sqlite3_column_double($0, 0) }
                for item in upserting.reversed() {
                    var sort: Double?
                    try database.rows("SELECT sort,last_copied FROM items WHERE id=?", [.text(item.id.uuidString)]) {
                        if sqlite3_column_double($0, 1) == item.lastCopiedAt.timeIntervalSince1970 { sort = sqlite3_column_double($0, 0) }
                    }
                    if sort == nil { nextSort += 1; sort = nextSort }
                    try upsert(item, sort: sort!, database: database, classifyNew: true)
                }
                try validateReferences(snapshot, database: database)
                try saveMetadata(snapshot, database: database)
            }
        }
    }
    public func export(_ snapshot: ClipboardSnapshot, to url: URL) throws { try write(snapshot, to: url) }
    public func importSnapshot(from url: URL) throws -> ClipboardSnapshot { try read(url) }

    func read(_ url: URL) throws -> ClipboardSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue >= 0 else { throw SnapshotRepositoryError.tooLarge }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SnapshotRepositoryError.invalidData("请选择文件") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        let snapshot: ClipboardSnapshot
        do { snapshot = try JSONDecoder().decode(ClipboardSnapshot.self, from: data) }
        catch { throw SnapshotRepositoryError.invalidData("无法解析数据：\(error.localizedDescription)") }
        try validate(snapshot)
        return snapshot
    }
    private func write(_ snapshot: ClipboardSnapshot, to url: URL) throws {
        try validate(snapshot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".paste-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
    /// Checks admission invariants without touching durable storage.
    public func validate(_ snapshot: ClipboardSnapshot) throws {
        guard snapshot.version == 1 else { throw SnapshotRepositoryError.unsupportedVersion(snapshot.version) }
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw SnapshotRepositoryError.invalidData(reason) } }
        try require(snapshot.preferences.ignoredBundleIDs.count <= 1000 && snapshot.preferences.ignoredBundleIDs.allSatisfy { $0.utf8.count <= 1024 }, "忽略应用列表无效")
        let itemIDs = Set(snapshot.items.map(\.id))
        try require(itemIDs.count == snapshot.items.count, "条目 ID 重复")
        try require(Set(snapshot.pinboards.map(\.id)).count == snapshot.pinboards.count, "收藏夹 ID 重复")
        for item in snapshot.items {
            try require(item.createdAt.timeIntervalSince1970.isFinite && item.lastCopiedAt.timeIntervalSince1970.isFinite, "时间无效")
            try require(item.text.utf8.count <= 2 * 1024 * 1024 && item.title.utf8.count <= 16_384, "文字过长")
            try require(item.sourceBundleID.utf8.count <= 1024 && item.sourceName.utf8.count <= 4096, "来源名称过长")
            try require(item.representations.count <= 256 && item.filePaths.count <= 1024, "条目格式或文件数量过多")
            for path in item.filePaths { try require(path.utf8.count <= 16_384, "文件路径过长") }
            if let derivation = item.derivation {
                try require(derivation.provider.utf8.count <= 1024, "结果服务名称过长")
                try require(!derivation.sourceItemIDs.contains(item.id) && Set(derivation.sourceItemIDs).count == derivation.sourceItemIDs.count, "结果来源无效")
            }
            if let enrichment = item.enrichment {
                if let ocr = enrichment.ocr {
                    try require(ocr.text.utf8.count <= 2 * 1024 * 1024, "OCR 文字过长")
                    try require(!ocr.provider.isEmpty && ocr.provider.utf8.count <= 1024 && ocr.createdAt.timeIntervalSince1970.isFinite, "文字识别记录无效")
                }
                if let translation = enrichment.translation {
                    try require(translation.sourceText.utf8.count <= 2 * 1024 * 1024 && translation.translatedText.utf8.count <= 2 * 1024 * 1024, "翻译文字过长")
                    try require(!translation.sourceLanguage.isEmpty && !translation.targetLanguage.isEmpty && translation.sourceLanguage.utf8.count <= 64 && translation.targetLanguage.utf8.count <= 64, "翻译语言无效")
                    try require(!translation.provider.isEmpty && !translation.model.isEmpty && translation.provider.utf8.count <= 1024 && translation.model.utf8.count <= 1024 && translation.createdAt.timeIntervalSince1970.isFinite, "翻译记录无效")
                }
            }
            try require(item.originalRepresentations == nil || item.kind == .image, "原图数据只能用于图片卡片")
            try require((item.originalRepresentations?.count ?? 0) <= 256, "原始图片格式数量过多")
            for group in [item.representations, item.originalRepresentations ?? []] {
            var representationKeys = Set<String>()
            for representation in group {
                try require((0...1023).contains(representation.itemIndex) && !representation.type.isEmpty && representation.type.utf8.count <= 1024, "剪贴板格式无效")
                try require(representationKeys.insert("\(representation.itemIndex):\(representation.type)").inserted, "同一条目的格式重复")
            }
            }
        }
        if let session = snapshot.session {
            try require(Set(session.stackItemIDs).count == session.stackItemIDs.count && Set(session.stackItemIDs).isSubset(of: itemIDs), "连续粘贴列表无效")
            if let until = session.pauseUntil { try require(until.timeIntervalSince1970.isFinite, "暂停时间无效") }
            try require(!session.pauseIndefinitely || session.pauseUntil == nil, "暂停状态冲突")
        }
        for board in snapshot.pinboards {
            try require(!board.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && board.name.utf8.count <= 4096 && board.colorHex.utf8.count <= 64, "收藏夹名称或颜色无效")
            try require(Set(board.itemIDs).count == board.itemIDs.count && Set(board.itemIDs).isSubset(of: itemIDs), "收藏夹引用无效")
        }
    }
}
