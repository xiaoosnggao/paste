import AppKit
import SwiftUI
import PasteCore

/// The detail layer's smart page: actions on the left, the result on the right.
struct IntelligenceView: View {
    @ObservedObject var model: AppModel
    let itemID: UUID?
    @State private var result = ""
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var availability = IntelligenceService.availability
    private var current: ClipItem? { itemID.flatMap { id in model.snapshot.items.first { $0.id == id } } }
    private var text: String { current?.text ?? "" }
    private var tooLong: Bool { text.count > 2400 }
    var body: some View {
        Group {
            if let item = current {
                PanelDetailScaffold(model: model, item: item, page: .intelligence, title: "智能处理",
                                    showsFooter: busy || !result.isEmpty || error != nil || savedMessage != nil) {
                    HStack(alignment: .top, spacing: PopupMetrics.gap + DesignTokens.Space.xs) {
                        ScrollView { actions.frame(maxWidth: .infinity, alignment: .leading) }
                            .scrollIndicators(.never)
                            .frame(width: 300)
                        resultSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } footer: {
                    footer
                }
            } else {
                PanelDetailScaffold(model: model, item: nil, page: .intelligence, title: "智能处理", showsFooter: false) {
                    ContentUnavailableView("此卡片已删除", systemImage: "trash").frame(maxWidth: .infinity, maxHeight: .infinity)
                } footer: {
                    Spacer()
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                HStack(spacing: DesignTokens.Space.xs) {
                    PopupCardHeader("Apple 智能", symbol: "apple.intelligence")
                    PopupIconButton(symbol: "arrow.clockwise", label: "刷新 Apple 智能状态") { availability = IntelligenceService.availability }
                        .disabled(busy)
                }
                if availability.available {
                    tileGrid(IntelligenceAction.allCases.map { action in
                        Tile(title: action.rawValue, symbol: Self.symbol(action.rawValue), enabled: !busy && !tooLong) { startAI(action) }
                    })
                    if tooLong { note("智能处理最多支持 2400 个字符。请缩短文本后重试。", symbol: "exclamationmark.circle") }
                } else {
                    // Unavailable actions are hidden; this says why.
                    note(availability.message, symbol: "info.circle")
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                PopupCardHeader("文本整理", symbol: "wand.and.rays")
                tileGrid(LocalTextAction.allCases.map { action in
                    Tile(title: action.rawValue, symbol: Self.symbol(action.rawValue), enabled: !busy) { startLocal(action) }
                })
            }
        }
    }

    private func tileGrid(_ tiles: [Tile]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: DesignTokens.Space.sm), GridItem(.flexible(), spacing: DesignTokens.Space.sm)],
                  spacing: DesignTokens.Space.sm) {
            ForEach(tiles) { tile in ActionTile(tile: tile) }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
            Image(systemName: symbol).foregroundStyle(PanelPalette.secondaryText).accessibilityHidden(true)
            Text(text).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .popupCard(padding: DesignTokens.Space.md)
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "摘要": "text.quote"
        case "润色": "wand.and.stars"
        case "提取要点": "list.bullet.rectangle"
        default:
            if name.contains("链接") { "link" }
            else if name.contains("邮") { "envelope" }
            else if name.contains("电话") || name.contains("号码") { "phone" }
            else if name.contains("空") || name.contains("清") { "eraser" }
            else if name.contains("行") { "text.alignleft" }
            else if name.contains("大") || name.contains("小写") { "textformat" }
            else { "sparkle" }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            PopupCardHeader("结果", symbol: "sparkles") {
                if !result.isEmpty {
                    PopupIconButton(symbol: "doc.on.doc", label: "复制结果") { copyResult() }.disabled(busy)
                }
            }
            Group {
                if result.isEmpty {
                    PopupEmptyState(symbol: "sparkles",
                                    title: busy ? "正在处理…" : "选择一个操作开始",
                                    hint: busy ? nil : "结果会显示在这里，可复制或另存为新卡片",
                                    busy: busy)
                } else {
                    ScrollView {
                        Text(result).font(.scaled(.title)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popupCard(padding: DesignTokens.Space.md, tint: PanelPalette.accent)
    }
    @ViewBuilder private var footer: some View {
        footerStatus
        Spacer()
        if busy {
            Button("取消") { task?.cancel(); task = nil; operation = UUID(); busy = false }.popupSecondaryStyle()
        }
        if !result.isEmpty {
            Button("保存结果") {
                if model.saveText(result, title: "处理结果", item: nil) { savedMessage = "结果已保存，相同内容将合并。" }
                else { error = model.statusMessage ?? "保存失败。" }
            }.popupSecondaryStyle().disabled(busy)
            Button("复制结果") { copyResult() }
                .primaryActionStyle()
                .disabled(busy)
        }
    }
    @ViewBuilder private var footerStatus: some View {
        if busy {
            ProgressView().controlSize(.small)
            WindowFooterNote("正在处理…")
        } else if let error {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(error).font(.scaled(.caption)).foregroundStyle(.orange).lineLimit(2).help(error)
        } else if let savedMessage {
            WindowFooterNote(savedMessage)
        }
    }
    private func startAI(_ action: IntelligenceAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do { let output = try await IntelligenceService.run(action, text: text); try Task.checkCancellation(); result = output }
            catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { busy = false }
        }
    }
    private func startLocal(_ action: LocalTextAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do {
                let input = text
                let output = try await Task.detached(priority: .userInitiated) { try TextTools.apply(action, to: input) }.value
                try Task.checkCancellation()
                result = output
                if output.isEmpty { error = "未找到符合条件的内容。" }
            } catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { busy = false }
        }
    }
    private func copyResult() {
        guard !model.isPasting else { return }
        do {
            let value = ClipItem(text: result, kind: .text, representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(result.utf8))])
            try model.bridge.write([value], plainText: true)
            model.statusMessage = "处理结果已复制"
        } catch { self.error = error.localizedDescription }
    }
}

private struct Tile: Identifiable {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    var id: String { title }
}

/// Writing Tools–style tile: symbol over label on a soft card.
private struct ActionTile: View {
    let tile: Tile
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: tile.action) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Image(systemName: tile.symbol).font(.scaled(.title, weight: .medium))
                    .foregroundStyle(PanelPalette.accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous).fill(PanelPalette.accent.opacity(0.12)))
                Text(tile.title).font(.scaled(.label, weight: .semibold)).foregroundStyle(PanelPalette.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Space.md)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(scheme == .dark ? (hovering ? 0.45 : 0.30) : (hovering ? 1 : 0.78))))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(hovering ? PanelPalette.accent.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.05), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .opacity(tile.enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!tile.enabled)
        .onHover { hovering = $0 && tile.enabled }
        .accessibilityLabel(tile.title)
    }
}
