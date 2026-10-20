import Foundation
import PasteCore

extension AppModel {
    /// Archive database rows for undo without retaining binary payloads in the UI model.
    func deleteHistoryBatch(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try synchronizeDurableHistory()
        let token = try repository.archiveItems(ids: ids)
        var before = snapshot; before.items = []
        let next = SnapshotOperations.deleteItems(ids: ids, in: snapshot)
        var after = next; after.items = []
        deletedHistoryIDs.formUnion(ids)
        for id in ids { dirtyHistoryItems.removeValue(forKey: id) }
        snapshot = next
        persist()
        undoManager.registerUndo(withTarget: self) { target in
            do { try target.restoreHistoryBatch(token: token, ids: ids, before: before, after: after) }
            catch { target.statusMessage = "恢复失败：\(error.localizedDescription)" }
        }
        undoManager.setActionName("删除历史记录")
    }

    private func restoreHistoryBatch(token: String, ids: Set<UUID>, before: ClipboardSnapshot, after: ClipboardSnapshot) throws {
        var restoredIDs: [UUID] = []
        try persistence.performSynchronous { restoredIDs = try repository.restoreArchivedItems(token: token) }
        deletedHistoryIDs.subtract(restoredIDs)
        let restored = SnapshotOperations.undoChange(before: before, after: after, in: snapshot, preserveUnloadedReferences: true)
        loadingHistoryWindow = true
        snapshot = restored
        loadingHistoryWindow = false
        persist()
        scheduleHistoryQuery()
        let restoredSet = Set(restoredIDs)
        undoManager.registerUndo(withTarget: self) { target in
            do { try target.deleteHistoryBatch(ids: restoredSet) }
            catch { target.statusMessage = "删除失败：\(error.localizedDescription)" }
        }
        undoManager.setActionName("删除历史记录")
    }
}
