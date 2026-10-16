import SwiftUI
import PasteCore

struct StackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("连续粘贴", systemImage: "square.stack.3d.up.fill").font(.headline)
                Spacer()
                Text("\(model.stackItems.count) 个项目").font(.caption).foregroundStyle(.secondary)
            }
            if model.stackItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 35)).foregroundStyle(.secondary)
                    Text("添加项目后，按顺序逐项粘贴")
                    Button("添加所选项目") { model.setStack(model.selectedItems) }.disabled(model.selectedItems.isEmpty)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 20)
                            SourceIcon(item: item).frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? item.text : item.title).lineLimit(2)
                                Text(item.kind.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.setStack(model.stackItems.filter { $0.id != item.id }) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }.listStyle(.inset)
            }
            HStack {
                Toggle("倒序粘贴", isOn: Binding(get: { model.stackReversed }, set: model.setStackReversed)).toggleStyle(.checkbox)
                Spacer()
                Button("清空") { model.setStack([]) }.disabled(model.stackItems.isEmpty)
                Button("粘贴下一项", action: model.pasteNextStack).keyboardShortcut(.defaultAction).disabled(model.stackItems.isEmpty)
            }
            Text("在目标应用中放置光标，再点击“粘贴下一项”。粘贴后自动移除该项目。") .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 440, minHeight: 340)
    }
    private var orderedItems: [ClipItem] { model.stackReversed ? Array(model.stackItems.reversed()) : model.stackItems }
}
