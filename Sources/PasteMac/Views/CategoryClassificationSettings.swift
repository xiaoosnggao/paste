import SwiftUI
import PasteCore

/// 自动归类 settings for one pinboard, in a popover anchored on its tab.
///
/// It used to be a sheet that dropped over the whole panel and hid the cards;
/// the popover opens above the tab and leaves the deck visible.
struct CategoryClassificationSettings: View {
    static let popoverWidth: CGFloat = 380
    /// Upper bound for the popover; the self-test checks the fields fit.
    static let popoverMaxHeight: CGFloat = 296
    static let rowHeight: CGFloat = 28

    @ObservedObject var model: AppModel
    let board: Pinboard
    var onDismiss: () -> Void
    @State private var description = ""
    @State private var keywords = ""
    @State private var enabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.sectionSpacing) {
            HStack(spacing: DesignTokens.Space.sm) {
                Circle().fill(Color(hex: board.colorHex)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(board.name).font(.scaled(.title, weight: .semibold)).lineLimit(1)
                Text("自动归类").font(.scaled(.label)).foregroundStyle(PanelPalette.secondaryText)
                Spacer(minLength: DesignTokens.Space.sm)
                Toggle("自动归类新内容", isOn: $enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("自动归类新内容").accessibilityLabel("自动归类新内容")
            }
            .frame(height: Self.rowHeight)
            CategoryClassificationFields(description: $description, keywords: $keywords)
            HStack(spacing: WindowMetrics.footerSpacing) {
                WindowFooterNote(enabled ? "新内容将自动归入此分类" : "已暂停自动归类")
                Spacer()
                Button("取消", action: onDismiss).windowCancelAction()
                Button("保存") {
                    model.setClassificationDetails(board.id, description: description, enabled: enabled,
                        keywords: keywords.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    onDismiss()
                }.windowPrimaryAction()
            }
            .controlSize(.small)
            .frame(height: Self.rowHeight)
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: Self.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
        .onAppear { description = board.classificationDescription ?? ""; keywords = (board.classificationKeywords ?? []).joined(separator: "，"); enabled = board.automaticClassification != false }
    }
}

/// The popover's fields, separate so the self-test can measure them.
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
