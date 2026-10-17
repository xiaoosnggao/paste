import AppKit
import SwiftUI
import PasteCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var mcp: MCPService? = nil
    @State private var page = SettingsPage.general
    @State private var recording = false
    @State private var recordingStack = false
    @State private var deleteConfirmation = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case general = "通用", ai = "AI 服务", tools = "识别与翻译", shortcuts = "快捷键", privacy = "隐私", integrations = "系统集成"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "sparkles"
            case .tools: return "viewfinder"
            case .shortcuts: return "keyboard"
            case .privacy: return "hand.raised"
            case .integrations: return "puzzlepiece.extension"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(height: 40)
                ForEach(SettingsPage.allCases) { entry in
                    Button { page = entry } label: {
                        Label(entry.rawValue, systemImage: entry.symbol)
                            .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(page == entry ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(page == entry ? .white : .primary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("剪贴板历史管理").font(.caption).foregroundStyle(.secondary).padding(14)
            }.padding(.horizontal, 10).frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0.12))
            VStack(alignment: .leading, spacing: 0) {
                Text(page.rawValue).font(.system(size: 16, weight: .bold)).padding(.horizontal, 25).padding(.top, 20).padding(.bottom, 12)
                Form {
                    if let error = model.storageError {
                        Section("保存失败") {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Button("重试保存", action: model.retrySave)
                        }
                    }
                    switch page {
                    case .general: general
                    case .ai: AIServiceSettingsView(model: model)
                    case .tools: CloudToolSettingsView(model: model)
                    case .shortcuts: shortcuts
                    case .privacy: privacy
                    case .integrations: integrations
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.18))
        }.frame(minWidth: 640, minHeight: 520).ignoresSafeArea(.container, edges: .top)
            .confirmationDialog("删除全部未收藏的历史记录？", isPresented: $deleteConfirmation) {
                Button("删除历史记录", role: .destructive) { model.clearHistory() }
                Button("取消", role: .cancel) {}
            } message: { Text("收藏内容将保留，删除后可撤销。") }
    }

    private func preference<Value>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.snapshot.preferences[keyPath: path] }, set: { value in
            var preferences = model.snapshot.preferences
            preferences[keyPath: path] = value
            model.updatePreferences(preferences)
        })
    }

    @ViewBuilder private var general: some View {
        Section("启动") {
            Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        Section("剪贴板") {
            Toggle("记录剪贴板历史", isOn: preference(\.monitoringEnabled))
            Toggle("粘贴到当前应用", isOn: preference(\.pasteToFrontmost))
            Toggle("始终粘贴为纯文本", isOn: preference(\.alwaysPlainText))
            Toggle("复制时播放音效", isOn: preference(\.soundEnabled))
        }
        Section("历史记录") {
            Picker("保留期限", selection: preference(\.retentionDays)) {
                Text("1 天").tag(Int?.some(1))
                Text("1 周").tag(Int?.some(7))
                Text("1 个月").tag(Int?.some(30))
                Text("1 年").tag(Int?.some(365))
                Text("永久").tag(Int?.none)
            }
            Picker("历史记录上限", selection: preference(\.maxHistoryItems)) {
                ForEach([100, 500, 1000, 5000, 10000], id: \.self) { Text("\($0)").tag($0) }
            }
            Button("删除历史记录…", role: .destructive) { deleteConfirmation = true }
        }
        Section("备份") {
            HStack {
                Button("导出备份…", action: model.exportBackup)
                Button("导入备份…", action: model.importBackup)
            }
            Text("备份包含剪贴板内容、收藏夹和设置。") .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var privacy: some View {
        Section("忽略内容") {
            Toggle("忽略机密内容", isOn: preference(\.ignoreConfidential))
            Toggle("忽略临时内容", isOn: preference(\.ignoreTransient))
            Toggle("忽略自动生成的内容", isOn: preference(\.ignoreGenerated))
            Text("不记录应用标记为机密、临时或自动生成的内容。") .font(.caption).foregroundStyle(.secondary)
        }
        Section("忽略的应用") {
            ForEach(model.snapshot.preferences.ignoredBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 10) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
                        Text(url.deletingPathExtension().lastPathComponent)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 26)
                        Text(bundleID)
                    }
                    Spacer()
                    Button {
                        var preferences = model.snapshot.preferences
                        preferences.ignoredBundleIDs.removeAll { $0 == bundleID }
                        model.updatePreferences(preferences)
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("停止忽略此应用")
                }
            }
            Button("添加应用…", action: model.chooseIgnoredApplication)
        }
        Section("暂停收集") {
            if model.isPaused {
                Text("收集已暂停").foregroundStyle(.secondary)
                Button("恢复收集", action: model.resume)
            } else {
                HStack {
                    Button("暂停 15 分钟") { model.pause(minutes: 15) }
                    Button("暂停 1 小时") { model.pause(minutes: 60) }
                    Button("持续暂停") { model.pause(minutes: nil) }
                }
            }
        }
    }

    @ViewBuilder private var shortcuts: some View {
        if let shortcuts = model.toolShortcuts { ToolShortcutsSettingsView(shortcuts: shortcuts) }
        Section("打开窗口") {
            HStack {
                Text("显示剪贴板")
                Spacer()
                Button(recording ? "按下快捷键…" : model.hotKeyDescription) { recordingStack = false; recording.toggle() }
                    .font(.system(.body, design: .monospaced)).frame(minWidth: 120)
                    .background {
                        if recording {
                            ShortcutRecorder { code, flags, description in
                                model.setShortcut(keyCode: code, modifiers: flags, description: description)
                                recording = false
                            } cancel: { recording = false }
                        }
                    }
            }
            HStack {
                Text("显示连续粘贴")
                Spacer()
                Button(recordingStack ? "按下快捷键…" : model.stackHotKeyDescription) { recording = false; recordingStack.toggle() }
                    .font(.system(.body, design: .monospaced)).frame(minWidth: 120)
                    .background {
                        if recordingStack {
                            ShortcutRecorder { code, flags, description in
                                model.setStackShortcut(keyCode: code, modifiers: flags, description: description)
                                recordingStack = false
                            } cancel: { recordingStack = false }
                        }
                    }
            }
            Text("点击快捷键按钮后，按下包含 ⌘、⌥ 或 ⌃ 的组合键。按 Esc 取消。") .font(.caption).foregroundStyle(.secondary)
        }
        Section("面板操作") {
            shortcutRow("搜索", "⌘F")
            shortcutRow("选择上一项 / 下一项", "← / →")
            shortcutRow("粘贴所选卡片", "↩")
            shortcutRow("粘贴为纯文本", "⇧↩")
            shortcutRow("快速粘贴", "⌘1…9")
            shortcutRow("关闭面板", "Esc")
        }
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var integrations: some View {
        Section("本地存储") {
            Text("历史记录保存在此 Mac。可通过菜单栏或快捷键打开剪贴板。")
        }
        Section("系统动作") {
                    Text("在快捷指令中打开剪贴板、搜索、添加文本或复制最新卡片。")
                    Text("可在快捷指令的“打开 URL”动作中使用以下链接。搜索词需进行 URL 编码。")
                        .font(.caption).foregroundStyle(.secondary)
            Text("pasteboard://open\npasteboard://search?query=关键词").font(.caption.monospaced()).textSelection(.enabled)
            Button("打开快捷指令") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") { NSWorkspace.shared.open(url) }
            }
        }
        Section("智能处理") {
            Text(IntelligenceService.availability.message).font(.caption).foregroundStyle(.secondary)
            Text("在文本预览中生成摘要、润色或整理文本。剪贴板的推荐按钮按当前应用和最近使用情况排序。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let mcp { Section("MCP") { MCPSettingsView(service: mcp) } }
        Section("同步与共享") {
            Text("暂不支持 iCloud 同步和共享收藏夹。").foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let captured: (UInt32, UInt32, String) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> RecordingView {
        let view = RecordingView(); view.captured = captured; view.cancel = cancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: RecordingView, context: Context) {}
    final class RecordingView: NSView {
        var captured: ((UInt32, UInt32, String) -> Void)?
        var cancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel?(); return }
            let flags = event.modifierFlags
            guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
            var carbon: UInt32 = 0
            var text = ""
            if flags.contains(.control) { carbon |= 4096; text += "⌃" }
            if flags.contains(.option) { carbon |= 2048; text += "⌥" }
            if flags.contains(.shift) { carbon |= 512; text += "⇧" }
            if flags.contains(.command) { carbon |= 256; text += "⌘" }
            text += event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"
            captured?(UInt32(event.keyCode), carbon, text)
        }
    }
}
