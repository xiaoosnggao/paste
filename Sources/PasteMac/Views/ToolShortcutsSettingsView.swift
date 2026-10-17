import SwiftUI
import Carbon

struct ToolShortcutsSettingsView: View {
    @ObservedObject var shortcuts: ToolShortcutManager
    @State private var recording: ToolAction?
    var body: some View {
        Section("识别与翻译") {
            Text("快捷键默认关闭。点击建议快捷键，或录制自定义组合以启用。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ToolAction.allCases) { action in
                HStack {
                    Label(action.title, systemImage: action.symbol)
                    Spacer()
                    let binding = shortcuts.bindings[action] ?? ToolShortcut()
                    Toggle("启用", isOn: Binding(get: { shortcuts.bindings[action]?.enabled ?? false }, set: { _ = shortcuts.setEnabled(action, $0) }))
                        .labelsHidden().disabled(binding.keyCode == nil)
                    Button(recording == action ? "按下快捷键…" : binding.description) { recording = recording == action ? nil : action }
                        .frame(minWidth: 100)
                        .background {
                            if recording == action {
                                ShortcutRecorder { key, modifiers, description in
                                    _ = shortcuts.configure(action, keyCode: key, modifiers: modifiers, description: description)
                                    recording = nil
                                } cancel: { recording = nil }
                                .frame(width: 0, height: 0)
                            }
                        }
                    Button(action.suggestedDescription) {
                        recording = nil
                        _ = shortcuts.configure(action, keyCode: action.suggestedKeyCode, modifiers: UInt32(controlKey | optionKey), description: action.suggestedDescription)
                    }.help("设置并启用建议快捷键")
                    Button { shortcuts.clear(action); recording = nil } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).disabled(binding.keyCode == nil).help("清除快捷键")
                }
            }
            Text("在其他应用中选中文字后，按快捷键翻译。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = shortcuts.errorMessage { Text(message).foregroundStyle(.red).font(.caption) }
        }
    }
}
