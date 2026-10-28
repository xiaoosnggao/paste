#if DEBUG
import Foundation
import PasteCore

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
        return 3
    }
}
#endif
