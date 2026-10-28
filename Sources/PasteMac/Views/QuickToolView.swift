import AppKit
import SwiftUI
import PasteCore

struct QuickToolView: View {
    @ObservedObject var model: AppModel
    /// In the panel's detail layer: no window titlebar, compact sizes, footer in the layer's footer.
    var hosted = false
    @State private var image: NSImage?
    @State private var imageError = false
    @State private var expandedImage = false
    @State private var copied: String?
    @FocusState private var sourceFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var item: ClipItem? { model.activeToolItem }
    private var translation: ClipTranslation? { item?.enrichment?.translation }
    private var dirty: Bool { item != nil && model.toolInputText != model.toolSourceText }
    private var staleTranslation: Bool { model.toolTranslationIsStale }
    private var hasImage: Bool { item?.kind == .image }
    private var paneMinHeight: CGFloat { hosted ? 60 : 130 }

    var body: some View {
        Group {
            if hosted { hostedBody } else { windowBody }
        }
        .background { if #available(macOS 15.0, *) { SystemTranslationHost() } }
        .task(id: item?.fingerprint) { await loadImage() }
        .background(InputFocusOnAppear { if !hasImage { sourceFocused = true } }.frame(width: 0, height: 0))
        .onDisappear { model.cancelAutoTranslation() }
    }

    private var windowBody: some View {
        VStack(spacing: 0) {
            titlebar
            Divider().opacity(0.45)
            VStack(spacing: WindowMetrics.sectionSpacing) {
                services
                if hasImage { imageStrip }
                content
                if let error = model.toolError ?? model.storageError { errorRow(error) }
                footer
            }.padding(WindowMetrics.contentPadding)
        }
        .frame(minWidth: 540, minHeight: 390)
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0))
    }

    private var hostedBody: some View {
        PanelDetailScaffold(model: model, item: item, page: .translate, title: "识别与翻译") {
            VStack(spacing: PopupMetrics.gap) {
                languageBar
                if hasImage { imageStrip }
                hostedPanes
                if let error = model.toolError ?? model.storageError { errorRow(error) }
            }
        } footer: {
            footer
        }
    }

    private static let languages: [(tag: String, title: String)] = [
        ("zh", "简体中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("zh-Hant", "繁体中文"), ("fr", "法语"),
    ]
    private var targetTitle: String {
        Self.languages.first { $0.tag == model.toolConfiguration.targetLanguage }?.title ?? model.toolConfiguration.targetLanguage
    }

    /// Translate-style header: source chip ⇄ target chip, the service on the trailing side.
    private var languageBar: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            LanguageChip(title: "自动检测", symbol: hasImage ? "viewfinder" : "text.magnifyingglass")
                .help(hasImage ? "识别：\(model.toolConfiguration.ocrProviderTitle)" : "自动检测原文语言")
            Button {
                var configuration = model.toolConfiguration
                configuration.targetLanguage = configuration.targetLanguage.hasPrefix("zh") ? "en" : "zh"
                model.toolConfiguration = configuration
            } label: {
                Image(systemName: "arrow.left.arrow.right").font(.scaled(.label, weight: .semibold))
                    .foregroundStyle(PanelPalette.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(PanelPalette.accent.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("在中文与英语之间切换目标语言")
            .accessibilityLabel("切换目标语言")
            Menu {
                Picker("目标语言", selection: $model.toolConfiguration.targetLanguage) {
                    ForEach(Self.languages, id: \.tag) { Text($0.title).tag($0.tag) }
                }.pickerStyle(.inline)
            } label: {
                LanguageChip(title: targetTitle, symbol: nil, accent: true, menu: true)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("目标语言：\(targetTitle)")
            Spacer(minLength: DesignTokens.Space.sm)
            services
            PopupIconButton(symbol: "slider.horizontal.3", label: "服务设置") { model.onSettings?() }
        }
        .frame(height: 32)
    }

    private var hostedPanes: some View {
        HStack(spacing: PopupMetrics.gap) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                PopupCardHeader(hasImage ? "识别文字" : "原文") {
                    if dirty {
                        PopupIconButton(symbol: "checkmark", label: "保存修改") { _ = model.saveToolInput() }
                            .disabled(model.toolBusy)
                    }
                    PopupIconButton(symbol: copied == "source" ? "checkmark" : "doc.on.doc", label: "复制原文") { copy(model.toolInputText, pane: "source") }
                        .disabled(model.toolInputText.isEmpty)
                }
                ZStack(alignment: .topLeading) {
                    if model.toolInputText.isEmpty {
                        Text(hasImage ? "等待识别文字…" : "输入或粘贴文字…")
                            .font(.scaled(.title)).foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    ToolSourceEditor(text: model.toolInputText, focused: $sourceFocused,
                                     label: hasImage ? "识别文字" : "原文") { text, composing in
                        model.editToolInput(text, isComposing: composing)
                    }
                }.frame(maxHeight: .infinity)
                Text("\(model.toolInputText.count) 个字符").font(.scaled(.micro).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popupCard(padding: DesignTokens.Space.md, focused: sourceFocused)

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                PopupCardHeader(staleTranslation ? "译文 · 待更新" : targetTitle) {
                    if staleTranslation {
                        Image(systemName: "arrow.clockwise").font(.scaled(.micro)).foregroundStyle(.orange).help("原文或翻译设置已更改")
                    }
                    PopupIconButton(symbol: copied == "translation" ? "checkmark" : "doc.on.doc", label: "复制译文") {
                        if let translation { copy(translation.translatedText, pane: "translation") }
                    }.disabled(translation == nil)
                }
                if let translation {
                    ScrollView {
                        Text(translation.translatedText).font(.scaled(.title)).lineSpacing(5)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                    Text(shortName(translation.provider)).font(.scaled(.micro)).foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    PopupEmptyState(symbol: "character.bubble",
                                    title: model.toolBusy ? "正在翻译…" : "译文会显示在这里",
                                    hint: model.toolBusy ? nil : "↩ 翻译 · ⇧↩ 换行",
                                    busy: model.toolBusy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popupCard(padding: DesignTokens.Space.md, tint: PanelPalette.accent)
        }
        .frame(maxHeight: .infinity)
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            Text("识别与翻译").font(.scaled(.label, weight: .semibold)).allowsHitTesting(false)
            ToolWindowDragRegion().frame(maxWidth: .infinity).frame(height: WindowMetrics.titleBarHeight)
            if model.isDemo { Text("DEMO").font(.scaled(.micro, weight: .medium)).foregroundStyle(.tertiary) }
            Image(systemName: "lock.shield").font(.scaled(.caption)).foregroundStyle(.tertiary)
                .help("系统服务在本机处理；云服务仅接收当前图片或文字。")
            ToolIconButton(symbol: "slider.horizontal.3", label: "服务设置") { model.onSettings?() }
            ToolIconButton(symbol: model.toolPinned ? "pin.fill" : "pin", label: "固定窗口 ⌘P", active: model.toolPinned) { model.toolPinned.toggle() }
        }.padding(.leading, WindowMetrics.trafficLightInset).padding(.trailing, DesignTokens.Space.md).frame(height: WindowMetrics.titleBarHeight)
    }

    private var services: some View {
        HStack(spacing: 8) {
            // In the panel the toolbar's 截图 and the ⋯ menu already start screenshots.
            if !hosted {
                Menu {
                    Button("截图识别") { model.performTool(.screenshotOCR) }
                    Button("截图翻译") { model.performTool(.screenshotTranslate) }
                } label: {
                    Label("截图翻译", systemImage: "camera.viewfinder").font(.scaled(.label, weight: .medium))
                } primaryAction: { model.performTool(.screenshotTranslate) }
                    .fixedSize().controlSize(.small).help("框选屏幕区域后自动识别并翻译")
                Divider().frame(height: 12)
            }
            if hasImage {
                Menu {
                    Picker("识别服务", selection: ocrSelection) {
                        Section("常规识别") {
                            ForEach(OCRProvider.allCases) { Text($0.title).tag(ToolSelectionItem.builtin($0.rawValue)) }
                        }
                        let aiList = model.toolConfiguration.aiServices.filter { !$0.ocrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.isEnabled }
                        if !aiList.isEmpty {
                            Section("AI 视觉服务") {
                                ForEach(aiList) { service in
                                    Text("\(service.name) (\(service.ocrModel))").tag(ToolSelectionItem.aiService(service.id))
                                }
                            }
                        }
                    }
                } label: {
                    Label(shortName(model.toolConfiguration.ocrProviderTitle), systemImage: "viewfinder")
                        .font(.scaled(.caption, weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 12).padding(.horizontal, 2)
            }
            Menu {
                Picker("翻译服务", selection: translationSelection) {
                    Section("常规翻译") {
                        ForEach(TranslationProvider.allCases) { Text($0.title).tag(ToolSelectionItem.builtin($0.rawValue)) }
                    }
                    let aiList = model.toolConfiguration.aiServices.filter { !$0.translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.isEnabled }
                    if !aiList.isEmpty {
                        Section("AI 服务") {
                            ForEach(aiList) { service in
                                Text("\(service.name) (\(service.translationModel))").tag(ToolSelectionItem.aiService(service.id))
                            }
                        }
                    }
                }
            } label: {
                Label(shortName(model.toolConfiguration.translationProviderTitle), systemImage: "character.bubble")
                    .font(.scaled(.caption, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize()
            if !hosted {
            Spacer(minLength: 8)
            Image(systemName: "arrow.right").font(.scaled(.micro)).foregroundStyle(.tertiary)
            Picker("目标语言", selection: $model.toolConfiguration.targetLanguage) {
                Text("简体中文").tag("zh"); Text("英语").tag("en"); Text("日语").tag("ja")
                Text("韩语").tag("ko"); Text("繁体中文").tag("zh-Hant"); Text("法语").tag("fr")
            }.labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
            }
        }.disabled(model.toolBusy)
    }

    private var imageStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expandedImage.toggle() }
                } label: {
                    thumbnail.frame(width: hosted ? 56 : 84, height: hosted ? 34 : 52).clipped()
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                }.buttonStyle(.plain).help("展开原图")
                    .popover(isPresented: $expandedImage, arrowEdge: .top) {
                        thumbnail.frame(width: 360, height: 240).padding(12)
                    }
                Text("截图").font(.scaled(.label, weight: .medium))
                Spacer(minLength: 4)
                Button("重新识别并翻译") {
                    if let item { model.recognizeItem(item) }
                }
                    .controlSize(.small).disabled(model.toolBusy)
                ToolIconButton(symbol: "doc.on.doc", label: "复制原图") { if let item { model.copyToolOriginal(item) } }
            }
        }.padding(hosted ? 6 : 10)
            .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.3), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.md).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
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
                    Text(hasImage ? "识别文字" : "原文").font(.scaled(.caption, weight: .semibold)).foregroundStyle(.secondary)
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
                            .font(.scaled(.body)).foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    ToolSourceEditor(text: model.toolInputText, focused: $sourceFocused,
                                     label: hasImage ? "识别文字" : "原文") { text, composing in
                        model.editToolInput(text, isComposing: composing)
                    }
                }.frame(minHeight: paneMinHeight, maxHeight: .infinity)
                Text("\(model.toolInputText.count) 个字符").font(.scaled(.micro).monospacedDigit()).foregroundStyle(.tertiary)
            }.padding(hosted ? DesignTokens.Space.sm : 12).frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(staleTranslation ? "译文 · 待更新" : "译文").font(.scaled(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    if staleTranslation {
                        Image(systemName: "arrow.clockwise").font(.scaled(.micro)).foregroundStyle(.orange).help("原文或翻译设置已更改")
                    }
                    Spacer()
                    ToolIconButton(symbol: copied == "translation" ? "checkmark" : "doc.on.doc", label: "复制译文") {
                        if let translation { copy(translation.translatedText, pane: "translation") }
                    }.disabled(translation == nil)
                }.frame(height: 26)
                if let translation {
                    ScrollView {
                        Text(translation.translatedText).font(.scaled(.body)).lineSpacing(5)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: paneMinHeight, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.toolBusy ? "正在处理…" : "等待翻译…")
                            .font(.scaled(.body)).foregroundStyle(.tertiary)
                        if !model.toolBusy {
                            Text("↩ 翻译 · ⇧↩ 换行").font(.scaled(.micro)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }.padding(.top, 7).frame(maxWidth: .infinity, minHeight: paneMinHeight, maxHeight: .infinity, alignment: .topLeading)
                }
                Text(translation.map { shortName($0.provider) } ?? " ")
                    .font(.scaled(.micro)).foregroundStyle(.tertiary).lineLimit(1)
            }.padding(hosted ? DesignTokens.Space.sm : 12).frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.3), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5) }
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(error).font(.scaled(.caption)).fixedSize(horizontal: false, vertical: true).lineLimit(2).help(error)
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
            if let message = dirty ? "原文已修改" : model.toolStatus {
                Text(message).font(.scaled(.micro)).foregroundStyle(.secondary)
                    .lineLimit(1).help(message)
            }
            Spacer(minLength: 8)
            if model.toolBusy {
                Button("取消", action: model.cancelToolOperation).popupSecondaryStyle()
            } else {
                Button { model.translateToolInput() } label: {
                    HStack(spacing: 10) {
                        Text(translation == nil ? "翻译" : "重新翻译")
                        Text("↩").opacity(0.65)
                    }.font(.scaled(.label, weight: .medium)).padding(.horizontal, 5)
                }.primaryActionStyle().disabled(!hasImage && model.toolInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("停止输入0.75秒自动翻译；按回车立即翻译")
            }
        }.frame(minHeight: 32)
    }

    private var ocrSelection: Binding<ToolSelectionItem> {
        Binding(
            get: {
                if let aiID = model.toolConfiguration.ocrAIServiceID {
                    return .aiService(aiID)
                }
                return .builtin(model.toolConfiguration.ocrProvider.rawValue)
            },
            set: { newValue in
                var configuration = model.toolConfiguration
                switch newValue {
                case .builtin(let raw):
                    guard let provider = OCRProvider(rawValue: raw) else { return }
                    configuration.ocrAIServiceID = nil
                    configuration.ocrProvider = provider
                case .aiService(let id):
                    configuration.ocrAIServiceID = id
                }
                model.toolConfiguration = configuration
            }
        )
    }

    private var translationSelection: Binding<ToolSelectionItem> {
        Binding(
            get: {
                if let aiID = model.toolConfiguration.translationAIServiceID {
                    return .aiService(aiID)
                }
                return .builtin(model.toolConfiguration.translationProvider.rawValue)
            },
            set: { newValue in
                var configuration = model.toolConfiguration
                switch newValue {
                case .builtin(let raw):
                    guard let provider = TranslationProvider(rawValue: raw) else { return }
                    configuration.translationAIServiceID = nil
                    configuration.translationProvider = provider
                case .aiService(let id):
                    configuration.translationAIServiceID = id
                }
                model.toolConfiguration = configuration
            }
        )
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
            Image(systemName: symbol).font(.scaled(.label, weight: .medium))
                .foregroundStyle(active ? PanelPalette.accent : PanelPalette.secondaryText)
                .frame(width: 27, height: 27)
                .background((active ? PanelPalette.accent.opacity(0.12) : (hovering ? PanelPalette.hover : Color.clear)), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
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

/// A rounded language chip in the translate header.
private struct LanguageChip: View {
    let title: String
    let symbol: String?
    var accent = false
    var menu = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            if let symbol { Image(systemName: symbol).font(.scaled(.caption, weight: .medium)) }
            Text(title).font(.scaled(.label, weight: .semibold))
            if menu { Image(systemName: "chevron.down").font(.scaled(.micro, weight: .bold)).opacity(0.6) }
        }
        .foregroundStyle(accent ? PanelPalette.accent : PanelPalette.text)
        .padding(.horizontal, DesignTokens.Space.md)
        .frame(height: 30)
        .background(Capsule().fill(accent ? PanelPalette.accent.opacity(0.12) : Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
        .fixedSize()
    }
}
