import SwiftUI
import PasteCore

/// Processing begins only after an explicit action; cloud providers disclose the destination.
struct ClipEnrichmentView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @State private var editingOCR = false
    @FocusState private var ocrFocused: Bool
    @State private var ocrDraft = ""
    @State private var editingSource = ""
    private var current: ClipItem? { model.snapshot.items.first { $0.id == item.id } }
    private var disclosure: String {
        let configuration = model.toolConfiguration
        let ocr = configuration.ocrProvider == .system
            ? "系统识别在本机处理图片。"
            : "图片将发送至\(configuration.ocrProviderTitle)。"
        let translation = configuration.translationProvider == .system
            ? "系统翻译可能需要下载语言资源。"
            : "原文将发送至\(configuration.translationProviderTitle)。"
        return (item.kind == .image ? ocr : "") + translation
    }
    var body: some View {
        if let value = current {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if value.kind == .image {
                        Button("识别文字", systemImage: "text.viewfinder") { model.recognizeItem(value) }
                        Button("识别并翻译", systemImage: "character.bubble") { model.recognizeItem(value, translateAfter: true) }
                        Button("复制原图") { model.copyToolOriginal(value) }
                    } else if !value.text.isEmpty {
                        Button("翻译", systemImage: "character.bubble") { model.translateItem(value) }
                        Button("复制原文") { model.copyToolOriginal(value) }
                    }
                    Spacer(minLength: 0)
                    if value.enrichment != nil { Button("打开识别与翻译") { model.showToolItem(value) } }
                }.controlSize(.small)
                Text(disclosure)
                    .font(.caption).foregroundStyle(.secondary)
                if value.enrichment?.ocr != nil || value.enrichment?.translation != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let ocr = value.enrichment?.ocr { ocrContent(value, text: ocr.text, provider: ocr.provider) }
                            if let translation = value.enrichment?.translation {
                                textSection(title: "原文", text: translation.sourceText, copyTitle: "复制原文")
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("译文").font(.headline)
                                        if value.translationIsStale {
                                            Label("原文已修改", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                        }
                                        Spacer()
                                        Button(value.translationIsStale ? "复制旧译文" : "复制译文") { model.copyToolText(translation.translatedText) }
                                        Button("重新翻译") { model.translateItem(value) }
                                    }.controlSize(.small)
                                    Text(translation.translatedText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(translation.provider) · \(translation.model) · \(translation.sourceLanguage) → \(translation.targetLanguage)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if value.translationIsStale { Text("原文已修改，需重新翻译。").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }.padding(.trailing, 6)
                    }.frame(maxHeight: 240)
                }
            }

        }
    }
    private func ocrContent(_ value: ClipItem, text: String, provider: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("识别文字").font(.headline)
                Text(provider).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制识别文字") { model.copyToolText(text) }
                if editingOCR {
                    Button("取消") { editingOCR = false }
                    Button("保存") { model.saveOCRText(value, text: ocrDraft); editingOCR = false }
                        .disabled(text != editingSource)
                } else {
                    Button("编辑") { ocrDraft = text; editingSource = text; editingOCR = true }
                }
            }.controlSize(.small)
            if editingOCR {
                TextEditor(text: $ocrDraft).font(.system(size: 13)).frame(minHeight: 90, maxHeight: 150)
                    .scrollContentBackground(.hidden).padding(6).focused($ocrFocused)
                    .modifier(PasteboardInputSurface(focused: ocrFocused))
                    .background(InputFocusOnAppear { ocrFocused = true }.frame(width: 0, height: 0))
                if text != editingSource { Text("识别文字已更新，请取消后重新编辑。").font(.caption).foregroundStyle(.orange) }
            } else { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    private func textSection(title: String, text: String, copyTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.headline); Spacer(); Button(copyTitle) { model.copyToolText(text) }.controlSize(.small) }
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ClipEnrichmentBadge: View {
    let item: ClipItem
    var body: some View {
        HStack(spacing: 5) {
            if item.enrichment?.ocr != nil { Label("已识别", systemImage: "text.viewfinder") }
            if item.enrichment?.translation != nil {
                Label(item.translationIsStale ? "需重新翻译" : "已翻译", systemImage: item.translationIsStale ? "exclamationmark.circle" : "character.bubble")
            }
        }.font(.system(size: 10, weight: .medium))
    }
}
