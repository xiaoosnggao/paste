import AppKit
import SwiftUI
import PasteCore

struct QuickToolView: View {
    @ObservedObject var model: AppModel
    @State private var image: NSImage?
    @State private var imageError = false
    @State private var expandedImage = false
    @State private var copied: String?
    @FocusState private var sourceFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var item: ClipItem? { model.activeToolItem }
    private var translation: ClipTranslation? { item?.enrichment?.translation }
    private var dirty: Bool { item != nil && model.toolInputText != model.toolSourceText }
    private var staleTranslation: Bool { translation.map { $0.sourceText != model.toolInputText } ?? false }
    private var hasImage: Bool { item?.kind == .image }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Divider().opacity(0.5)
            VStack(spacing: 12) {
                services
                if hasImage { imageStrip }
                content
                if let error = model.toolError ?? model.storageError { errorRow(error) }
                footer
            }.padding(16)
        }
        .frame(minWidth: 540, minHeight: 390)
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
        .background { if #available(macOS 15.0, *) { SystemTranslationHost() } }
        .task(id: item?.fingerprint) { await loadImage() }
        .onAppear { if !hasImage { sourceFocused = true } }
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            Text("识别与翻译").font(.system(size: 12, weight: .semibold)).allowsHitTesting(false)
            ToolWindowDragRegion().frame(maxWidth: .infinity).frame(height: 38)
            if model.isDemo { Text("DEMO").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary) }
            Image(systemName: "lock.shield").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("系统服务在本机处理。云服务仅接收当前图片或文字。原始内容与结果分别保存为卡片。")
            ToolIconButton(symbol: "slider.horizontal.3", label: "服务设置") { model.onSettings?() }
            ToolIconButton(symbol: model.toolPinned ? "pin.fill" : "pin", label: "固定窗口 ⌘P", active: model.toolPinned) { model.toolPinned.toggle() }
        }.padding(.leading, 76).padding(.trailing, 10).frame(height: 38)
    }

    private var services: some View {
        HStack(spacing: 8) {
            Menu {
                Button("截图识别") { model.performTool(.screenshotOCR) }
                Button("截图翻译") { model.performTool(.screenshotTranslate) }
            } label: {
                Label("截图", systemImage: "camera.viewfinder").font(.system(size: 12, weight: .medium))
            } primaryAction: { model.performTool(.screenshotOCR) }
                .fixedSize().controlSize(.small).help("框选屏幕区域以识别文字，也可在菜单中选择截图翻译")
            Divider().frame(height: 12)
            if hasImage {
                Menu {
                    Picker("识别服务", selection: $model.toolConfiguration.ocrProvider) {
                        ForEach(OCRProvider.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(shortName(model.toolConfiguration.ocrProviderTitle), systemImage: "viewfinder")
                        .font(.system(size: 11, weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 12).padding(.horizontal, 2)
            }
            Menu {
                Picker("翻译服务", selection: $model.toolConfiguration.translationProvider) {
                    ForEach(TranslationProvider.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(shortName(model.toolConfiguration.translationProviderTitle), systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: 8)
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            Picker("目标语言", selection: $model.toolConfiguration.targetLanguage) {
                Text("简体中文").tag("zh"); Text("英语").tag("en"); Text("日语").tag("ja")
                Text("韩语").tag("ko"); Text("繁体中文").tag("zh-Hant"); Text("法语").tag("fr")
            }.labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
        }.disabled(model.toolBusy)
    }

    private var imageStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expandedImage.toggle() }
                } label: {
                    thumbnail.frame(width: 84, height: 52).clipped()
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help("展开原图")
                    .popover(isPresented: $expandedImage, arrowEdge: .top) {
                        thumbnail.frame(width: 360, height: 240).padding(12)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("截图").font(.system(size: 12, weight: .medium))
                    Text("原图与识别文字分别保存")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("重新识别") { if let item { model.recognizeItem(item) } }
                    .controlSize(.small).disabled(model.toolBusy)
                ToolIconButton(symbol: "doc.on.doc", label: "复制原图") { if let item { model.copyToolOriginal(item) } }
            }
        }.padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var thumbnail: some View {
        if let image { Image(nsImage: image).resizable().scaledToFit() }
        else if imageError { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
        else { ProgressView().controlSize(.small) }
    }

    private var content: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(hasImage ? "识别文字" : "原文").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if dirty {
                        ToolIconButton(symbol: "checkmark", label: "保存修改") { _ = model.saveToolInput() }
                            .disabled(model.toolBusy)
                    }
                    ToolIconButton(symbol: copied == "source" ? "checkmark" : "doc.on.doc", label: "复制原文") { copy(model.toolInputText, pane: "source") }
                        .disabled(model.toolInputText.isEmpty)
                }.frame(height: 26)
                ZStack(alignment: .topLeading) {
                    if model.toolInputText.isEmpty {
                        Text(hasImage ? "等待识别文字…" : "输入或粘贴文字…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.toolInputText)
                        .font(.system(size: 14)).lineSpacing(5).scrollContentBackground(.hidden)
                        .focused($sourceFocused).disabled(model.toolBusy)
                        .accessibilityLabel(hasImage ? "识别文字" : "原文")
                }.frame(minHeight: 130, maxHeight: .infinity)
                Text("\(model.toolInputText.count) 个字符").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }.padding(12).frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
            Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(staleTranslation ? "译文 · 原文已修改" : "译文").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if staleTranslation {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(.orange).help("原文已修改，需重新翻译")
                    }
                    Spacer()
                    ToolIconButton(symbol: copied == "translation" ? "checkmark" : "doc.on.doc", label: "复制译文") {
                        if let translation { copy(translation.translatedText, pane: "translation") }
                    }.disabled(translation == nil)
                }.frame(height: 26)
                if let translation {
                    ScrollView {
                        Text(translation.translatedText).font(.system(size: 14)).lineSpacing(5)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 130, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.toolBusy ? "正在处理…" : "等待翻译…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                        if !model.toolBusy {
                            Text("↩ 翻译 · ⇧↩ 换行").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }.padding(.top, 7).frame(maxWidth: .infinity, minHeight: 130, maxHeight: .infinity, alignment: .topLeading)
                }
                Text(translation.map { shortName($0.provider) } ?? " ")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }.padding(12).frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 1) }
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).lineLimit(2).help(error)
            Spacer(minLength: 4)
            Button(model.toolError == nil ? "重试保存" : "重试") {
                if model.toolError == nil { model.retrySave() } else { model.retryToolOperation() }
            }.controlSize(.small).disabled(model.toolBusy)
            ToolIconButton(symbol: "gearshape", label: "服务设置") { model.onSettings?() }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.toolBusy { ProgressView().controlSize(.mini) }
            else { Image(systemName: "square.stack").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Text(dirty ? "原文已修改，翻译后自动保存" : (model.toolStatus ?? "原始内容与结果分别保存"))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(model.toolStatus ?? "原始内容与结果分别保存为卡片")
            Spacer(minLength: 8)
            if model.toolBusy {
                Button("取消", action: model.cancelToolOperation).controlSize(.regular)
            } else {
                Button { model.translateToolInput() } label: {
                    HStack(spacing: 10) {
                        Text(translation == nil ? "翻译" : "重新翻译")
                        Text("↩").opacity(0.65)
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.toolInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.frame(minHeight: 32)
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "系统 OCR（本机）", with: "Apple 识别")
            .replacingOccurrences(of: "系统翻译", with: "Apple 翻译")
            .replacingOccurrences(of: "OpenAI 兼容", with: "OpenAI")
            .replacingOccurrences(of: "Google Cloud Vision", with: "Google Vision")
    }
    private func copy(_ text: String, pane: String) {
        model.copyToolText(text); copied = pane
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copied == pane { copied = nil }
        }
    }
    private func loadImage() async {
        image = nil; imageError = false; expandedImage = false
        guard let item, let data = AppModel.imageData(item) else { return }
        let task = Task.detached(priority: .utility) { try ImageProcessing.thumbnail(data, size: 640) }
        do {
            let png = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation(); image = NSImage(data: png)
        } catch is CancellationError { }
        catch { imageError = true }
    }
}

private struct ToolIconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 27, height: 27)
                .background((active ? Color.accentColor.opacity(0.1) : Color.primary.opacity(hovering ? 0.06 : 0)), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
            .onHover { hovering = $0 }
    }
}

private struct ToolWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
