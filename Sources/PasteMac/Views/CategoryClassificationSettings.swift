import SwiftUI
import PasteCore

struct CategoryClassificationSettings: View {
    /// The sheet hangs from the top of the 320pt clipboard panel; anything
    /// taller ran past the panel's bottom edge and off the screen.
    static let sheetHeight: CGFloat = 296
    static let sheetWidth: CGFloat = 420

    @ObservedObject var model: AppModel
    let board: Pinboard
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var keywords = ""
    @State private var enabled = true
    var body: some View {
        WindowScaffold(board.name, subtitle: "自动归类", chrome: .sheet, scrolls: true) {
            Toggle("自动归类新内容", isOn: $enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("自动归类新内容").accessibilityLabel("自动归类新内容")
        } content: {
            CategoryClassificationFields(description: $description, keywords: $keywords)
        } footer: {
            WindowFooterNote(enabled ? "新内容将自动归入此分类" : "已暂停自动归类")
            Spacer()
            Button("取消") { dismiss() }.windowCancelAction()
            Button("保存") {
                model.setClassificationDetails(board.id, description: description, enabled: enabled,
                    keywords: keywords.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                dismiss()
            }.windowPrimaryAction()
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
        .onAppear { description = board.classificationDescription ?? ""; keywords = (board.classificationKeywords ?? []).joined(separator: "，"); enabled = board.automaticClassification != false }
    }
}

/// The sheet's fields, separate so the self-test can measure them.
struct CategoryClassificationFields: View {
    @Binding var description: String
    @Binding var keywords: String
    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text("分类说明").font(.scaled(.label, weight: .medium))
                TextField("例如：项目报价、付款条件和交付安排", text: $description, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(PasteboardTextFieldStyle())
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text("匹配关键词").font(.scaled(.label, weight: .medium))
                TextField("用逗号分隔", text: $keywords).textFieldStyle(PasteboardTextFieldStyle())
                Text("包含全部关键词时自动归入；多个分类同时匹配时由你选择。")
                    .font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
