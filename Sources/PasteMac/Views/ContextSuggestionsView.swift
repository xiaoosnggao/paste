import AppKit
import SwiftUI

struct ContextSuggestionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedIDs.count > 1 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("已选 \(model.selectedIDs.count) 项").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if model.contextSuggestionsLoading {
                            Text(model.contextSuggestionProgress ?? "正在整理所选内容…").font(.caption).foregroundStyle(PanelPalette.secondaryText)
                            Button("取消", action: model.dismissContextSuggestions).buttonStyle(.plain)
                        }
                    }
                    if let summary = model.multiCardSummary {
                        Text(summary.sentence).font(.system(size: 13)).lineLimit(2)
                        Button(model.multiCardSummaryExpanded ? "收起要点" : "展开要点") {
                            model.multiCardSummaryExpanded.toggle()
                        }.buttonStyle(.plain).foregroundStyle(PanelPalette.accent).font(.caption)
                        ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(summary.facts.enumerated()), id: \.offset) { _, fact in
                                        Text("• " + readableFact(fact)).font(.system(size: 12)).textSelection(.enabled)
                                    }
                                    HStack {
                                        ForEach(summary.sourceIDs, id: \.self) { id in
                                            if let item = model.snapshot.items.first(where: { $0.id == id }) {
                                                Button(item.sourceName.isEmpty ? "查看来源" : item.sourceName) { model.preview(item) }
                                                    .buttonStyle(.plain).font(.caption)
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: model.multiCardSummaryExpanded ? min(160, CGFloat(summary.facts.count) * 22 + 28) : 0)
                        .clipped()
                        .opacity(model.multiCardSummaryExpanded ? 1 : 0)
                        .allowsHitTesting(model.multiCardSummaryExpanded)
                        .accessibilityHidden(!model.multiCardSummaryExpanded)
                        .animation(reduceMotion ? nil : .timingCurve(0.333, 1, 0.666, 1, duration: 0.24), value: model.multiCardSummaryExpanded)
                    } else {
                        Text("合并重复信息，保留来源、条件与差异").font(.caption).foregroundStyle(PanelPalette.secondaryText)
                    }
                }.padding(.horizontal, 22).padding(.top, 10)
            }
            suggestionsRow
        }.foregroundStyle(PanelPalette.text)
    }

    private func readableFact(_ fact: String) -> String {
        var value = fact
        for item in model.selectedItems {
            value = value.replacingOccurrences(of: "[\(item.id.uuidString)]", with: (item.sourceName.isEmpty ? "来源" : item.sourceName) + "：")
        }
        return value
    }

    private var suggestionsRow: some View {
        GeometryReader { geometry in
            let slots = model.contextSuggestionsLoading ? 4 : min(4, max(3, model.contextSuggestions.count))
            let available = geometry.size.width - 282
            let cardWidth = min(320, max(220, (available - CGFloat(slots - 1) * 12) / CGFloat(slots)))
            HStack(spacing: 16) {
                context.frame(width: 154, alignment: .leading)
                if let error = model.contextSuggestionsError {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(error).font(.system(size: 12)).foregroundStyle(PanelPalette.secondaryText).lineLimit(2)
                        Button("重新生成", action: model.retryContextSuggestions).buttonStyle(.plain).foregroundStyle(PanelPalette.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            if model.contextSuggestionsLoading {
                                ForEach(0..<4) { index in
                                    SuggestionSkeletonCard(index: index).frame(width: cardWidth, height: 108)
                                }
                            } else {
                                ForEach(Array(model.contextSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                                    SuggestionOptionCard(suggestion: suggestion, index: index,
                                                         applying: model.contextSuggestionApplyingID == suggestion.id,
                                                         disabled: model.contextSuggestionApplyingID != nil || model.isPasting) {
                                        model.applyContextSuggestion(suggestion)
                                    }.frame(width: cardWidth, height: 108)
                                }
                            }
                        }.padding(.vertical, 1).horizontalScrollWheelRouting()
                    }.scrollIndicators(.never)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.contextSuggestionsLoading)
                }
                controls.frame(width: 52)
            }
            .frame(height: 108)
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(height: 132)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 建议")
        .accessibilityValue(model.contextSuggestionsLoading ? "正在生成" : "\(model.contextSuggestions.count) 项建议")
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("AI 建议", systemImage: "sparkles")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(PanelPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceName).lineLimit(1).truncationMode(.middle)
                Label(targetName, systemImage: "arrow.turn.down.right").lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 11)).foregroundStyle(PanelPalette.secondaryText)
        }.help("来源：\(sourceName)\n目标：\(targetName)")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: model.retryContextSuggestions) {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 30)
            }.buttonStyle(.plain).help("重新生成建议")
                .disabled(model.contextSuggestionsLoading || model.contextSuggestionApplyingID != nil)
                .accessibilityLabel("重新生成建议")
            Button(action: model.dismissContextSuggestions) {
                Image(systemName: "xmark").frame(width: 24, height: 30)
            }.buttonStyle(.plain).help("关闭建议").accessibilityLabel("关闭建议")
        }.foregroundStyle(PanelPalette.secondaryText)
    }

    private var sourceName: String {
        if model.selectedIDs.count > 1 { return "\(model.selectedIDs.count) 项来源" }; let name = model.selectedItems.first?.sourceName ?? ""
        return name.isEmpty ? "未知来源" : name
    }
    private var targetName: String { model.pasteEngine.target?.name ?? "复制到剪贴板" }
}

