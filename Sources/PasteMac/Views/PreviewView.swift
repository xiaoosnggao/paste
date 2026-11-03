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
        Group {
            if let value = current {
                WindowScaffold(value.title.isEmpty ? value.kind.displayName : value.title,
                               subtitle: "\(value.sourceName) · \(value.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    accessory(value)
                } content: {
                    VStack(alignment: .leading, spacing: WindowMetrics.sectionSpacing) {
                        mainContent(value)
                        if value.kind == .image || value.kind == .text || value.kind == .link {
                            ClipEnrichmentView(model: model, item: value)
                        }
                    }
                } footer: {
                    footer(value)
                }
            } else {
                WindowScaffold("预览") {
                    ContentUnavailableView("此卡片已删除", systemImage: "trash").frame(maxWidth: .infinity, maxHeight: .infinity)
                } footer: {
                    Spacer()
                    WindowCloseButton()
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: current.map { PreviewImageRevision(id: $0.id, representations: $0.representations) }) { await loadThumbnail() }
        .onDisappear { links.cancel() }
        .onChange(of: current?.text) { _, _ in links.reset() }
    }
    private func accessory(_ value: ClipItem) -> some View {
        HStack(spacing: DesignTokens.Space.sm) {
            SourceIcon(item: value).frame(width: 20, height: 20).accessibilityHidden(true)
            if value.kind == .text || value.kind == .link {
                Button("智能处理", systemImage: "sparkles") { model.intelligence(value) }.controlSize(.small)
            }
        }
    }
    @ViewBuilder private func mainContent(_ value: ClipItem) -> some View {
        if value.kind == .image { imageContent(value) }
        else if value.kind == .color {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(Color(hex: value.text)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Text(value.text).font(.system(.largeTitle, design: .monospaced)).shadow(radius: 2))
        } else if value.kind == .file { filesContent(value) }
        else {
            if value.kind == .link { linkContent(value).frame(maxWidth: .infinity, alignment: .leading).windowWell(padding: DesignTokens.Space.sm) }
            ScrollView {
                Text(value.text).font(.scaled(.title)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 96, maxHeight: .infinity)
            .windowWell()
        }
    }
    @ViewBuilder private func footer(_ value: ClipItem) -> some View {
        if value.kind == .image && model.processingImageIDs.contains(value.id) {
            ProgressView().controlSize(.small)
            WindowFooterNote("正在移除背景…")
        } else {
            WindowFooterNote(model.statusMessage ?? "\(value.characterCount) 个字符 · \(value.representations.count) 种数据格式")
        }
        Spacer()
        if value.kind == .image {
            if model.processingImageIDs.contains(value.id) {
                Button("取消") { model.cancelImageProcessing(value.id) }
            } else {
                if value.originalRepresentations != nil {
                    Button("恢复原图", systemImage: "arrow.uturn.backward") { model.restoreImageBackground(value) }
                }
                Button("移除背景", systemImage: "person.crop.rectangle") { model.removeImageBackground(value) }
                    .help("移除背景在本机处理")
            }
        } else if value.kind == .file {
            Button("快速查看", systemImage: "eye") {
                if !QuickLookController.shared.show(urls: value.filePaths.map { URL(fileURLWithPath: $0) }) {
                    model.statusMessage = "无法预览文件，文件可能已移动或删除。"
                }
            }
        }
        WindowCloseButton()
    }
    private func imageContent(_ value: ClipItem) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let imageError { Text(imageError).font(.scaled(.body)).foregroundStyle(PanelPalette.secondaryText) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .windowWell(padding: DesignTokens.Space.sm)
    }
    private func filesContent(_ value: ClipItem) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Space.xs) {
                ForEach(value.filePaths, id: \.self) { path in
                    HStack(spacing: DesignTokens.Space.md) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.scaled(.body, weight: .semibold)).lineLimit(1)
                            Text(path).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer(minLength: DesignTokens.Space.sm)
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, DesignTokens.Space.md).padding(.vertical, DesignTokens.Space.sm)
                    .background(PanelPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
    private func linkContent(_ value: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            if let preview = links.preview {
                Text(preview.title).font(.scaled(.title, weight: .semibold)).lineLimit(2)
                Text(preview.url.host ?? "").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            } else if links.loading {
                HStack(spacing: DesignTokens.Space.sm) {
                    ProgressView().controlSize(.small); Text("正在获取网页信息…").font(.scaled(.label))
                    Button("取消") { links.cancel() }.controlSize(.small)
                }
            } else {
                HStack(spacing: DesignTokens.Space.sm) {
                    Button("加载网页预览", systemImage: "globe") { links.load(value.text) }.controlSize(.small)
                    Text("加载时将连接该网站，不下载图片或其他资源。").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                }
            }
            if let message = links.errorMessage { Text(message).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText) }
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
