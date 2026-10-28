#if DEBUG
import AppKit
import SwiftUI

/// Checks for the shared window scaffold and the classification sheet size.
@MainActor
enum WindowLayoutChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Window layout: " + message) }; count += 1
        }
        try check(WindowMetrics.trafficLightInset >= 70, "title strip overlaps the traffic lights")
        try check(WindowMetrics.titleBarHeight >= 32, "title strip shorter than the native title bar")
        try check(WindowMetrics.chromeHeight == WindowMetrics.titleBarHeight + WindowMetrics.footerHeight + 2,
                  "chrome height out of sync with its parts")

        // The sheet hangs from the panel's top edge, so it must be shorter than the panel.
        let sheet = CategoryClassificationSettings.self
        try check(sheet.sheetHeight <= PanelPresentation.baseHeight - DesignTokens.Space.lg,
                  "classification sheet (\(sheet.sheetHeight)pt) runs past the \(PanelPresentation.baseHeight)pt panel")
        let fields = CategoryClassificationFields(description: .constant("项目报价、付款条件和交付安排，以及验收标准与发票信息"),
                                                  keywords: .constant("报价，合同"))
            .frame(width: sheet.sheetWidth - WindowMetrics.contentPadding * 2)
        let host = NSHostingView(rootView: fields)
        let needed = (host.fittingSize.height + WindowMetrics.contentPadding * 2 + WindowMetrics.chromeHeight).rounded(.up)
        try check(needed <= sheet.sheetHeight, "classification fields need \(needed)pt but the sheet is \(sheet.sheetHeight)pt")
        return count
    }
}
#endif
