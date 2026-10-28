import AppKit
import SwiftUI
import PasteCore

private struct PreviewImageRevision: Hashable {
    let id: UUID
    let representations: [PasteboardRepresentation]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.representations == rhs.representations }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The preview window. It opens above the panel and follows ← and →;
/// editing, translation and smart processing open in the panel from its buttons.
struct PreviewWindowView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // A fresh view per card resets the image and link state.
        PreviewView(model: model, itemID: model.previewItemID).id(model.previewItemID)
    }
}

struct PreviewView: View {
    @ObservedObject var model: AppModel
    let itemID: UUID?
    @StateObject private var links = LinkPreviewService()
    @State private var image: NSImage?
    @State private var imageError: String?
    private var current: ClipItem? { itemID.flatMap { id in model.snapshot.items.first { $0.id == id } } }
    var body: some View {
        Group {
            if let value = current {
                WindowScaffold(value.title.isEmpty ? value.kind.displayName : value.title,
                               subtitle: "\(value.sourceName) · \(value.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    accessory(value)
                } content: {
                    HStack(alignment: .top, spacing: DesignTokens.Space.lg) {
                        mainContent(value).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // Results only; the actions that create them live in the ⋯ menu.
                        let enriched = value.enrichment?.ocr != nil || value.enrichment?.translation != nil
                        if enriched || model.suggestionStripAvailable {
                            ScrollView {
                                VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
                                    if model.suggestionStripAvailable { PreviewSuggestionsSection(model: model) }
                                    if enriched { ClipEnrichmentView(model: model, item: value).controlSize(.small) }
                                }
                            }
                            .scrollIndicators(.automatic)
                            .frame(width: 300)
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
    /// Source, list navigation and the jumps to the panel's pages.
    private func accessory(_ value: ClipItem) -> some View {
        let items = model.visibleItems
        let index = items.firstIndex { $0.id == value.id }
        return HStack(spacing: DesignTokens.Space.sm) {
            HStack(spacing: 0) {
                PopupIconButton(symbol: "chevron.left", label: "上一张 (←)") { model.movePreview(-1) }
                    .disabled(index.map { $0 == 0 } ?? true)
                PopupIconButton(symbol: "chevron.right", label: "下一张 (→)") { model.movePreview(1) }
                    .disabled(index.map { $0 >= items.count - 1 } ?? true)
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            moreMenu(value)
        }
    }
    /// Everything beyond paste and copy: the panel pages, recognition and image or file tools.
    private func moreMenu(_ value: ClipItem) -> some View {
        Menu {
            Section("打开") {
                ForEach(PanelDetailPage.layerPages.filter { $0.isAvailable(for: value) }) { page in
                    Button("\(page.title) (\(page.shortcutLabel))", systemImage: page.systemImage) { model.openFromPreview(page, item: value) }
                }
            }
            if value.kind == .image || !value.text.isEmpty, value.kind != .file, value.kind != .color {
                Section(ClipEnrichmentView.disclosure(for: value, model: model)) {
                    if value.kind == .image {
                        Button("识别文字", systemImage: "text.viewfinder") { model.recognizeItem(value) }
                        Button("识别并翻译", systemImage: "character.bubble") { model.recognizeItem(value, translateAfter: true) }
                    } else {
                        Button("翻译", systemImage: "character.bubble") { model.translateItem(value) }
                    }
                    if value.enrichment != nil {
                        Button("打开识别与翻译", systemImage: "arrow.up.forward.app") { model.showToolItem(value) }
                    }
                }
            }
            if value.kind == .image && !model.processingImageIDs.contains(value.id) {
                Section {
                    Button("移除背景（本机处理）", systemImage: "person.crop.rectangle") { model.removeImageBackground(value) }
                    if value.originalRepresentations != nil {
                        Button("恢复原图", systemImage: "arrow.uturn.backward") { model.restoreImageBackground(value) }
                    }
                }
            }
            if value.kind == .file {
                Button("快速查看", systemImage: "eye") {
                    if !QuickLookController.shared.show(urls: value.filePaths.map { URL(fileURLWithPath: $0) }) {
                        model.statusMessage = "无法预览文件，文件可能已移动或删除。"
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多操作").accessibilityLabel("更多操作")
    }
    private func footerNote(_ value: ClipItem) -> String {
        if let message = model.statusMessage { return message }
        switch value.kind {
        case .image: return value.enrichment?.ocr.map { "已识别 \($0.text.count) 个字符" } ?? "图片"
        case .file: return "\(value.filePaths.count) 个文件"
        case .color: return value.text
        default: return "\(value.characterCount) 个字符"
        }
    }
    @ViewBuilder private func mainContent(_ value: ClipItem) -> some View {
        if value.kind == .image { imageContent(value) }
        else if value.kind == .color {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(Color(hex: value.text)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Text(value.text).font(.system(.largeTitle, design: .monospaced)).shadow(radius: 2))
        } else if value.kind == .file { filesContent(value) }
        else {
            // Stacked: the link card sits above the URL, not beside it.
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                if value.kind == .link { linkContent(value).frame(maxWidth: .infinity, alignment: .leading).windowWell(padding: DesignTokens.Space.sm) }
                ScrollView {
                    Text(value.text).font(.scaled(.title)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 72, maxHeight: .infinity)
                .popupCard()
            }
        }
    }
    @ViewBuilder private func footer(_ value: ClipItem) -> some View {
        if value.kind == .image && model.processingImageIDs.contains(value.id) {
            ProgressView().controlSize(.small)
            WindowFooterNote("正在移除背景…")
        } else {
            SourceIcon(item: value).frame(width: 18, height: 18).accessibilityHidden(true)
            WindowFooterNote("\(value.sourceName) · \(value.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(footerNote(value))")
        }
        Spacer()
        if value.kind == .image && model.processingImageIDs.contains(value.id) {
            Button("取消") { model.cancelImageProcessing(value.id) }.popupSecondaryStyle()
        }
        Button("复制") { model.select(value); model.copySelected() }.popupSecondaryStyle()
        Button("粘贴") { model.activate(value) }
            .windowPrimaryAction()
            .help("粘贴到当前应用 (↩)")
    }
    private func imageContent(_ value: ClipItem) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let imageError { Text(imageError).font(.scaled(.body)).foregroundStyle(PanelPalette.secondaryText) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity)
        .popupCard(padding: DesignTokens.Space.sm)
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
                    .background(PanelPalette.raised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
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
