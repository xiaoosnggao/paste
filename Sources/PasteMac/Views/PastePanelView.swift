import AppKit
import SwiftUI
import PasteCore

struct PastePanelView: View {
    @ObservedObject var model: AppModel
    @State private var classificationBoard: Pinboard?
    @State private var renamingBoard: UUID?
    @State private var renameText = ""
    @State private var searchFocused = false
    @State private var boardNameFocused: UUID?
    @State private var pendingBoardDeletion: Pinboard?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Color.clear.frame(height: PanelMetrics.toolbarDeckSpacing)
            deck.frame(height: PanelMetrics.deckHeight)
            if model.contextSuggestionsPresented {
                ContextSuggestionsView(model: model)
                    .frame(height: PanelPresentation.suggestionContentHeight + model.suggestionAdditionalHeight)
                    .padding(.top, PanelPresentation.suggestionSpacing)
                    .transition(.opacity)
            }
        }
        .padding(.top, PanelMetrics.panelTopPadding).padding(.bottom, PanelMetrics.panelBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.panelCornerRadius))
        .overlay(alignment: .bottomTrailing) { statusNotice }
        .onChange(of: model.isSearchVisible) { _, visible in searchFocused = visible }
        .onChange(of: model.queryString) { _, _ in model.selectFirstIfNeeded() }
        .onChange(of: model.filter) { _, _ in model.selectFirstIfNeeded() }
        .sheet(item: $classificationBoard) { board in CategoryClassificationSettings(model: model, board: board) }
        .onChange(of: model.selectedPinboardID) { _, _ in model.selectFirstIfNeeded() }
        .confirmationDialog(pendingBoardDeletion.map { "删除收藏夹“\($0.name)”？" } ?? "删除收藏夹？",
                            isPresented: Binding(get: { pendingBoardDeletion != nil }, set: { if !$0 { pendingBoardDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingBoardDeletion) { board in
            Button("删除", role: .destructive) { model.deletePinboard(board.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("其中的卡片仍保留在剪贴板历史中，可按 ⌘Z 撤销。")
        }
    }

    @ViewBuilder private var deck: some View {
            if model.visibleItems.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: PanelMetrics.deckSpacing) {
                            if model.historyPageOffset > 0 {
                                HistoryPagerTile(direction: .newer, loading: false, action: model.loadPreviousHistoryPage)
                                    .disabled(model.historyLoading)
                            }
                            ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, selected: model.selectedIDs.contains(item.id), index: index, categories: model.categories(for: item.id))
                                    .id(item.id)
                                    .onAppear { model.loadDisplayPayload(item.id) }
                                    .onDisappear { model.releaseDisplayPayload(item.id) }
                                    // Select on the first click instead of waiting out the double-click interval.
                                    .onTapGesture(count: 2) { model.activate(item) }
                                    .simultaneousGesture(TapGesture().onEnded { selectOnClick(item) })
                                    .help("单击选择，双击粘贴")
                                    .accessibilityAction { model.select(item) }
                                    .accessibilityAction(named: Text("粘贴")) { model.activate(item) }
                                    .contextMenu { cardMenu(item) }
                                    .draggable(item.id.uuidString)
                                    .dropDestination(for: String.self) { values, _ in
                                        guard let board = model.activePinboard, let moved = values.first.flatMap(UUID.init(uuidString:)), moved != item.id,
                                              board.itemIDs.contains(moved) else { return false }
                                        var order = board.itemIDs.filter { $0 != moved }
                                        guard let target = order.firstIndex(of: item.id) else { return false }
                                        order.insert(moved, at: target)
                                        model.reorderPinboard(board.id, itemIDs: order)
                                        return true
                                    }
                            }
                            if model.historyHasMore {
                                HistoryPagerTile(direction: .older, loading: model.historyLoading) {
                                    if let last = model.historyResultIDs.last { model.loadNextHistoryPage(after: last) }
                                }.disabled(model.historyLoading)
                            }
                        }.padding(.horizontal, PanelMetrics.deckHorizontalPadding).padding(.vertical, PanelMetrics.deckVerticalPadding)
                            .horizontalScrollWheelRouting()
                    }.scrollIndicators(.never)
                        .onChange(of: model.selectedIDs) { _, ids in
                            if let id = ids.first { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) } }
                        }
                }
            }
    }

    /// The persistent failure if there is one, otherwise the transient notice.
    private var visibleNotice: PanelNotice? {
        if let error = model.storageError ?? model.pasteFailureText { return .error(error) }
        return model.notice
    }

    private var statusNotice: some View {
        ZStack {
            if let notice = visibleNotice {
                noticeBanner(notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: visibleNotice)
    }

    private func noticeBanner(_ notice: PanelNotice) -> some View {
        HStack(spacing: 8) {
            if notice == .copied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            } else if case .error = notice {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            Text(notice.text).font(.system(size: 11)).lineLimit(2)
            if model.storageError != nil {
                Button("重试保存", action: model.retrySave).buttonStyle(.plain).foregroundStyle(PanelPalette.accent)
            } else if notice != .copied {
                Button { model.notice = nil; model.pasteIssue = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 22).padding(.bottom, 10)
    }

    private var toolbar: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 140)
            let searchWidth = min(180, available * 0.35)
            let controlsWidth: CGFloat = model.isSearchVisible ? 240 + searchWidth : 192
            let boardWidth = min(620, boardToolbarWidth, max(0, available - controlsWidth))
            ZStack(alignment: .trailing) {
                HStack(spacing: PanelMetrics.toolbarSpacing) {
                    Button { model.usesRecommendations.toggle() } label: {
                        Image(systemName: "sparkles").font(.system(size: 15)).frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize).contentShape(Rectangle())
                    }.buttonStyle(PanelControlStyle(selected: model.usesRecommendations)).focusEffectDisabled().help("按当前应用和最近使用情况推荐")
                    .accessibilityLabel("智能推荐")
                    .accessibilityValue(model.usesRecommendations ? "已开启" : "未开启")
                    Button { model.isSearchVisible.toggle() } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize).contentShape(Rectangle())
                    }.buttonStyle(PanelControlStyle(selected: model.isSearchVisible)).focusEffectDisabled().help("搜索 ⌘F")
                    .accessibilityLabel("搜索")
                    Button { model.performTool(.screenshotOCR) } label: {
                        Label("截图", systemImage: "camera.viewfinder")
                            .font(.system(size: 12, weight: .medium)).frame(width: 64, height: PanelMetrics.controlSize).contentShape(Rectangle())
                    }.buttonStyle(PanelControlStyle()).focusEffectDisabled().help("截图识别")
                    if model.isSearchVisible {
                        PanelInputField(placeholder: "搜索或描述要找的内容", text: $model.queryString, focused: $searchFocused,
                                        onSubmit: model.submitHistorySearch,
                                        onCancel: { model.isSearchVisible = false; model.queryString = ""; searchFocused = false })
                            .padding(.horizontal, 9).frame(width: searchWidth, height: PanelMetrics.controlSize)
                            .modifier(PasteboardInputSurface(focused: searchFocused))
                            .onAppear { searchFocused = true }
                        filterMenu
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            boardPill("剪贴板", id: nil, color: .blue)
                            ForEach(model.snapshot.pinboards) { board in
                                if renamingBoard == board.id {
                                    PanelInputField(placeholder: "名称", text: $renameText,
                                                    focused: Binding(get: { boardNameFocused == board.id },
                                                                     set: { boardNameFocused = $0 ? board.id : nil }),
                                                    onSubmit: { finishRename(board.id) },
                                                    onCancel: { renamingBoard = nil; boardNameFocused = nil })
                                        .padding(.horizontal, 9).frame(width: 115, height: PanelMetrics.controlSize)
                                        .modifier(PasteboardInputSurface(focused: boardNameFocused == board.id))
                                } else {
                                    boardPill(board.name, id: board.id, color: Color(hex: board.colorHex))
                                        .contextMenu {
                                            Button("重命名") { beginRename(board.id, name: board.name) }
                                            Button("自动归类设置…") { classificationBoard = board }
                                            Button("向左移动") { model.movePinboard(board.id, delta: -1) }
                                            Button("向右移动") { model.movePinboard(board.id, delta: 1) }
                                            Button("删除收藏夹…", role: .destructive) { pendingBoardDeletion = board }
                                        }
                                        .dropDestination(for: String.self) { values, _ in
                                            model.selectedIDs = Set(values.compactMap(UUID.init(uuidString:)))
                                            model.pinSelection(to: board.id)
                                            return true
                                        }
                                }
                            }
                        }
                    }.scrollIndicators(.never).frame(width: boardWidth, height: PanelMetrics.controlSize)
                    Button(action: createBoard) {
                        Image(systemName: "plus").frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize).contentShape(Rectangle())
                    }.buttonStyle(PanelControlStyle()).focusEffectDisabled().help("新建收藏夹")
                    .accessibilityLabel("新建收藏夹")
                }.frame(width: min(available, controlsWidth + boardWidth), height: PanelMetrics.toolbarHeight)
                    .frame(maxWidth: .infinity)
                appMenu.padding(.trailing, PanelMetrics.toolbarTrailingPadding)
            }
        }.frame(height: PanelMetrics.toolbarHeight)
    }

    private func createBoard() {
        let existingIDs = Set(model.snapshot.pinboards.map(\.id))
        model.createPinboard(name: "未命名")
        if let board = model.snapshot.pinboards.first(where: { !existingIDs.contains($0.id) }) {
            beginRename(board.id, name: board.name)
        }
    }

    private func beginRename(_ id: UUID, name: String) {
        renameText = name
        renamingBoard = id
        DispatchQueue.main.async { boardNameFocused = id }
    }

    private func finishRename(_ id: UUID) {
        model.renamePinboard(id, name: renameText)
        renamingBoard = nil
        boardNameFocused = nil
    }

    private var boardToolbarWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let clipboardWidth = ("剪贴板" as NSString).size(withAttributes: [.font: font]).width + 26
        let widths = model.snapshot.pinboards.map { board -> CGFloat in
            if renamingBoard == board.id { return 115 }
            return min(160, (board.name as NSString).size(withAttributes: [.font: font]).width + 39)
        }
        return clipboardWidth + widths.reduce(0, +) + CGFloat(widths.count) * 6
    }

    private func boardPill(_ title: String, id: UUID?, color: Color) -> some View {
        let selected = model.selectedPinboardID == id
        return Button { model.selectedPinboardID = id; model.selectedIDs = [] } label: {
            HStack(spacing: 6) {
                if id != nil {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(selected ? Color.white.opacity(0.8) : .clear, lineWidth: 1))
                }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(selected ? PanelPalette.selectionText : PanelPalette.text)
            .padding(.horizontal, 13).frame(height: PanelMetrics.controlSize).frame(maxWidth: 160)
            .background(selected ? PanelPalette.selection : PanelPalette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? PanelPalette.border : PanelPalette.border.opacity(0.45), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).focusEffectDisabled().help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "已选中" : "")
    }

    private var filterMenu: some View {
        Menu {
            Picker("类型", selection: $model.filter.kind) {
                Text("所有类型").tag(Optional<ClipKind>.none)
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName).tag(Optional(kind))
                }
            }.pickerStyle(.menu)
            Picker("应用", selection: $model.filter.sourceBundleID) {
                Text("所有应用").tag(Optional<String>.none)
                ForEach(sources, id: \.sourceBundleID) { item in
                    Text(item.sourceName.isEmpty ? item.sourceBundleID : item.sourceName).tag(Optional(item.sourceBundleID))
                }
            }.pickerStyle(.menu)
            Menu("日期") {
                Button("所有时间") { model.filter.since = nil }
                Button("今天") { model.filter.since = Calendar.current.startOfDay(for: Date()) }
                Button("本周") { model.filter.since = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start }
                Button("最近 7 天") { model.filter.since = Date().addingTimeInterval(-7 * 86400) }
                Button("最近 30 天") { model.filter.since = Date().addingTimeInterval(-30 * 86400) }
            }
            Divider()
            Button("清除筛选", action: clearFilters)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(hasActiveFilter ? PanelPalette.accent : PanelPalette.secondaryText)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize)
        .help("筛选")
        .accessibilityLabel("筛选")
        .accessibilityValue(hasActiveFilter ? "已启用筛选" : "")
    }

    private var sources: [ClipItem] {
        var seen = Set<String>()
        return model.snapshot.items.filter { !$0.sourceBundleID.isEmpty && seen.insert($0.sourceBundleID).inserted }
    }

    private var appMenu: some View {
        Menu {
            Button("新建文本", action: model.newText)
            Button("连续粘贴", action: model.showStack)
            Divider()
            Button("截图识别") { model.performTool(.screenshotOCR) }
            Button("截图翻译") { model.performTool(.screenshotTranslate) }
            Button("输入翻译") { model.performTool(.inputTranslate) }
            Button("剪贴板翻译") { model.performTool(.clipboardTranslate) }
            Button("选中文字翻译") { model.performTool(.selectionTranslate) }
            Divider()
            Button("撤销", action: model.undo)
            Button("重做", action: model.redo)
            Menu("暂停收集") {
                Button("持续暂停") { model.pause(minutes: nil) }
                ForEach([15, 30, 60, 180, 480], id: \.self) { minutes in
                    Button(minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时") { model.pause(minutes: minutes) }
                }
            }
            if model.isPaused { Button("恢复收集", action: model.resume) }
            Divider()
            Button("导出备份…", action: model.exportBackup)
            Button("导入备份…", action: model.importBackup)
            Divider()
            Button("设置…", action: model.openSettings)
        } label: { Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold)).frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize).contentShape(Rectangle()) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize)
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder private func cardMenu(_ item: ClipItem) -> some View {
        Button("粘贴") { ensureSelection(item); model.activateSelected() }
        Button("粘贴为纯文本") { ensureSelection(item); model.activateSelected(plainText: true) }
        Button("复制") { ensureSelection(item); model.copySelected() }
        if let candidates = model.suggestedCategories[item.id], !candidates.isEmpty {
            Menu("建议分类") {
                ForEach(model.snapshot.pinboards.filter { candidates.contains($0.id) }) { board in
                    Button(board.name) { ensureSelection(item); model.pinSelection(to: board.id) }
                }
            }
        }
        Menu("添加到收藏夹") {
            ForEach(model.snapshot.pinboards) { board in
                Button(board.name) { ensureSelection(item); model.pinSelection(to: board.id) }
            }
        }
        if model.selectedPinboardID != nil { Button("从收藏夹移除") { ensureSelection(item); model.unpinSelection() } }
        Divider()
        Button("编辑") { model.edit(item) }.disabled(item.kind == .image || item.kind == .file)
        Button("预览") { model.preview(item) }
        if item.enrichment != nil { Button("识别与翻译详情") { model.showToolItem(item) } }
        if item.kind == .image {
            Button("识别文字") { model.recognizeItem(item) }
            Button("识别并翻译") { model.recognizeItem(item, translateAfter: true) }
        } else if !item.text.isEmpty { Button("翻译") { model.translateItem(item) } }
        if let ocr = item.enrichment?.ocr { Button("复制识别文字") { model.copyToolText(ocr.text) } }
        if let translation = item.enrichment?.translation { Button("复制译文") { model.copyToolText(translation.translatedText) } }
        if item.kind == .image {
            Button("向左旋转") { model.rotateImage(item, clockwise: false) }
            Button("向右旋转") { model.rotateImage(item, clockwise: true) }
        }
        if item.kind == .file || item.kind == .link { Button("打开") { model.openItem(item) } }
        Button("添加到连续粘贴") { ensureSelection(item); model.setStack(model.selectedItems); model.showStack() }
        Divider()
        Button("删除", role: .destructive) { ensureSelection(item); model.deleteSelected() }
    }

    private func selectOnClick(_ item: ClipItem) {
        let flags = NSEvent.modifierFlags
        let extend = flags.contains(.command) || flags.contains(.shift)
        // The AI suggestion bar describes the current multi-selection, and `activate` keeps it intact.
        // A plain click on one of its cards (including the first click of a double-click) must not collapse it.
        if !extend, model.contextSuggestionsPresented, model.selectedIDs.count > 1, model.selectedIDs.contains(item.id) { return }
        model.select(item, extend: extend)
    }

    private func clearFilters() {
        model.filter = ClipFilter()
        model.queryString = ""
    }

    private var hasActiveFilter: Bool {
        model.filter.kind != nil || model.filter.sourceBundleID != nil || model.filter.since != nil
    }

    private func ensureSelection(_ item: ClipItem) {
        if !model.selectedIDs.contains(item.id) { model.select(item) }
    }

    private var emptyState: some View {
        let filtering = !model.queryString.isEmpty || model.filter != ClipFilter()
        let inPinboard = model.selectedPinboardID != nil
        return VStack(spacing: 10) {
            Image(systemName: filtering ? "magnifyingglass" : (inPinboard ? "folder" : "clipboard")).font(.system(size: 35, weight: .light)).foregroundStyle(.secondary)
            Text(filtering ? "未找到匹配卡片" : (inPinboard ? "收藏夹为空" : "暂无剪贴板记录")).font(.headline)
            Text(filtering ? "更换关键词或清除筛选。" : (inPinboard ? "将卡片拖入此收藏夹。" : "复制的内容会显示在这里。")) .font(.subheadline).foregroundStyle(.secondary)
            if filtering {
                Button("清除筛选", action: clearFilters)
                    .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
            }
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let index: Int
    var categories: [Pinboard] = []
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SourceIcon(item: item, selected: selected).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.sourceName.isEmpty ? "剪贴板" : item.sourceName)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.kind.displayName).font(.system(size: 11)).foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(relativeTime(now: context.date)).font(.system(size: 10))
                        .foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText).lineLimit(1)
                }
            }.padding(.horizontal, 12).frame(height: PanelMetrics.cardHeaderHeight).background(selected ? PanelPalette.selection : (hovered ? PanelPalette.hover : PanelPalette.raised))
            VStack(alignment: .leading, spacing: 8) {
                if item.kind == .image {
                    CardThumbnail(item: item)
                        .frame(maxHeight: item.enrichment == nil ? .infinity : 72)
                    if let ocr = item.enrichment?.ocr { Text(ocr.text).font(.system(size: 11)).lineLimit(2) }
                } else if item.kind == .color {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: item.text)).overlay(Text(item.text).font(.system(.title3, design: .monospaced)).shadow(radius: 2))
                } else if item.kind == .file {
                    Image(systemName: "doc.fill").font(.system(size: 36)).foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
                    Text(item.title.isEmpty ? item.filePaths.first ?? "文件" : item.title).font(.system(size: 16, weight: .medium)).lineLimit(3)
                } else {
                    Text(item.text).font(.system(size: 13)).lineSpacing(3).lineLimit(item.enrichment == nil ? 7 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if let translation = item.enrichment?.translation {
                    Text(translation.translatedText).font(.system(size: 11)).lineLimit(2).foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
                }
                if item.enrichment != nil { ClipEnrichmentBadge(item: item) }
                if let category = categories.first {
                    Label(category.name + (categories.count > 1 ? " +\(categories.count - 1)" : ""), systemImage: "folder")
                        .font(.system(size: 10)).foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack {
                    Text(item.kind == .file ? "\(item.filePaths.count) 个文件" : "\(item.enrichment?.ocr?.text.count ?? item.characterCount) 个字符").lineLimit(1)
                    Spacer()
                    if index < 9 { Text("⌘\(index + 1)") }
                }.font(.system(size: 10)).foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
            }.padding(PanelMetrics.cardContentPadding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(selected ? PanelPalette.selection : PanelPalette.surface)
        }.frame(width: PanelMetrics.cardWidth, height: PanelMetrics.cardHeight).foregroundStyle(selected ? PanelPalette.selectionText : PanelPalette.text)
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius).strokeBorder(selected ? PanelPalette.selectionBorder : PanelPalette.border.opacity(hovered ? 0.9 : 0.45),
                                                                        lineWidth: selected ? 2 : (hovered ? 1 : 0.75)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func relativeTime(now: Date) -> String {
        if now.timeIntervalSince(item.lastCopiedAt) < 60 { return "刚刚" }
        return Self.relativeFormatter.localizedString(for: item.lastCopiedAt, relativeTo: now)
    }

    /// Shared by every card; creating a formatter per card on each minute tick is wasteful.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct SourceIcon: View {
    let item: ClipItem
    var selected = false
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.sourceBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: item.kind.symbolName).resizable().scaledToFit().padding(7)
                .foregroundStyle(selected ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
        }
    }
}

