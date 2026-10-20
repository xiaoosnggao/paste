import AppKit
import PasteCore

extension AppModel {
    @discardableResult
    func saveText(_ text: String, title: String, item: ClipItem?) -> Bool {
        saveEditedText(text, title: title, item: item, representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])
    }

    @discardableResult
    func saveRichText(_ value: NSAttributedString, title: String, item: ClipItem?) -> Bool {
        do {
            let data = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return saveEditedText(value.string, title: title, item: item, representations: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.string.utf8)),
                .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: data)
            ])
        } catch { statusMessage = "富文本保存失败：\(error.localizedDescription)"; return false }
    }

    private func saveEditedText(_ text: String, title: String, item: ClipItem?, representations: [PasteboardRepresentation]) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 2 * 1024 * 1024 else { statusMessage = "文本不能为空，且不能超过 2 MB。"; return false }
        let kind = ContentClassifier.classify(text: text)
        let existing: ClipItem?
        if let item {
            guard !deletedHistoryIDs.contains(item.id), let hydrated = materializedItems([item]).first else {
                statusMessage = "此卡片已删除，请将内容另存为新卡片。"
                return false
            }
            existing = hydrated
        } else { existing = nil }
        let value = ClipItem(id: existing?.id ?? UUID(), createdAt: existing?.createdAt ?? Date(), lastCopiedAt: Date(),
                             title: title.isEmpty ? String(text.prefix(160)) : String(title.prefix(160)),
                             text: text, kind: kind, sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard",
                             sourceName: "Pasteboard", representations: representations, enrichment: existing?.enrichment, derivation: existing?.derivation)
        var base = snapshot
        if let existing, !base.items.contains(where: { $0.id == existing.id }) { base.items.append(existing) }
        var next = existing != nil ? SnapshotOperations.replaceItem(value, in: base) : captureInHistory(value)
        if item == nil, let board = selectedPinboardID,
           let stored = next.items.first(where: { $0.id == value.id || $0.fingerprint == value.fingerprint }) {
            next = SnapshotOperations.pin(itemIDs: [stored.id], to: board, in: next)
        }
        guard commit(next, action: item != nil ? "编辑卡片" : "新建文本") else { return false }
        if item == nil { queryString = ""; filter = .init() }
        if let stored = snapshot.items.first(where: { $0.id == value.id || $0.fingerprint == value.fingerprint }) { select(stored) }
        return true
    }

    func movePinboard(_ id: UUID, delta: Int) {
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + delta
        guard snapshot.pinboards.indices.contains(destination) else { return }
        var next = snapshot
        next.pinboards.swapAt(index, destination)
        commit(next, action: "调整收藏夹顺序")
    }

    func rotateImage(_ item: ClipItem, clockwise: Bool) {
        guard processingImageIDs.isEmpty else { statusMessage = "正在处理图片，请等待完成或取消操作。"; return }
        guard !deletedHistoryIDs.contains(item.id), let current = materializedItems([item]).first,
              let data = Self.imageData(current) else { statusMessage = "无法读取图片，卡片可能已删除。"; return }
        processingImageIDs.insert(current.id)
        let work = Task.detached(priority: .utility) { try ImageProcessing.rotate(data, clockwise: clockwise) }
        imageProcessingTasks[current.id] = Task { @MainActor [weak self] in
            defer { self?.processingImageIDs.remove(current.id); self?.imageProcessingTasks[current.id] = nil }
            do {
                let output = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                guard let self, !self.deletedHistoryIDs.contains(current.id), self.materializedItems([current]).first == current else { return }
                var rotated = current
                rotated.representations = [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: output)]
                rotated.lastCopiedAt = Date()
                if self.commit(SnapshotOperations.replaceItem(rotated, in: self.snapshot), action: "旋转图片") { self.select(rotated) }
            } catch is CancellationError { }
            catch { self?.statusMessage = error.localizedDescription }
        }
    }

    func openItem(_ item: ClipItem) {
        if item.kind == .file {
            let existing = item.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { statusMessage = "原文件已移动或删除。文件卡片仅保存路径。"; return }
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else if item.kind == .link, let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else { preview(item) }
    }

    func chooseIgnoredApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择不记录剪贴板的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var value = snapshot.preferences
        value.ignoredBundleIDs = Array(Set(value.ignoredBundleIDs + ids)).sorted()
        updatePreferences(value)
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "导出剪贴板备份"
        panel.nameFieldStringValue = "Pasteboard-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        panel.message = "备份包含文字和原始格式。文件卡片仅备份路径，不包含文件本身。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try synchronizeDurableHistory()
            try repository.export(isDemo ? snapshot : repository.load(), to: url)
            statusMessage = "备份已导出"
        }
        catch { statusMessage = "导出失败：\(error.localizedDescription)" }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "导入剪贴板备份"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try repository.importSnapshot(from: url)
            let alert = NSAlert()
            alert.messageText = "用备份替换当前历史记录和收藏夹？"
            alert.informativeText = "将导入 \(imported.items.count) 张卡片。可通过“撤销”恢复当前数据。"
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try replaceHistoryFromBackup(imported, action: "导入备份")
            selectedPinboardID = nil
            selectedIDs = []
            selectFirstIfNeeded()
            statusMessage = "备份已导入"
        } catch { statusMessage = "导入失败，当前数据未改变：\(error.localizedDescription)" }
    }
    /// Explicit exports and MCP reads include all accepted, not-yet-completed writes.
    func synchronizeDurableHistory() throws {
        guard !isDemo else { return }
        try persistence.performSynchronous {
            try repository.applyChanges(metadata: snapshot, upserting: Array(dirtyHistoryItems.values), deleting: deletedHistoryIDs)
        }
    }

    private func replaceHistoryFromBackup(_ imported: ClipboardSnapshot, action: String) throws {
        if isDemo { _ = commit(imported, action: action); return }
        if corruptStore { try recoverCorruptHistory(imported); return }
        try synchronizeDurableHistory()
        // Keep import undo on disk instead of retaining an unbounded snapshot in memory.
        let recoveryDirectory = storageDirectory.appendingPathComponent("Import Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let recovery = recoveryDirectory.appendingPathComponent("before-import-\(UUID().uuidString).json")
        let applied = recoveryDirectory.appendingPathComponent("after-import-\(UUID().uuidString).json")
        try repository.export(repository.load(), to: recovery)
        try repository.export(imported, to: applied)
        try persistence.performSynchronous { try repository.save(imported) }
        finishHistoryReplacement()
        loadingHistoryWindow = true
        snapshot = try repository.loadMetadata()
        dirtyHistoryItems.removeAll(); deletedHistoryIDs.removeAll()
        loadingHistoryWindow = false
        selectedIDs = []; selectedPinboardID = nil
        installHistoryPage(try repository.loadItems(limit: 50, includePayload: false), offset: 0, total: try repository.itemCount())
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try target.synchronizeDurableHistory()
                let restored = SnapshotOperations.undoChange(before: try target.repository.importSnapshot(from: recovery),
                                                            after: try target.repository.importSnapshot(from: applied),
                                                            in: try target.repository.load())
                try target.replaceHistoryFromBackup(restored, action: action)
            }
            catch { target.statusMessage = "恢复失败：\(error.localizedDescription)" }
        }
        undoManager.setActionName(action)
        scheduleHistoryQuery()
    }

    func recoverCorruptHistory(_ imported: ClipboardSnapshot) throws {
        try persistence.performSynchronous { try repository.recoverCorruptStore(with: imported) }
        finishHistoryReplacement()
        loadingHistoryWindow = true
        snapshot = try repository.loadMetadata()
        dirtyHistoryItems.removeAll(); deletedHistoryIDs.removeAll()
        loadingHistoryWindow = false
        selectedIDs = []; selectedPinboardID = nil
        installHistoryPage(try repository.loadItems(limit: 50, includePayload: false), offset: 0, total: try repository.itemCount())
        undoManager.removeAllActions()
        scheduleHistoryQuery()
    }
}
