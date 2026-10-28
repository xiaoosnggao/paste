import AppKit
import SwiftUI

/// One fixed-height row of suggestion chips under the toolbar. Its height never depends on
/// loading, results or errors, so the panel does not resize while suggestions arrive.
/// Descriptions and the multi-select summary live on the 建议 page (⌘J).
struct SuggestionStripView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            if !model.suggestionStripShowsHint {
                Image(systemName: "sparkles").foregroundStyle(PanelPalette.accent).accessibilityHidden(true)
            }
            ScrollView(.horizontal) {
                HStack(spacing: DesignTokens.Space.xs) { content }
                    .padding(.vertical, 1).horizontalScrollWheelRouting()
            }
            .scrollIndicators(.never)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.displayedSuggestions.map(\.id))
            Spacer(minLength: 0)
            status
            if !model.suggestionStripShowsHint { detailButton }
        }
        .font(.scaled(.label))
        .padding(.horizontal, PanelMetrics.deckHorizontalPadding)
        .frame(height: PanelPresentation.suggestionContentHeight)
        .foregroundStyle(PanelPalette.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 建议")
        .accessibilityValue(model.contextSuggestionsLoading ? "正在生成" : "\(model.displayedSuggestions.count) 项建议")
    }

    private var detailButton: some View {
            Button { model.openPanelDetailForSelection(.suggestions) } label: {
                Text("详情 ⌘J").font(.scaled(.micro, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(PanelPalette.secondaryText).help("查看建议说明与多选摘要 (⌘J)")
    }

    @ViewBuilder private var content: some View {
        let suggestions = model.displayedSuggestions
        if model.selectedIDs.isEmpty {
            Text("选中卡片后显示建议").foregroundStyle(PanelPalette.secondaryText)
        } else if model.suggestionStripShowsHint {
            // Dismissed: the slot keeps its height (no panel jump) and shows a quiet hint.
            Button(action: model.retryContextSuggestions) { Text("✨ ⌘J 建议").font(.scaled(.caption)) }
                .buttonStyle(.plain).foregroundStyle(PanelPalette.secondaryText.opacity(0.7))
                .help("重新显示建议，⌘J 查看详情").accessibilityLabel("重新显示建议")
        } else if suggestions.isEmpty, model.contextSuggestionsLoading {
            Text(model.contextSuggestionProgress ?? "正在生成建议…").foregroundStyle(PanelPalette.secondaryText)
        } else {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionChip(suggestion: suggestion, index: index,
                               applying: model.contextSuggestionApplyingID == suggestion.id,
                               disabled: model.contextSuggestionApplyingID != nil || model.isPasting) {
                    model.applyContextSuggestion(suggestion)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let error = model.contextSuggestionsError {
            Text(error).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .trailing).help(error)
            Button("重试", action: model.retryContextSuggestions).buttonStyle(.plain).foregroundStyle(PanelPalette.accent)
        } else if model.contextSuggestionsLoading, !model.displayedSuggestions.isEmpty {
            ProgressView().controlSize(.mini).help("AI 建议生成中，当前为本地建议")
        }
        if model.contextSuggestionKey != nil {
            Button(action: model.dismissContextSuggestions) { Image(systemName: "xmark").frame(width: 18, height: 22) }
                .buttonStyle(.plain).foregroundStyle(PanelPalette.secondaryText).help("隐藏建议").accessibilityLabel("隐藏建议")
        }
    }
}

private struct SuggestionChip: View {
    let suggestion: ContextSuggestion
    let index: Int
    let applying: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(suggestion.title).lineLimit(1)
                Text(applying ? "处理中" : "⌥\(index + 1)").font(.scaled(.micro, weight: .medium))
                    .foregroundStyle(applying ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
            }
            .foregroundStyle(applying ? PanelPalette.selectionText : PanelPalette.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(applying ? PanelPalette.selection : (hovered ? PanelPalette.hover : PanelPalette.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(suggestion.origin == .rule ? PanelPalette.border.opacity(0.6) : PanelPalette.accent.opacity(0.45), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { hovered = $0 }
        .help(suggestion.detail)
        .accessibilityLabel("\(suggestion.title)，\(suggestion.detail)，处理后粘贴")
    }
}

/// The 建议 page of the detail layer: every suggestion with its description, and the
/// multi-select summary with its facts and sources.
struct SuggestionsDetailPage: View {
    @ObservedObject var model: AppModel
    let itemID: UUID?

    var body: some View {
        PanelDetailScaffold(model: model, item: model.snapshot.items.first { $0.id == itemID } ?? model.selectedItems.first,
                            page: .suggestions, title: "建议", subtitle: subtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                    if model.selectedIDs.count > 1 { multiSummary }
                    if let error = model.contextSuggestionsError {
                        Text(error).foregroundStyle(PanelPalette.secondaryText)
                    }
                    if model.displayedSuggestions.isEmpty {
                        Text(model.contextSuggestionsLoading ? (model.contextSuggestionProgress ?? "正在生成建议…") : "暂无建议。")
                            .foregroundStyle(PanelPalette.secondaryText)
                    }
                    ForEach(Array(model.displayedSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { model.applyContextSuggestion(suggestion) } label: {
                            HStack(alignment: .top, spacing: DesignTokens.Space.md) {
                                Text("⌥\(index + 1)").font(.scaled(.caption, weight: .medium)).foregroundStyle(PanelPalette.secondaryText).frame(width: 28, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.title).font(.scaled(.body, weight: .semibold))
                                    Text(suggestion.detail).font(.scaled(.label)).foregroundStyle(PanelPalette.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if model.contextSuggestionApplyingID == suggestion.id { ProgressView().controlSize(.small) }
                                else if suggestion.origin == .rule { Text("本地").font(.scaled(.micro)).foregroundStyle(PanelPalette.secondaryText) }
                            }
                            .padding(DesignTokens.Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PanelPalette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.contextSuggestionApplyingID != nil || model.isPasting)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            if model.contextSuggestionsLoading { ProgressView().controlSize(.small); Text("AI 建议生成中…").foregroundStyle(PanelPalette.secondaryText) }
            Spacer()
            Button("重新生成", action: model.retryContextSuggestions)
                .disabled(model.contextSuggestionsLoading || model.contextSuggestionApplyingID != nil)
            Button("关闭", action: model.closePanelDetail).keyboardShortcut(.cancelAction)
        }
    }

    private var subtitle: String {
        let target = model.pasteEngine.target?.name ?? "复制到剪贴板"
        if model.selectedIDs.count > 1 { return "已选 \(model.selectedIDs.count) 项 → \(target)" }
        let source = model.selectedItems.first?.sourceName ?? ""
        return "\(source.isEmpty ? "未知来源" : source) → \(target)"
    }

    @ViewBuilder private var multiSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = model.multiCardSummary {
                Text(summary.sentence).font(.scaled(.body, weight: .medium)).textSelection(.enabled)
                ForEach(Array(summary.facts.enumerated()), id: \.offset) { _, fact in
                    Text("• " + readableFact(fact)).font(.scaled(.label)).textSelection(.enabled)
                }
                HStack {
                    ForEach(summary.sourceIDs, id: \.self) { id in
                        if let item = model.snapshot.items.first(where: { $0.id == id }) {
                            Button(item.sourceName.isEmpty ? "查看来源" : item.sourceName) { model.preview(item) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(PanelPalette.accent)
                        }
                    }
                }
            } else {
                Text(model.contextSuggestionsLoading ? (model.contextSuggestionProgress ?? "正在整理所选内容…") : "合并重复信息，保留来源、条件与差异")
                    .font(.caption).foregroundStyle(PanelPalette.secondaryText)
            }
        }
    }

    private func readableFact(_ fact: String) -> String {
        var value = fact
        for item in model.selectedItems {
            value = value.replacingOccurrences(of: "[\(item.id.uuidString)]", with: (item.sourceName.isEmpty ? "来源" : item.sourceName) + "：")
        }
        return value
    }
}
