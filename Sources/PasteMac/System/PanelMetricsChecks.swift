#if DEBUG
import Foundation
import PasteCore

/// Pure checks for panel layout metrics and card accessibility labels.
@MainActor
enum PanelMetricsChecks {
    static func run() throws -> Int {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: message) }
        }
        try check(PanelMetrics.verticalContentHeight == PanelPresentation.baseHeight,
                  "panel metrics do not add up to PanelPresentation.baseHeight")
        try check(PanelMetrics.cardHeight + PanelMetrics.deckVerticalPadding * 2 == PanelMetrics.deckHeight,
                  "clip card height does not fit the deck")
        try check(PanelMetrics.toolbarHeight == PanelMetrics.controlSize, "toolbar height differs from control size")
        // The card shadow (radius 6, y 3) needs ~9pt below the card or the deck's ScrollView clips it.
        try check(PanelMetrics.deckVerticalPadding >= 9, "deck padding too small for the card shadow")

        let bare = ClipItem(text: "  第一行\n第二行  ", kind: .text)
        try check(bare.accessibilitySummary == "文本，第一行 第二行", "card label kept empty source or newlines: \(bare.accessibilitySummary)")
        let sourced = ClipItem(title: "会议纪要", text: "正文", kind: .text, sourceName: "备忘录")
        try check(sourced.accessibilitySummary == "文本，备忘录，会议纪要", "card label lost source or title")
        let file = ClipItem(text: "", kind: .file, filePaths: ["/tmp/报告.pdf"])
        try check(file.accessibilitySummary == "文件，报告.pdf", "file card label missing file name")
        let image = ClipItem(text: "", kind: .image)
        try check(image.accessibilitySummary == "图片", "image card label has stray separators")
        try check(String(ClipItem(text: String(repeating: "长", count: 100), kind: .text).accessibilitySummary.dropFirst(3)).count == 40,
                  "card label preview is not truncated")
        return 9
    }
}
#endif
