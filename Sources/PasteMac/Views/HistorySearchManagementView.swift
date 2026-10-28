import SwiftUI
import PasteCore

struct HistorySearchManagementView: View {
    @ObservedObject var model: AppModel
    let preview: HistoryManagementPreview
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.scaled(.display, weight: .medium))
                    .foregroundStyle(preview.intent == .previewDelete ? Color.red : Color.accentColor)
                    .frame(width: 42, height: 42).background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                VStack(alignment: .leading, spacing: 5) {
                    Text(preview.title).font(.title3.weight(.semibold))
                    Text("\(preview.itemIDs.count) 项内容").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(preview.query).font(.body).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            if let category = preview.categoryName {
                LabeledContent("目标分类", value: category)
            }
            Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !preview.examples.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(preview.examples.enumerated()), id: \.offset) { _, title in
                            Label(title, systemImage: "doc.text").font(.caption).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            if let message = error ?? preview.error {
                Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
            HStack {
                if applying { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { model.historyManagementPreview = nil; dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(applying)
                Button(actionTitle) { apply() }
                    .buttonStyle(.borderedProminent)
                    .tint(preview.intent == .previewDelete ? .red : .accentColor)
                    .disabled(applying || preview.error != nil || preview.itemIDs.isEmpty)
            }
        }
        .padding(24).frame(width: 420)
        .background(.regularMaterial)
        .interactiveDismissDisabled(applying)
    }
    private var symbol: String {
        switch preview.intent {
        case .previewDelete: return "trash"
        case .previewCategorize: return "folder"
        case .previewSummarize: return "sparkles"
        case .search: return "magnifyingglass"
        }
    }
    private var description: String {
        switch preview.intent {
        case .previewDelete: return "删除全部匹配内容，可撤销。"
        case .previewCategorize: return "将全部匹配内容加入此分类，保留现有分类，可撤销。"
        case .previewSummarize: return "使用已配置的 AI 服务总结匹配内容，原卡片保留。"
        case .search: return "查看全部匹配内容。"
        }
    }
    private var actionTitle: String {
        switch preview.intent {
        case .previewDelete: return "删除 \(preview.itemIDs.count) 项"
        case .previewCategorize: return "加入分类"
        case .previewSummarize: return "开始总结"
        case .search: return "完成"
        }
    }
    private func apply() {
        guard !applying else { return }
        applying = true; error = nil
        Task { @MainActor in
            do {
                try await model.applyHistoryManagement(ids: preview.itemIDs, intent: preview.intent, categoryID: preview.categoryID)
                model.historyManagementPreview = nil; dismiss()
            } catch { self.error = error.localizedDescription; applying = false }
        }
    }
}
