import AppKit
import SwiftUI
import PasteCore

struct IntelligenceView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @State private var result = ""
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var availability = IntelligenceService.availability
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("智能处理").font(.headline)
            Text(item.title.isEmpty ? String(item.text.prefix(80)) : item.title).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            Text(availability.message).font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(IntelligenceAction.allCases) { action in
                    Button(action.rawValue) { startAI(action) }.disabled(busy || !availability.available || item.text.count > 2400)
                }
                Button("刷新状态") { availability = IntelligenceService.availability }.disabled(busy)
            }
            if item.text.count > 2400 { Text("智能处理最多支持 2400 个字符。请缩短文本后重试。").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("文本整理").font(.subheadline)
            HStack {
                ForEach(LocalTextAction.allCases) { action in Button(action.rawValue) { startLocal(action) }.disabled(busy) }
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("正在处理…"); Button("取消") { task?.cancel(); task = nil; operation = UUID(); busy = false } } }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            if !result.isEmpty {
                ScrollView { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: 220)
                HStack {
                    Button("复制结果") { copyResult() }
                    Button("保存结果") {
                        if model.saveText(result, title: "处理结果", item: nil) { savedMessage = "结果已保存，相同内容将合并。" }
                        else { error = model.statusMessage ?? "保存失败。" }
                    }
                }.disabled(busy)
                if let savedMessage { Text(savedMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.padding(16).padding(.top, 28)
        .frame(minWidth: 560, minHeight: 480, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { task?.cancel() }
    }
    private func startAI(_ action: IntelligenceAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do { let output = try await IntelligenceService.run(action, text: item.text); try Task.checkCancellation(); result = output }
            catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { busy = false }
        }
    }
    private func startLocal(_ action: LocalTextAction) {
        busy = true; error = nil; savedMessage = nil; result = ""; operation = UUID(); let id = operation
        task = Task {
            do {
                let input = item.text
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
