import SwiftUI
import PasteCore

struct CategoryClassificationSettings: View {
    @ObservedObject var model: AppModel
    let board: Pinboard
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var keywords = ""
    @State private var enabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(board.name).font(.title2.weight(.semibold))
            Toggle("自动归类新内容", isOn: $enabled)
            VStack(alignment: .leading, spacing: 7) {
                Text("分类说明").font(.subheadline.weight(.medium))
                TextField("例如：项目报价、付款条件和交付安排", text: $description, axis: .vertical)
                    .lineLimit(3...4).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("匹配关键词").font(.subheadline.weight(.medium))
                TextField("用逗号分隔", text: $keywords).textFieldStyle(.roundedBorder)
                Text("包含全部关键词时自动归入；多个分类同时匹配时由你选择。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.setClassificationDetails(board.id, description: description, enabled: enabled,
                        keywords: keywords.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    dismiss()
                }.buttonStyle(.borderedProminent).foregroundStyle(PanelPalette.canvas).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
        .onAppear { description = board.classificationDescription ?? ""; keywords = (board.classificationKeywords ?? []).joined(separator: "，"); enabled = board.automaticClassification != false }
    }
}
