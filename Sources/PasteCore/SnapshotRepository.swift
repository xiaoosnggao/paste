import Foundation

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
    private let directory: URL
    private var storeURL: URL { directory.appendingPathComponent("clipboard.json") }
    private let maxEncodedBytes = 100 * 1024 * 1024
    private let maxDecodedBytes = 64 * 1024 * 1024
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> ClipboardSnapshot {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return .init() }
        return try read(storeURL)
    }
    public func save(_ snapshot: ClipboardSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try write(snapshot, to: storeURL)
    }
    public func export(_ snapshot: ClipboardSnapshot, to url: URL) throws { try write(snapshot, to: url) }
    public func importSnapshot(from url: URL) throws -> ClipboardSnapshot { try read(url) }

    private func read(_ url: URL) throws -> ClipboardSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maxEncodedBytes else { throw SnapshotRepositoryError.tooLarge }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SnapshotRepositoryError.invalidData("请选择文件") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxEncodedBytes + 1) ?? Data()
        guard data.count <= maxEncodedBytes else { throw SnapshotRepositoryError.tooLarge }
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
        guard data.count <= maxEncodedBytes else { throw SnapshotRepositoryError.tooLarge }
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
        try require(snapshot.items.count <= 10_000 && snapshot.pinboards.count <= 1000, "条目或收藏夹数量过多")
        try require((1...10_000).contains(snapshot.preferences.maxHistoryItems), "历史数量限制无效")
        if let days = snapshot.preferences.retentionDays { try require((1...36_500).contains(days), "保留天数无效") }
        try require(snapshot.preferences.ignoredBundleIDs.count <= 1000 && snapshot.preferences.ignoredBundleIDs.allSatisfy { $0.utf8.count <= 1024 }, "忽略应用列表无效")
        let itemIDs = Set(snapshot.items.map(\.id))
        try require(itemIDs.count == snapshot.items.count, "条目 ID 重复")
        try require(Set(snapshot.pinboards.map(\.id)).count == snapshot.pinboards.count, "收藏夹 ID 重复")
        var total = 0
        func account(_ count: Int) throws {
            guard count <= maxDecodedBytes - total else { throw SnapshotRepositoryError.tooLarge }; total += count
        }
        for item in snapshot.items {
            try require(item.createdAt.timeIntervalSince1970.isFinite && item.lastCopiedAt.timeIntervalSince1970.isFinite, "时间无效")
            try require(item.text.utf8.count <= 2 * 1024 * 1024 && item.title.utf8.count <= 16_384, "文字过长")
            try require(item.sourceBundleID.utf8.count <= 1024 && item.sourceName.utf8.count <= 4096, "来源名称过长")
            try require(item.representations.count <= 256 && item.filePaths.count <= 1024, "条目格式或文件数量过多")
            try account(item.text.utf8.count + item.title.utf8.count + item.sourceBundleID.utf8.count + item.sourceName.utf8.count)
            for path in item.filePaths { try require(path.utf8.count <= 16_384, "文件路径过长"); try account(path.utf8.count) }
            if let derivation = item.derivation {
                try require(derivation.provider.utf8.count <= 1024, "结果服务名称过长")
                try account(derivation.provider.utf8.count + 64)
                try require(derivation.sourceItemID != item.id, "结果不能引用自身作为原始卡片")
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
                try account(enrichment.payloadByteCount)
            }
            try require(item.originalRepresentations == nil || item.kind == .image, "原图数据只能用于图片卡片")
            try require((item.originalRepresentations?.count ?? 0) <= 256, "原始图片格式数量过多")
            for group in [item.representations, item.originalRepresentations ?? []] {
            var representationKeys = Set<String>()
            for representation in group {
                try require((0...1023).contains(representation.itemIndex) && !representation.type.isEmpty && representation.type.utf8.count <= 1024, "剪贴板格式无效")
                try require(representationKeys.insert("\(representation.itemIndex):\(representation.type)").inserted, "同一条目的格式重复")
                try account(representation.data.count + representation.type.utf8.count)
            }
            }
        }
        if let session = snapshot.session {
            try require(session.stackItemIDs.count <= 10_000 && Set(session.stackItemIDs).count == session.stackItemIDs.count && Set(session.stackItemIDs).isSubset(of: itemIDs), "连续粘贴列表无效")
            if let until = session.pauseUntil { try require(until.timeIntervalSince1970.isFinite, "暂停时间无效") }
            try require(!session.pauseIndefinitely || session.pauseUntil == nil, "暂停状态冲突")
            try account(session.stackItemIDs.count * 16)
        }
        for board in snapshot.pinboards {
            try require(!board.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && board.name.utf8.count <= 4096 && board.colorHex.utf8.count <= 64, "收藏夹名称或颜色无效")
            try require(board.itemIDs.count <= 10_000 && Set(board.itemIDs).count == board.itemIDs.count && Set(board.itemIDs).isSubset(of: itemIDs), "收藏夹引用无效")
            try account(board.name.utf8.count + board.colorHex.utf8.count + board.itemIDs.count * 16)
        }
    }
}
