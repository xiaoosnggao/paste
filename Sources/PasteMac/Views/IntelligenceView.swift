import AppKit
import SwiftUI
import PasteCore

/// The detail layer's smart page: actions on the left, the result on the right.
struct IntelligenceView: View {
    @ObservedObject var model: AppModel
    let itemID: UUID?
    @State private var result = ""
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var availability = IntelligenceService.availability
    private var current: ClipItem? { itemID.flatMap { id in model.snapshot.items.first { $0.id == id } } }
    private var text: String { current?.text ?? "" }
    private var tooLong: Bool { text.count > 2400 }
    var body: some View {
        Group {
            if let item = current {
                PanelDetailScaffold(model: model, item: item, page: .intelligence, title: "智能处理",
                                    showsFooter: busy || !result.isEmpty || error != nil || savedMessage != nil) {
                    HStack(alignment: .top, spacing: DesignTokens.Space.lg) {
                        ScrollView { actions.frame(maxWidth: .infinity, alignment: .leading) }
                            .scrollIndicators(.automatic)
                            .frame(width: 380)
                        resultSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } footer: {
                    footer
                }
            } else {
                PanelDetailScaffold(model: model, item: nil, page: .intelligence, title: "智能处理", showsFooter: false) {
                    ContentUnavailableView("此卡片已删除", systemImage: "trash").frame(maxWidth: .infinity, maxHeight: .infinity)
                } footer: {
                    Spacer()
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                HStack(spacing: DesignTokens.Space.sm) {
                    WindowSectionHeader("Apple 智能")
                    Button("刷新状态", systemImage: "arrow.clockwise") { availability = IntelligenceService.availability }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small).disabled(busy)
                        .help("刷新 Apple 智能状态")
                }
                Text(availability.message).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // Unavailable actions are hidden; the message above says why.
                if availability.available {
                    HStack(spacing: DesignTokens.Space.sm) {
                        ForEach(IntelligenceAction.allCases) { action in
                            Button(action.rawValue) { startAI(action) }.disabled(busy || tooLong)
                        }
                    }
                }
                if tooLong {
                    Text("智能处理最多支持 2400 个字符。请缩短文本后重试。").font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                WindowSectionHeader("文本整理")
                HStack(spacing: DesignTokens.Space.sm) {
                    ForEach(LocalTextAction.allCases) { action in Button(action.rawValue) { startLocal(action) }.disabled(busy) }
                }
            }
        }
        .controlSize(.small)
    }
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            WindowSectionHeader("结果")
            Group {
                if result.isEmpty {
                    Text(busy ? "正在处理…" : "选择左侧的操作，结果显示在这里。")
                        .font(.scaled(.body)).foregroundStyle(PanelPalette.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        Text(result).font(.scaled(.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .windowWell(padding: DesignTokens.Space.sm)
        }
    }
    @ViewBuilder private var footer: some View {
        footerStatus
        Spacer()
        if busy {
            Button("取消") { task?.cancel(); task = nil; operation = UUID(); busy = false }
        }
        if !result.isEmpty {
            Button("保存结果") {
                if model.saveText(result, title: "处理结果", item: nil) { savedMessage = "结果已保存，相同内容将合并。" }
                else { error = model.statusMessage ?? "保存失败。" }
            }.disabled(busy)
            Button("复制结果") { copyResult() }
                .primaryActionStyle()
                .disabled(busy)
        }
    }
    @ViewBuilder private var footerStatus: some View {
        if busy {
            ProgressView().controlSize(.small)
            WindowFooterNote("正在处理…")
        } else if let error {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(error).font(.scaled(.caption)).foregroundStyle(.orange).lineLimit(2).help(error)
        } else if let savedMessage {
            WindowFooterNote(savedMessage)
        }
    }
    private func startAI(_ action: IntelligenceAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do { let output = try await IntelligenceService.run(action, text: text); try Task.checkCancellation(); result = output }
            catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { busy = false }
        }
    }
    private func startLocal(_ action: LocalTextAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do {
                let input = text
                let output = try await Task.detached(priority: .userInitiated) { try TextTools.apply(action, to: input) }.value
                try Task.checkCancellation()
                result = output
                if output.isEmpty { error = "未找到符合条件的内容。" }
            } catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { busy = false }
        }
    }
    private func copyResult() {
        guard !model.isPasting else { return }
        do {
            let value = ClipItem(text: result, kind: .text, representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(result.utf8))])
            try model.bridge.write([value], plainText: true)
            model.statusMessage = "处理结果已复制"
        } catch { self.error = error.localizedDescription }
    }
}
