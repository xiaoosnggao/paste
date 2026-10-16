import AppKit
import SwiftUI
import PasteCore

struct PastePanelView: View {
    @ObservedObject var model: AppModel
    @State private var renamingBoard: UUID?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var boardNameFocused: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Color.clear.frame(height: 17)
            deck.frame(height: 242)
            footer.padding(.top, 4).frame(height: 24)
        }
        .padding(.top, 14).padding(.bottom, 1)
        .frame(maxWidth: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 25))
        .onChange(of: model.isSearchVisible) { _, visible in searchFocused = visible }
        .onChange(of: model.queryString) { _, _ in model.selectFirstIfNeeded() }
        .onChange(of: model.filter) { _, _ in model.selectFirstIfNeeded() }
        .onChange(of: model.selectedPinboardID) { _, _ in model.selectFirstIfNeeded() }
    }

    @ViewBuilder private var deck: some View {
            if model.visibleItems.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, selected: model.selectedIDs.contains(item.id), index: index)
                                    .id(item.id)
                                    .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
                                        switch result {
                                        case .first: model.activate(item)
                                        case .second: model.select(item, extend: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
                                        }
                                    })
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
                        }.padding(.horizontal, 20).padding(.vertical, 5)
                    }.scrollIndicators(.never)
                        .onChange(of: model.selectedIDs) { _, ids in
                            if let id = ids.first { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) } }
                        }
                }
            }
    }

    private var footer: some View {
            HStack(spacing: 8) {
                if model.isDemo { Text("演示模式").foregroundStyle(.orange) }
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1).help(error)
                    Button("重试保存", action: model.retrySave).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                } else if let failure = model.pasteFailureText {
                    Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.orange).lineLimit(1).help(failure)
                    if case .accessibilityPermissionRequired? = model.pasteIssue {
                        Button("设置直接粘贴…", action: model.requestDirectPastePermission)
                            .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(Color.accentColor)
                    }
                } else if model.snapshot.preferences.pasteToFrontmost && !model.directPastePermissionGranted {
                    Label(model.hasCheckedDirectPastePermission ? "直接粘贴未授权" : "使用直接粘贴时将检查权限", systemImage: "info.circle")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button("设置直接粘贴…", action: model.requestDirectPastePermission)
                        .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(Color.accentColor)
                } else {
                    Text(model.statusMessage ?? (model.isPaused ? "剪贴板收集已暂停" : "\(model.visibleItems.count) 个项目"))
                }
                Spacer()
                ViewThatFits(in: .horizontal) {
                    Text("单击选择 · 双击或 ↩ 粘贴    ⇧↩ 纯文本    ⌘1–9 快速粘贴")
                    Text("双击或 ↩ 粘贴")
                    Color.clear.frame(width: 0, height: 0)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22)
    }

    private var toolbar: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 140)
            let searchWidth = min(180, available * 0.35)
            let controlsWidth: CGFloat = model.isSearchVisible ? 240 + searchWidth : 192
            let boardWidth = min(620, boardToolbarWidth, max(0, available - controlsWidth))
            ZStack {
                HStack(spacing: 8) {
                    Button { model.usesRecommendations.toggle() } label: {
                        Image(systemName: "sparkles").font(.system(size: 15)).frame(width: 32, height: 32).contentShape(Rectangle())
                            .foregroundStyle(model.usesRecommendations ? Color.accentColor : Color.primary)
                    }.buttonStyle(.plain).focusEffectDisabled().help("按当前应用和最近使用情况推荐")
                    Button { model.isSearchVisible.toggle() } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).focusEffectDisabled().help("搜索 ⌘F")
                    Button { model.performTool(.screenshotOCR) } label: {
                        Label("截图", systemImage: "camera.viewfinder")
                            .font(.system(size: 12, weight: .medium)).frame(width: 64, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).focusEffectDisabled().help("截图识别")
                    if model.isSearchVisible {
                        TextField("搜索剪贴板", text: $model.queryString)
                            .textFieldStyle(.plain).focused($searchFocused).frame(width: searchWidth, height: 32)
                            .onSubmit { model.activateSelected(plainText: NSEvent.modifierFlags.contains(.shift)) }
                            .onExitCommand { model.isSearchVisible = false; model.queryString = ""; searchFocused = false }
                        filterMenu
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            boardPill("剪贴板", id: nil, color: .blue)
                            ForEach(model.snapshot.pinboards) { board in
                                if renamingBoard == board.id {
                                    TextField("名称", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 115, height: 32)
                                        .focused($boardNameFocused, equals: board.id)
                                        .onSubmit { finishRename(board.id) }
                                        .onExitCommand { renamingBoard = nil; boardNameFocused = nil }
                                } else {
                                    boardPill(board.name, id: board.id, color: Color(hex: board.colorHex))
                                        .contextMenu {
                                            Button("重命名") { beginRename(board.id, name: board.name) }
                                            Button("向左移动") { model.movePinboard(board.id, delta: -1) }
                                            Button("向右移动") { model.movePinboard(board.id, delta: 1) }
                                            Button("删除收藏夹", role: .destructive) { model.deletePinboard(board.id) }
                                        }
                                        .dropDestination(for: String.self) { values, _ in
                                            model.selectedIDs = Set(values.compactMap(UUID.init(uuidString:)))
                                            model.pinSelection(to: board.id)
                                            return true
                                        }
                                }
                            }
                        }
                    }.scrollIndicators(.never).frame(width: boardWidth, height: 32)
                    Button(action: createBoard) {
                        Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).focusEffectDisabled().help("新建收藏夹")
                }.frame(width: min(available, controlsWidth + boardWidth), height: 32)
                HStack { Spacer(); appMenu }.padding(.horizontal, 22)
            }
        }.frame(height: 32)
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
        Button { model.selectedPinboardID = id; model.selectedIDs = [] } label: {
            HStack(spacing: 6) {
                if id != nil { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }.padding(.horizontal, 13).frame(height: 32).frame(maxWidth: 160)
                .background(model.selectedPinboardID == id ? Color.white.opacity(0.19) : Color.clear, in: Capsule())
        }.buttonStyle(.plain).focusEffectDisabled().help(title)
    }

    private var filterMenu: some View {
        Menu {
            Menu("类型") {
                Button("所有类型") { model.filter.kind = nil }
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Button { model.filter.kind = kind } label: { Label(kind.displayName, systemImage: kind.symbolName) }
                }
            }
            Menu("应用") {
                Button("所有应用") { model.filter.sourceBundleID = nil }
                ForEach(sources, id: \.sourceBundleID) { item in
                    Button(item.sourceName.isEmpty ? item.sourceBundleID : item.sourceName) { model.filter.sourceBundleID = item.sourceBundleID }
                }
            }
            Menu("日期") {
                Button("所有时间") { model.filter.since = nil }
                Button("今天") { model.filter.since = Calendar.current.startOfDay(for: Date()) }
                Button("本周") { model.filter.since = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start }
                Button("最近 7 天") { model.filter.since = Date().addingTimeInterval(-7 * 86400) }
                Button("最近 30 天") { model.filter.since = Date().addingTimeInterval(-30 * 86400) }
            }
            Divider()
            Button("清除筛选") { model.filter = ClipFilter(); model.queryString = "" }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(model.filter.kind != nil || model.filter.sourceBundleID != nil || model.filter.since != nil ? Color.blue : Color.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().frame(width: 32, height: 32)
    }

    private var sources: [ClipItem] {
        var seen = Set<String>()
        return model.snapshot.items.filter { !$0.sourceBundleID.isEmpty && seen.insert($0.sourceBundleID).inserted }
    }

    private var appMenu: some View {
        Menu {
            Button("新建文本", action: model.newText)
            Button("Paste Stack", action: model.showStack)
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
        } label: { Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold)).frame(width: 32, height: 32).contentShape(Rectangle()) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().frame(width: 32, height: 32)
    }

    @ViewBuilder private func cardMenu(_ item: ClipItem) -> some View {
        Button("粘贴") { ensureSelection(item); model.activateSelected() }
        Button("粘贴为纯文本") { ensureSelection(item); model.activateSelected(plainText: true) }
        Button("复制") { ensureSelection(item); model.copySelected() }
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

    private func ensureSelection(_ item: ClipItem) {
        if !model.selectedIDs.contains(item.id) { model.select(item) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.queryString.isEmpty ? "clipboard" : "magnifyingglass").font(.system(size: 35, weight: .light)).foregroundStyle(.secondary)
            Text(model.queryString.isEmpty && model.filter == ClipFilter() ? "暂无剪贴板记录" : "未找到匹配项目").font(.headline)
            Text("复制文本、图片、链接或文件后，将自动保存到此处。") .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let index: Int
    private var tint: Color {
        switch item.sourceBundleID {
        case "com.apple.Notes": return Color(red: 0.82, green: 0.62, blue: 0.15)
        case "com.apple.Safari", "com.google.Chrome": return Color(red: 0.24, green: 0.52, blue: 0.95)
        case "com.openai.chat": return Color(red: 0.03, green: 0.06, blue: 0.20)
        case "com.apple.iWork.Pages": return Color(red: 0.92, green: 0.48, blue: 0.12)
        case "com.apple.dt.Xcode": return Color(red: 0.15, green: 0.49, blue: 0.77)
        default: break
        }
        switch item.kind {
        case .image: return Color(red: 0.40, green: 0.36, blue: 0.71)
        case .link: return Color(red: 0.17, green: 0.53, blue: 0.78)
        case .color: return Color(hex: item.text)
        case .file: return Color(red: 0.70, green: 0.47, blue: 0.25)
        default: return Color(red: 0.34, green: 0.55, blue: 0.49)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.kind.displayName).font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(relativeTime(now: context.date)).font(.system(size: 11)).opacity(0.8)
                    }
                }
                Spacer()
                SourceIcon(item: item).frame(width: 56, height: 56).padding(.trailing, -7)
            }.padding(.leading, 13).frame(height: 48).background(tint).clipped()
            VStack(alignment: .leading, spacing: 8) {
                if item.kind == .image {
                    CardThumbnail(item: item)
                        .frame(maxHeight: item.enrichment == nil ? .infinity : 72)
                    if let ocr = item.enrichment?.ocr { Text(ocr.text).font(.system(size: 11)).lineLimit(2) }
                } else if item.kind == .color {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: item.text)).overlay(Text(item.text).font(.system(.title3, design: .monospaced)).shadow(radius: 2))
                } else if item.kind == .file {
                    Image(systemName: "doc.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
                    Text(item.title.isEmpty ? item.filePaths.first ?? "文件" : item.title).font(.system(size: 16, weight: .medium)).lineLimit(3)
                } else {
                    Text(item.text).font(.system(size: 13)).lineSpacing(3).lineLimit(item.enrichment == nil ? 7 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if let translation = item.enrichment?.translation {
                    Text(translation.translatedText).font(.system(size: 11)).lineLimit(2).foregroundStyle(.white.opacity(0.8))
                }
                if item.enrichment != nil { ClipEnrichmentBadge(item: item) }
                Spacer(minLength: 0)
                HStack {
                    Text(item.kind == .file ? "\(item.filePaths.count) 个文件" : "\(item.enrichment?.ocr?.text.count ?? item.characterCount) 个字符").lineLimit(1)
                    Spacer()
                    if index < 9 { Text("⌘\(index + 1)") }
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.065))
        }.frame(width: 230, height: 232).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 3 : 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.kind.displayName)，\(item.sourceName)，\(item.title)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func relativeTime(now: Date) -> String {
        if now.timeIntervalSince(item.lastCopiedAt) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: item.lastCopiedAt, relativeTo: now)
    }
}

struct SourceIcon: View {
    let item: ClipItem
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.sourceBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: item.kind.symbolName).resizable().scaledToFit().padding(7).foregroundStyle(.white.opacity(0.9))
        }
    }
}

extension ClipItem {
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
