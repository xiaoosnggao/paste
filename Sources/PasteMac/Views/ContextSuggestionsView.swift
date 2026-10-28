import AppKit
import SwiftUI

/// The 建议 section of the preview window: local rule suggestions at once, AI ones as they
/// stream in, each with its description, plus the multi-select summary. ⌥1–5 apply them.
struct PreviewSuggestionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(spacing: DesignTokens.Space.xs) {
                Label("建议", systemImage: "sparkles").font(.scaled(.label, weight: .semibold)).foregroundStyle(PanelPalette.accent)
                Spacer(minLength: 0)
                if model.contextSuggestionKey != nil || model.contextSuggestionsLoading {
                    RegenerateButton(loading: model.contextSuggestionsLoading, action: model.retryContextSuggestions)
                        .disabled(model.contextSuggestionsLoading || model.contextSuggestionApplyingID != nil)
                }
            }
            if model.suggestionStripShowsHint {
                Button("显示建议", action: model.retryContextSuggestions).buttonStyle(.plain).font(.scaled(.caption)).foregroundStyle(PanelPalette.accent)
            } else {
                if model.selectedIDs.count > 1, let id = model.previewItemID, model.selectedIDs.contains(id) { multiSummary }
                if let error = model.contextSuggestionsError {
                    HStack {
                        Text(error).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                        Button("重试", action: model.retryContextSuggestions).buttonStyle(.plain).font(.scaled(.caption)).foregroundStyle(PanelPalette.accent)
                    }
                }
                if model.displayedSuggestions.isEmpty, model.contextSuggestionsLoading {
                    Text(model.contextSuggestionProgress ?? "正在生成建议…").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                }
                ForEach(Array(model.displayedSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button { model.applyContextSuggestion(suggestion) } label: {
                        HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(.scaled(.label, weight: .semibold)).lineLimit(1)
                                Text(suggestion.detail).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 2) {
                                if model.contextSuggestionApplyingID == suggestion.id { ProgressView().controlSize(.mini) }
                                else { Text("⌥\(index + 1)").font(.scaled(.micro, weight: .medium)).foregroundStyle(PanelPalette.secondaryText) }
                                if suggestion.origin == .rule { Text("本地").font(.scaled(.micro)).foregroundStyle(PanelPalette.secondaryText) }
                            }
                        }
                        .padding(DesignTokens.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PanelPalette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.contextSuggestionApplyingID != nil || model.isPasting)
                    .help("处理后粘贴 (⌥\(index + 1))")
                    .accessibilityLabel("\(suggestion.title)，\(suggestion.detail)，处理后粘贴")
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.displayedSuggestions.map(\.id))
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

/// Subtle refresh icon for the 建议 header; spins while suggestions load.
private struct RegenerateButton: View {
    let loading: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.scaled(.caption, weight: .semibold))
                .foregroundStyle(hovering && !loading ? PanelPalette.text : PanelPalette.secondaryText)
                .rotationEffect(.degrees(loading && !reduceMotion ? 360 : 0))
                .animation(loading && !reduceMotion ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: loading)
                .frame(width: 22, height: 22)
                .background(hovering && !loading ? PanelPalette.hover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(loading ? "AI 建议生成中" : "重新生成")
        .accessibilityLabel("重新生成")
    }
}

extension AppModel {
    /// "Source → target" for the preview title bar: where the clip came from and where paste goes.
    var suggestionRoute: String {
        let target = pasteEngine.target?.name ?? "复制到剪贴板"
        if selectedIDs.count > 1 { return "已选 \(selectedIDs.count) 项 → \(target)" }
        let source = selectedItems.first?.sourceName ?? ""
        return "\(source.isEmpty ? "未知来源" : source) → \(target)"
    }
}
