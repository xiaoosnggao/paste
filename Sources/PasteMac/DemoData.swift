import AppKit
import PasteCore

enum DemoData {
    static func snapshot() -> ClipboardSnapshot {
        func text(_ value: String, app: String, bundle: String, seconds: Double, title: String = "") -> ClipItem {
            ClipItem(createdAt: Date().addingTimeInterval(-seconds), lastCopiedAt: Date().addingTimeInterval(-seconds),
                     title: title.isEmpty ? value : title, text: value, kind: ContentClassifier.classify(text: value),
                     sourceBundleID: bundle, sourceName: app,
                     representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))])
        }
        var items = [
            text("把灵感留在手边。\n下一次粘贴，更进一步。", app: "备忘录", bundle: "com.apple.Notes", seconds: 12),
            text("https://developer.apple.com/swift/", app: "Safari", bundle: "com.apple.Safari", seconds: 120, title: "Swift — Apple Developer"),
            text("#5B8DEF", app: "预览", bundle: "com.apple.Preview", seconds: 340),
            text("设计不是装饰，是让每一步都自然。\n\n· 保留内容的原始格式\n· 整理常用片段\n· 用键盘快速完成", app: "Pages", bundle: "com.apple.iWork.Pages", seconds: 720),
            text("let idea = clipboard.latest\nlet next = idea.makeSomething()", app: "Xcode", bundle: "com.apple.dt.Xcode", seconds: 1800),
            text("会议安排\n周三 10:00 · 产品讨论\n周五 15:00 · 设计评审", app: "日历", bundle: "com.apple.iCal", seconds: 3200)
        ]
        let image = NSImage(size: NSSize(width: 520, height: 360))
        image.lockFocus()
        NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 520, height: 360)).fill()
        let gradient = NSGradient(starting: .systemBlue, ending: .systemPurple)
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(x: 55, y: 40, width: 340, height: 340)), angle: 30)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 300, y: 60, width: 150, height: 150)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 130, width: 460, height: 110), xRadius: 12, yRadius: 12).fill()
        ("Hello world\nClipboard test 2026" as NSString).draw(at: NSPoint(x: 50, y: 145), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .medium), .foregroundColor: NSColor.black])
        image.unlockFocus()
        if let data = image.tiffRepresentation {
            items.insert(ClipItem(createdAt: Date().addingTimeInterval(-40), lastCopiedAt: Date().addingTimeInterval(-40), title: "灵感画板", text: "", kind: .image,
                                  sourceBundleID: "com.apple.Preview", sourceName: "预览", representations: [.init(type: NSPasteboard.PasteboardType.tiff.rawValue, data: data)]), at: 1)
        }
        let inspiration = Pinboard(name: "灵感", colorHex: "#F5B64A", itemIDs: Array(items.prefix(3)).map(\.id))
        let work = Pinboard(name: "工作", colorHex: "#B784EB", itemIDs: Array(items.suffix(3)).map(\.id))
        if let file = Bundle.main.url(forResource: "PreviewSample", withExtension: "txt") {
            items.append(ClipItem(title: "Quick Look 演示文件", text: "", kind: .file,
                                  sourceBundleID: "com.apple.finder", sourceName: "Finder",
                                  representations: [.init(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(file.absoluteString.utf8))], filePaths: [file.path]))
        }
        var preferences = AppPreferences()
        preferences.pasteToFrontmost = false
        return ClipboardSnapshot(items: items, pinboards: [inspiration, work], preferences: preferences)
    }
}
