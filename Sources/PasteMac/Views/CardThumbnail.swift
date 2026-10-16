import AppKit
import SwiftUI
import PasteCore

/// Cards only retain bounded display images; full clipboard bytes remain in the model.
@MainActor
struct CardThumbnail: View {
    let item: ClipItem
    @State private var image: NSImage?
    @State private var failed = false
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.fingerprint) { await load() }
    }
    private func load() async {
        image = nil; failed = false
        let key = (item.fingerprint + ":card384") as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        guard let data = AppModel.imageData(item) else { failed = true; return }
        let work = Task.detached(priority: .utility) { try ImageProcessing.thumbnail(data, size: 384) }
        do {
            let png = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            guard let result = NSImage(data: png) else { failed = true; return }
            Self.cache.setObject(result, forKey: key, cost: 384 * 384 * 4)
            image = result
        } catch is CancellationError { }
        catch { failed = true }
    }
}
