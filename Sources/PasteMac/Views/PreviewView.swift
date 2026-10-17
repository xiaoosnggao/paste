import AppKit
import SwiftUI
import PasteCore

private struct PreviewImageRevision: Hashable {
    let id: UUID
    let representations: [PasteboardRepresentation]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.representations == rhs.representations }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PreviewView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @StateObject private var links = LinkPreviewService()
    @State private var image: NSImage?
    @State private var imageError: String?
    private var current: ClipItem? { model.snapshot.items.first { $0.id == item.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let value = current {
                header(value)
                Divider()
                if value.kind == .image { imageContent(value) }
                else if value.kind == .color {
                    RoundedRectangle(cornerRadius: 20).fill(Color(hex: value.text)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(Text(value.text).font(.system(.largeTitle, design: .monospaced)).shadow(radius: 2))
                } else if value.kind == .file { filesContent(value) }
                else {
                    if value.kind == .link { linkContent(value) }
                    ScrollView { Text(value.text).font(.system(size: 16)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if value.kind == .image || value.kind == .text || value.kind == .link {
                    ClipEnrichmentView(model: model, item: value)
                }
                if let status = model.statusMessage { Text(status).font(.caption).foregroundStyle(.secondary) }
                Text("\(value.characterCount) 个字符 · \(value.representations.count) 种数据格式").font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("此卡片已删除", systemImage: "trash") }
        }
        .padding(24).frame(minWidth: 560, minHeight: 420)
        .task(id: current.map { PreviewImageRevision(id: $0.id, representations: $0.representations) }) { await loadThumbnail() }
        .onDisappear { links.cancel() }
        .onChange(of: current?.text) { _, _ in links.reset() }
    }
    private func header(_ value: ClipItem) -> some View {
        HStack(spacing: 12) {
            SourceIcon(item: value).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.title.isEmpty ? value.kind.displayName : value.title).font(.headline).lineLimit(2)
                Text("\(value.sourceName) · \(value.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if value.kind == .text || value.kind == .link {
                Button("智能处理", systemImage: "sparkles") { model.intelligence(value) }
            }
        }
    }
    private func imageContent(_ value: ClipItem) -> some View {
        VStack(spacing: 12) {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let imageError { Text(imageError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack {
                if model.processingImageIDs.contains(value.id) {
                    ProgressView().controlSize(.small)
                    Text("正在移除背景…")
                    Button("取消") { model.cancelImageProcessing(value.id) }
                } else {
                    Button("移除背景", systemImage: "person.crop.rectangle") { model.removeImageBackground(value) }
                    if value.originalRepresentations != nil {
                        Button("恢复原图", systemImage: "arrow.uturn.backward") { model.restoreImageBackground(value) }
                    }
                }
                Spacer()
                Text("移除背景在本机处理").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func filesContent(_ value: ClipItem) -> some View {
        VStack(alignment: .leading) {
            Button("快速查看", systemImage: "eye") {
                if !QuickLookController.shared.show(urls: value.filePaths.map { URL(fileURLWithPath: $0) }) {
                    model.statusMessage = "无法预览文件，文件可能已移动或删除。"
                }
            }
            List(value.filePaths, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
        }
    }
    private func linkContent(_ value: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = links.preview {
                Text(preview.title).font(.title3)
                Text(preview.url.host ?? "").font(.caption).foregroundStyle(.secondary)
            } else if links.loading {
                HStack { ProgressView().controlSize(.small); Text("正在获取网页信息…"); Button("取消") { links.cancel() } }
            } else {
                Button("加载网页预览", systemImage: "globe") { links.load(value.text) }
                Text("加载时将连接该网站，不下载图片或其他资源。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = links.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    @MainActor
    private func loadThumbnail() async {
        image = nil; imageError = nil
        guard let value = current, value.kind == .image, let data = AppModel.imageData(value) else { return }
        let work = Task.detached(priority: .utility) { try ImageProcessing.thumbnail(data) }
        do {
            let png = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            image = NSImage(data: png)
        } catch is CancellationError { }
        catch { imageError = error.localizedDescription }
    }
}
