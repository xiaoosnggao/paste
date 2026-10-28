import CoreGraphics

/// Layout constants for the clipboard panel.
///
/// The vertical metrics must add up to `PanelPresentation.baseHeight`; the
/// native self-test checks this so the two values cannot drift apart.
enum PanelMetrics {
    // Panel frame
    static let panelTopPadding: CGFloat = 14
    static let panelBottomPadding: CGFloat = 10
    static let panelCornerRadius: CGFloat = 25
    static let toolbarHeight: CGFloat = 32
    static let toolbarDeckSpacing: CGFloat = 12
    static let deckHeight: CGFloat = 252

    // Toolbar
    static let controlSize: CGFloat = 32
    static let toolbarSpacing: CGFloat = 8
    static let toolbarTrailingPadding: CGFloat = 22

    // Card deck
    static let deckSpacing: CGFloat = 14
    static let deckHorizontalPadding: CGFloat = 20
    /// Room for the card shadow (radius 6, y 3 → about 9pt below the card);
    /// the deck's ScrollView clips anything drawn outside this padding.
    static let deckVerticalPadding: CGFloat = 10

    // Clip card
    static let cardWidth: CGFloat = 230
    static let cardHeight: CGFloat = 232
    static let cardCornerRadius: CGFloat = 12
    static let cardHeaderHeight: CGFloat = 48
    static let cardContentPadding: CGFloat = 16

    static var verticalContentHeight: CGFloat {
        panelTopPadding + toolbarHeight + toolbarDeckSpacing + deckHeight + panelBottomPadding
    }
}
