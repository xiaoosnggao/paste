import SwiftUI

/// The modes offered by 合成一条, shared by the card context menu and the selection bar.
struct MergeModeMenuItems: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("本机") {
            ForEach(ClipMergeMode.local) { mode in
                Button(mode.title, systemImage: mode.symbol) { model.mergeSelection(mode) }
            }
        }
        Section(model.mergeAIServiceName.map { "AI · \($0)" } ?? "AI（需在设置中启用 AI 服务）") {
            ForEach(ClipMergeMode.ai) { mode in
                Button(mode.title, systemImage: mode.symbol) { model.mergeSelection(mode) }
                    .disabled(model.mergeAIServiceName == nil)
            }
        }
    }
}

/// Floats above the deck while several cards are selected: “已选 3 项 · 合成一条 ▾”.
/// Liquid Glass on macOS 26, a material capsule elsewhere or with Reduce Transparency.
struct MergeSelectionBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let row = HStack(spacing: DesignTokens.Space.md) {
            if let mode = model.mergeInProgress {
                ProgressView().controlSize(.small)
                Text("正在\(mode.title)…").font(.scaled(.label, weight: .medium))
                Button("取消", action: model.cancelMerge)
                    .buttonStyle(.plain).font(.scaled(.label, weight: .medium)).foregroundStyle(PanelPalette.accent)
            } else {
                Text("已选 \(model.selectedIDs.count) 项").font(.scaled(.label, weight: .medium)).foregroundStyle(PanelPalette.secondaryText)
                    .monospacedDigit()
                Menu {
                    MergeModeMenuItems(model: model)
                } label: {
                    Label("合成一条", systemImage: "rectangle.stack.badge.plus").font(.scaled(.label, weight: .semibold))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.visible)
                .foregroundStyle(PanelPalette.accent).tint(PanelPalette.accent)
                .fixedSize()
                .disabled(!model.canMergeSelection)
                .help(model.canMergeSelection ? "把所选内容按复制顺序合成一张新卡片" : "至少需要两项含文字的内容（图片需先识别文字）")
            }
        }
        .padding(.horizontal, DesignTokens.Space.lg)
        .frame(height: PanelMetrics.controlSize + 4)
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                GlassEffectContainer { row.glassEffect(.regular, in: Capsule()) }
            } else {
                row.background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("多选操作")
    }
}