private struct SuggestionOptionCard: View {
    let suggestion: ContextSuggestion
    let index: Int
    let applying: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(suggestion.title).foregroundStyle(applying ? PanelPalette.selectionText : PanelPalette.text).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(applying ? "处理中" : "⌥\(index + 1)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(applying ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
                }
                Text(suggestion.detail)
                    .font(.system(size: 12)).foregroundStyle(applying ? PanelPalette.selectionSecondaryText : PanelPalette.secondaryText)
                    .lineSpacing(3).lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(15).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(applying || hovered ? PanelPalette.accent.opacity(0.5) : PanelPalette.border.opacity(0.6), lineWidth: 0.7))
            .overlay { if applying { SuggestionShimmer(delay: 0).clipShape(RoundedRectangle(cornerRadius: 13)).allowsHitTesting(false) } }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .help(suggestion.instruction)
        .accessibilityLabel("\(suggestion.title)，\(suggestion.detail)，处理后粘贴")
    }

    private var surface: Color {
        if applying { return PanelPalette.selection }
        return hovered ? PanelPalette.hover : PanelPalette.surface
    }
}

private struct SuggestionSkeletonCard: View {
    let index: Int
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 13) {
                RoundedRectangle(cornerRadius: 4).fill(PanelPalette.skeleton).frame(width: geometry.size.width * 0.54, height: 14)
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(PanelPalette.skeleton.opacity(0.65)).frame(height: 9)
                    RoundedRectangle(cornerRadius: 3).fill(PanelPalette.skeleton.opacity(0.65)).frame(width: geometry.size.width * 0.72, height: 9)
                }
            }.padding(15)
        }
        .background(PanelPalette.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(PanelPalette.border.opacity(0.6), lineWidth: 0.7))
        .overlay { SuggestionShimmer(delay: Double(index) * 0.14).clipShape(RoundedRectangle(cornerRadius: 13)) }
        .accessibilityHidden(true)
    }
}

private struct SuggestionShimmer: View {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if !reduceMotion && !reduceTransparency && !ProcessInfo.processInfo.isLowPowerModeEnabled {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                GeometryReader { geometry in
                    let phase = (timeline.date.timeIntervalSinceReferenceDate + delay).truncatingRemainder(dividingBy: 1.8) / 1.8
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.045), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.7)
                        .offset(x: geometry.size.width * (phase * 1.7 - 0.7))
                }
            }.allowsHitTesting(false)
        }
    }
}