extension ClipItem {
    /// VoiceOver summary for a card: kind, source, then a short preview. Empty parts are skipped
    /// so the label never reads as stray separators.
    var accessibilitySummary: String {
        let preview: String
        if !title.isEmpty {
            preview = title
        } else if kind == .file {
            preview = filePaths.first.map { ($0 as NSString).lastPathComponent } ?? ""
        } else {
            let source = kind == .image ? (enrichment?.ocr?.text ?? "") : text
            preview = String(source.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces).prefix(40))
        }
        return [kind.displayName, sourceName, preview].filter { !$0.isEmpty }.joined(separator: "，")
    }

    var previewImage: NSImage? {
        for representation in representations where representation.type.contains("image") || representation.type.contains("png") || representation.type.contains("tiff") || representation.type.contains("jpeg") {
            if let image = NSImage(data: representation.data) { return image }
        }
        return nil
    }
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        let alpha: Double
        if text.count == 8 {
            alpha = Double(UInt8(text.suffix(2), radix: 16) ?? 255) / 255
            text = String(text.prefix(6))
        } else { alpha = 1 }
        let value = UInt64(text, radix: 16) ?? 0x6F81CE
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: alpha)
    }
}

/// Card-height tile at either end of the deck that pages through history,
/// so paging reads as part of the card row instead of a stray form button.
private struct HistoryPagerTile: View {
    enum Direction { case newer, older }
    let direction: Direction
    let loading: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius)
        Button(action: action) {
            VStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: direction == .newer ? "chevron.left" : "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(loading ? "读取中" : (direction == .newer ? "较新" : "更早"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(PanelPalette.secondaryText)
            .frame(width: 72, height: PanelMetrics.cardHeight)
            .background(hovered && isEnabled ? PanelPalette.hover : PanelPalette.surface.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(PanelPalette.border.opacity(hovered && isEnabled ? 0.9 : 0.45), lineWidth: hovered && isEnabled ? 1 : 0.75))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(direction == .newer ? "显示较新的 50 条" : "加载更早的 50 条")
        .accessibilityLabel(direction == .newer ? "显示较新的记录" : "加载更早的记录")
    }
}
