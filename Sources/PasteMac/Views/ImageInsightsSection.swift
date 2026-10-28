import AppKit
import SwiftUI
import PasteCore

/// “图片识别” in the preview popup's right column: text, QR codes and barcodes,
/// a rebuilt table and the dominant colors, each copyable with one click.
/// Runs on this Mac with Vision when the image is previewed.
struct ImageInsightsSection: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @State private var insights: ImageInsights?
    @State private var failure: String?
    @State private var copiedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(spacing: DesignTokens.Space.xs) {
                Label("图片识别", systemImage: "viewfinder").font(.scaled(.label, weight: .semibold)).foregroundStyle(PanelPalette.accent)
                Spacer(minLength: 0)
                Text("本机").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                    .help("使用系统视觉框架在这台 Mac 上识别，图片不会上传。")
            }
            if let insights {
                if insights.isEmpty {
                    Text("未发现文字、二维码或表格。").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                } else { results(insights) }
            } else if let failure {
                Text(failure).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            } else {
                HStack(spacing: DesignTokens.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在识别…").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                }
            }
        }
        .task(id: "\(item.fingerprint)#\(item.representations.count)") { await analyze() }
    }

    @ViewBuilder private func results(_ value: ImageInsights) -> some View {
        ForEach(value.codes) { code in
            row(key: "code-" + code.id, symbol: code.kind == "二维码" ? "qrcode" : "barcode", title: code.kind, copy: code.payload) {
                Text(code.payload).font(.scaled(.label)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            } extra: {
                if code.isLink, let url = URL(string: code.payload) {
                    IconAction(symbol: "arrow.up.right.square", label: "打开链接") { NSWorkspace.shared.open(url) }
                }
            }
        }
        if let tsv = value.tableTSV, let table = value.table {
            row(key: "table", symbol: "tablecells", title: "表格 · \(table.count) 行 × \(table.first?.count ?? 0) 列", copy: tsv) {
                tablePreview(table)
            } extra: {
                if let markdown = value.tableMarkdown {
                    IconAction(symbol: "number", label: "复制为 Markdown 表格") { copy(markdown, key: "table-md") }
                }
            }
        }
        // The text row is skipped when a recognition result is already shown below.
        if !value.text.isEmpty, item.enrichment?.ocr == nil {
            row(key: "text", symbol: "text.viewfinder", title: "文字 · \(value.text.count) 字", copy: value.text) {
                Text(value.text).font(.scaled(.label)).lineLimit(6).textSelection(.enabled)
            } extra: { EmptyView() }
        }
        if !value.colors.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                WindowSectionHeader("主色")
                HStack(spacing: DesignTokens.Space.sm) {
                    ForEach(value.colors, id: \.self) { hex in
                        Button { copy(hex, key: "color-" + hex) } label: {
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(Color(hex: hex))
                                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                                    .overlay { if copiedKey == "color-" + hex { Image(systemName: "checkmark").font(.scaled(.caption, weight: .bold)).foregroundStyle(.white).shadow(radius: 1) } }
                                    .frame(width: 36, height: 28)
                                Text(hex.dropFirst()).font(.system(.caption2, design: .monospaced)).foregroundStyle(PanelPalette.secondaryText)
                            }
                        }
                        .buttonStyle(.plain).focusEffectDisabled()
                        .help("复制 \(hex)").accessibilityLabel("复制颜色 \(hex)")
                    }
                }
            }
            .popupCard(padding: DesignTokens.Space.md)
        }
    }

    private func row<Body: View, Extra: View>(key: String, symbol: String, title: String, copy text: String,
                                              @ViewBuilder content: () -> Body, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.xs) {
                Image(systemName: symbol).font(.scaled(.caption, weight: .semibold)).foregroundStyle(PanelPalette.secondaryText)
                WindowSectionHeader(title)
                Spacer(minLength: DesignTokens.Space.sm)
                extra()
                IconAction(symbol: copiedKey == key ? "checkmark" : "doc.on.doc", label: "复制") { copy(text, key: key) }
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .popupCard(padding: DesignTokens.Space.md)
    }

    private func tablePreview(_ table: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Space.md, verticalSpacing: 3) {
            ForEach(Array(table.prefix(6).enumerated()), id: \.offset) { index, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.scaled(.caption, weight: index == 0 ? .semibold : .regular)).lineLimit(1)
                    }
                }
            }
            if table.count > 6 {
                Text("还有 \(table.count - 6) 行").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            }
        }
    }

    private func copy(_ text: String, key: String) {
        model.copyToolText(text)
        withAnimation(.easeOut(duration: 0.12)) { copiedKey = key }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedKey == key { withAnimation(.easeOut(duration: 0.2)) { copiedKey = nil } }
        }
    }

    private func analyze() async {
        let key = item.fingerprint
        if let cached = ImageInsightsCache.value(key) { insights = cached; return }
        insights = nil; failure = nil
        guard let data = AppModel.imageData(item) else {
            // History rows load their payload lazily; wait for it instead of reporting an error.
            if !item.representations.isEmpty { failure = "无法读取这张图片。" }
            return
        }
        do {
            let value = try await ImageInsights.analyze(data)
            try Task.checkCancellation()
            ImageInsightsCache.store(value, for: key)
            insights = value
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

/// A small borderless icon button used inside the preview's result cards.
private struct IconAction: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(.caption, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(hovering ? PanelPalette.raised : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .foregroundStyle(PanelPalette.text)
        .onHover { hovering = $0 }
        .help(label).accessibilityLabel(label)
    }
}
