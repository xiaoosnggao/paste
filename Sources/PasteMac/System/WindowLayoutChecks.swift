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

        // The popover opens above its tab; its fields must fit its height cap.
        let popover = CategoryClassificationSettings.self
        try check(popover.popoverMaxHeight <= PanelPresentation.baseHeight - DesignTokens.Space.lg,
                  "classification popover (\(popover.popoverMaxHeight)pt) is taller than the \(PanelPresentation.baseHeight)pt panel")
        let fields = CategoryClassificationFields(description: .constant("项目报价、付款条件和交付安排，以及验收标准与发票信息"),
                                                  keywords: .constant("报价，合同"))
            .frame(width: popover.popoverWidth - WindowMetrics.contentPadding * 2)
        let host = NSHostingView(rootView: fields)
        let needed = (host.fittingSize.height + WindowMetrics.contentPadding * 2
                      + (popover.rowHeight + WindowMetrics.sectionSpacing) * 2).rounded(.up)
        try check(needed <= popover.popoverMaxHeight, "classification fields need \(needed)pt but the popover allows \(popover.popoverMaxHeight)pt")
        return count
    }
}
#endif
