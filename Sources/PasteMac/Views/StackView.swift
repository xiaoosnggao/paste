import SwiftUI
import PasteCore

struct StackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WindowScaffold("连续粘贴", subtitle: model.stackItems.isEmpty ? nil : "\(model.stackItems.count) 张卡片") {
            VStack(alignment: .leading, spacing: WindowMetrics.sectionSpacing) {
                if model.stackItems.isEmpty {
                    VStack(spacing: DesignTokens.Space.md) {
                        Image(systemName: "square.stack.3d.up").font(.scaled(.hero)).foregroundStyle(PanelPalette.secondaryText)
                            .accessibilityHidden(true)
                        Text("添加卡片后，按顺序逐项粘贴").font(.scaled(.body))
                        Button("添加所选卡片") { model.setStack(model.selectedItems) }.disabled(model.selectedItems.isEmpty)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: DesignTokens.Space.xs) {
                            ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Text("在目标应用中放置光标，再点击“粘贴下一项”。粘贴后自动移除该卡片。")
                        .font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Toggle("倒序粘贴", isOn: Binding(get: { model.stackReversed }, set: model.setStackReversed)).toggleStyle(.checkbox)
            Spacer()
            Button("清空") { model.setStack([]) }.disabled(model.stackItems.isEmpty)
            WindowCloseButton()
            Button("粘贴下一项", action: model.pasteNextStack).windowPrimaryAction().disabled(model.stackItems.isEmpty)
        }
        .frame(minWidth: 440, minHeight: 340)
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        let title = item.title.isEmpty ? item.text : item.title
        return HStack(spacing: DesignTokens.Space.md) {
            Text("\(index + 1)").font(.scaled(.caption).monospacedDigit()).foregroundStyle(PanelPalette.secondaryText)
                .frame(width: 20, alignment: .trailing)
            SourceIcon(item: item).frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.scaled(.body)).lineLimit(2)
                Text(item.kind.displayName).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            }
            Spacer(minLength: DesignTokens.Space.sm)
            Button { model.setStack(model.stackItems.filter { $0.id != item.id }) } label: {
                Image(systemName: "xmark").font(.scaled(.caption, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(PanelControlStyle())
            .help("从连续粘贴中移除").accessibilityLabel("移除第 \(index + 1) 项")
        }
        .padding(.horizontal, DesignTokens.Space.md).padding(.vertical, DesignTokens.Space.sm)
        .background(PanelPalette.surface.opacity(index == 0 ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .strokeBorder(index == 0 ? PanelPalette.selectionBorder.opacity(0.6) : .clear, lineWidth: 1)
        }
    }
    private var orderedItems: [ClipItem] { model.stackReversed ? Array(model.stackItems.reversed()) : model.stackItems }
}
