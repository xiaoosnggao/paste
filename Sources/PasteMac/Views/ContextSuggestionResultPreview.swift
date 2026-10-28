import AppKit
import SwiftUI
import PasteCore

struct ContextSuggestionPreviewResult: Identifiable {
    let id: UUID
    let title: String
    var text: String
    let sourceIDs: [UUID]
    let provider: String
}

struct ContextSuggestionResultPreview: View {
    @ObservedObject var model: AppModel
    let result: ContextSuggestionPreviewResult
    @State private var editedText = ""
    @State private var notice: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(result.title).font(.title2.weight(.semibold))
                Spacer()
                Text("\(result.sourceIDs.count) 项来源").font(.caption).foregroundStyle(PanelPalette.secondaryText)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(result.sourceIDs, id: \.self) { id in
                        if let item = model.snapshot.items.first(where: { $0.id == id }) {
                            Button { model.preview(item) } label: {
                                Label(item.title.isEmpty ? item.sourceName : item.title, systemImage: "doc.text")
                                    .lineLimit(1).frame(maxWidth: 180)
                            }.buttonStyle(.bordered).controlSize(.small)
                        } else {
                            Text("来源已删除").font(.caption).foregroundStyle(PanelPalette.secondaryText)
                        }
                    }
                }
            }.scrollIndicators(.never)
            TextEditor(text: $editedText).font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10).background(PanelPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(notice ?? "").font(.caption).foregroundStyle(PanelPalette.secondaryText)
                Spacer()
                Button("复制") {
                    do {
                        try model.bridge.write([ClipItem(text: editedText, kind: .text)], plainText: true)
                        notice = "已复制"
                    } catch { notice = error.localizedDescription }
                }
                Button(saved ? "已保存" : "保存卡片") {
                    saved = model.saveContextSuggestionPreview(result, text: editedText)
                    notice = saved ? "已保存" : "保存失败，请重试。"
                }.disabled(saved)
                Button("粘贴") {
                    if !model.saveContextSuggestionPreview(result, text: editedText, paste: true) { notice = "无法保存结果，请重试。" }
                }.buttonStyle(.borderedProminent).tint(PanelPalette.accent).foregroundStyle(PanelPalette.onAccent)
            }
        }
        .padding(24).frame(minWidth: 560, minHeight: 420)
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
        .background(Color.clear)
        .onAppear { editedText = result.text }
        .onChange(of: editedText) { _, _ in saved = false; notice = nil }
    }
}
