import AppKit
import PasteCore

extension AppModel {
    func removeImageBackground(_ item: ClipItem) {
        guard processingImageIDs.isEmpty else { statusMessage = "正在处理图片，请等待完成或取消操作。"; return }
        guard !processingImageIDs.contains(item.id),
              let current = snapshot.items.first(where: { $0.id == item.id }), current.kind == .image,
              let data = Self.imageData(current) else { statusMessage = "无法读取此图片。"; return }
        processingImageIDs.insert(current.id)
        let work = Task.detached(priority: .utility) { try ImageProcessing.removeBackground(data) }
        imageProcessingTasks[current.id] = Task { @MainActor [weak self] in
            defer { self?.processingImageIDs.remove(current.id); self?.imageProcessingTasks[current.id] = nil }
            do {
                let output = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                guard let self, let latest = self.snapshot.items.first(where: { $0.id == current.id }), latest == current else { return }
                var updated = latest
                updated.originalRepresentations = latest.originalRepresentations ?? latest.representations
                updated.representations = [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: output)]
                updated.filePaths = []
                if self.commit(SnapshotOperations.replaceItem(updated, in: self.snapshot), action: "移除图片背景") {
                    self.statusMessage = "背景已移除。可通过“恢复原图”撤销。"
                }
            } catch is CancellationError { }
            catch { self?.statusMessage = error.localizedDescription }
        }
    }
    func cancelImageProcessing(_ id: UUID) { imageProcessingTasks[id]?.cancel() }
    func restoreImageBackground(_ item: ClipItem) {
        cancelImageProcessing(item.id)
        guard let latest = snapshot.items.first(where: { $0.id == item.id }), let original = latest.originalRepresentations else { return }
        var restored = latest
        restored.representations = original
        restored.originalRepresentations = nil
        if commit(SnapshotOperations.replaceItem(restored, in: snapshot), action: "恢复原图") { statusMessage = "已恢复原图。" }
    }
    static func imageData(_ item: ClipItem) -> Data? {
        item.representations.first { [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, "public.jpeg", "public.heic"].contains($0.type) }?.data
    }
}
