import SwiftUI
import PasteCore

/// The 连续粘贴 capsule: a small non-activating bar that floats near the mouse.
///
/// It replaces the old 440×490 window. Clicking it never takes focus from the
/// target app, so the insertion point stays where you put it. The collapsed bar
/// shows the next card and 粘贴下一项; the list (remove, 倒序粘贴, 清空) opens
/// below it on demand. Placement is handled by `StackCapsulePlacement`.
struct StackCapsuleView: View {
    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 36
    /// Five rows; longer stacks scroll.
    static let listMaxHeight: CGFloat = rowHeight * 5 + DesignTokens.Space.xs * 4

    /// Height of the list for `count` rows, so the capsule's size is known up front.
    static func listHeight(rows count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(rowHeight * CGFloat(count) + DesignTokens.Space.xs * CGFloat(count - 1), listMaxHeight)
    }

    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            if model.stackItems.isEmpty { emptyBar } else { bar }
            if expanded, !model.stackItems.isEmpty {
                Divider().opacity(0.5)
                list
            }
        }
        .frame(width: Self.width)
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(PanelPalette.border.opacity(0.35), lineWidth: 1) }
        .clipShape(shape)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.stackItems.isEmpty) { _, empty in if empty { expanded = false } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("连续粘贴")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? DesignTokens.Radius.lg : DesignTokens.Radius.xl, style: .continuous)
    }

    private var bar: some View {
        let ordered = model.orderedStackItems
        return HStack(spacing: DesignTokens.Space.sm) {
            Text("\(ordered.count)")
                .font(.scaled(.label, weight: .semibold).monospacedDigit())
                .foregroundStyle(PanelPalette.onAccent)
                .frame(minWidth: 24, minHeight: 24)
                .background(PanelPalette.accent, in: Capsule())
                .help("剩余 \(ordered.count) 张卡片")
                .accessibilityLabel("剩余 \(ordered.count) 张卡片")
            VStack(alignment: .leading, spacing: 1) {
                Text(ordered.first.map(title) ?? "").font(.scaled(.label, weight: .medium)).lineLimit(1)
                Text(model.stackReversed ? "下一项 · 倒序" : "下一项")
                    .font(.scaled(.micro)).foregroundStyle(PanelPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("粘贴下一项", action: model.pasteNextStack)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(PanelPalette.accent).foregroundStyle(PanelPalette.onAccent)
                .disabled(model.stackItems.isEmpty)
                .help("在目标应用中放置光标，再点击“粘贴下一项”。粘贴后自动移除该卡片。")
            iconButton(expanded ? "chevron.up" : "chevron.down", help: expanded ? "收起列表" : "展开列表") { expanded.toggle() }
            iconButton("xmark", help: "关闭", action: onClose)
        }
        .padding(.leading, DesignTokens.Space.md).padding(.trailing, DesignTokens.Space.sm)
        .padding(.vertical, DesignTokens.Space.sm)
    }

    private var emptyBar: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            Image(systemName: "square.stack.3d.up").font(.scaled(.title)).foregroundStyle(PanelPalette.secondaryText)
                .accessibilityHidden(true)
            Text("添加卡片后，按顺序逐项粘贴").font(.scaled(.label)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("添加所选卡片") { model.setStack(model.selectedItems) }
                .controlSize(.small).disabled(model.selectedItems.isEmpty)
            iconButton("xmark", help: "关闭", action: onClose)
        }
        .padding(.leading, DesignTokens.Space.md).padding(.trailing, DesignTokens.Space.sm)
        .padding(.vertical, DesignTokens.Space.sm)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            ScrollView {
                LazyVStack(spacing: DesignTokens.Space.xs) {
                    ForEach(Array(model.orderedStackItems.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                    }
                }
            }
            .frame(height: Self.listHeight(rows: model.stackItems.count))
            Text("在目标应用中放置光标，再点击“粘贴下一项”。粘贴后自动移除该卡片。")
                .font(.scaled(.micro)).foregroundStyle(PanelPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("倒序粘贴", isOn: Binding(get: { model.stackReversed }, set: model.setStackReversed))
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Button("清空") { model.setStack([]) }.controlSize(.small).disabled(model.stackItems.isEmpty)
            }
        }
        .padding(DesignTokens.Space.md)
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        HStack(spacing: DesignTokens.Space.sm) {
            Text("\(index + 1)").font(.scaled(.caption).monospacedDigit()).foregroundStyle(PanelPalette.secondaryText)
                .frame(width: 18, alignment: .trailing)
            SourceIcon(item: item).frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(item)).font(.scaled(.label)).lineLimit(1)
                Text(item.kind.displayName).font(.scaled(.micro)).foregroundStyle(PanelPalette.secondaryText)
            }
            Spacer(minLength: DesignTokens.Space.xs)
            iconButton("xmark", help: "从连续粘贴中移除") { model.setStack(model.stackItems.filter { $0.id != item.id }) }
                .accessibilityLabel("移除第 \(index + 1) 项")
        }
        .padding(.horizontal, DesignTokens.Space.sm)
        .frame(height: Self.rowHeight)
        .background(PanelPalette.surface.opacity(index == 0 ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .strokeBorder(index == 0 ? PanelPalette.selectionBorder.opacity(0.6) : .clear, lineWidth: 1)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(.caption, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PanelControlStyle())
        .help(help).accessibilityLabel(help)
    }

    private func title(_ item: ClipItem) -> String {
        let text = item.title.isEmpty ? item.text : item.title
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}
