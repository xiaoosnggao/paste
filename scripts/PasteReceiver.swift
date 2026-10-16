import AppKit

/// A deliberately separate acceptance fixture. Clipboard access occurs only in user actions.
@MainActor
final class ReceiverTextView: NSTextView {
    var operation: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        super.paste(sender)
        operation?("paste")
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        operation?("copy")
    }
}

@MainActor
final class ReceiverDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private let first = ReceiverTextView()
    private let second = ReceiverTextView()
    private let result = NSTextField(wrappingLabelWithString: "实际插入内容：空")
    private let counters = NSTextField(labelWithString: "粘贴次数：0 · 复制次数：0")
    private let richStatus = NSTextField(labelWithString: "富文本属性：空")
    private let markerLabel = NSTextField(wrappingLabelWithString: "测试标记：尚未生成")
    private var pasteCount = 0
    private var copyCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pasteboard 真实粘贴验收接收器"
        window.setAccessibilityIdentifier("paste-acceptance-receiver")
        window.minSize = NSSize(width: 640, height: 560)
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        body.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            body.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            body.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "独立应用 · 普通文本 / 富文本 / 焦点验收")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        body.addArrangedSubview(title)
        body.addArrangedSubview(markerLabel)
        let buttons = NSStackView(views: [
            button("生成测试标记并清空主输入框", action: #selector(seed)),
            button("打开 Pasteboard", action: #selector(openPasteboard)),
            button("激活此验收窗口", action: #selector(activateReceiver))
        ])
        buttons.spacing = 10
        body.addArrangedSubview(buttons)
        body.addArrangedSubview(NSTextField(labelWithString: "主输入框（默认粘贴目标）"))
        let primary = makeScroll(first, identifier: "receiver-primary-input")
        body.addArrangedSubview(primary)
        primary.heightAnchor.constraint(equalToConstant: 155).isActive = true
        body.addArrangedSubview(NSTextField(labelWithString: "第二输入框（点击后验证焦点保持）"))
        let secondary = makeScroll(second, identifier: "receiver-secondary-input")
        body.addArrangedSubview(secondary)
        secondary.heightAnchor.constraint(equalToConstant: 95).isActive = true
        body.addArrangedSubview(counters)
        body.addArrangedSubview(richStatus)
        result.setAccessibilityIdentifier("receiver-inserted-content")
        result.isSelectable = true
        body.addArrangedSubview(result)
        body.addArrangedSubview(NSView())
        for view in [markerLabel, primary, secondary, result] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40).isActive = true
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(first)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func makeScroll(_ textView: ReceiverTextView, identifier: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .systemFont(ofSize: 15)
        textView.delegate = self
        textView.setAccessibilityIdentifier(identifier)
        textView.setAccessibilityLabel(identifier == "receiver-primary-input" ? "主输入框" : "第二输入框")
        textView.operation = { [weak self] operation in
            guard let self else { return }
            if operation == "paste" { self.pasteCount += 1 } else { self.copyCount += 1 }
            self.refresh()
        }
        scroll.documentView = textView
        return scroll
    }

    func textDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        counters.stringValue = "粘贴次数：\(pasteCount) · 复制次数：\(copyCount)"
        if let storage = first.textStorage, storage.length > 0 {
            let attributes = storage.attributes(at: 0, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
            let color = attributes[.foregroundColor] as? NSColor
            richStatus.stringValue = "主输入框首字属性：粗体 \(bold ? "是" : "否") · 字号 \(Int(font?.pointSize ?? 0)) · 颜色 \(color?.description ?? "默认")"
        } else {
            richStatus.stringValue = "富文本属性：空"
        }
        result.stringValue = "主输入框全文：\n\(first.string.isEmpty ? "（空）" : first.string)\n第二输入框全文：\n\(second.string.isEmpty ? "（空）" : second.string)"
    }

    @objc private func seed() {
        let marker = "Pasteboard-验收-\(UUID().uuidString)"
        let rich = NSAttributedString(string: marker, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 17),
            .foregroundColor: NSColor.systemPurple
        ])
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(marker, forType: .string)
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        board.writeObjects([item])
        first.string = ""
        markerLabel.stringValue = "测试标记：\(marker)（剪贴板同时包含纯文本和紫色粗体 RTF）"
        refresh()
        window.makeFirstResponder(first)
    }

    @objc private func openPasteboard() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Users/gaoxs/Documents/project/paste/dist/Pasteboard.app"),
                                           configuration: configuration) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.markerLabel.stringValue = "打开失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func activateReceiver() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出验收接收器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = applicationMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

@main
enum PasteReceiver {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ReceiverDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
