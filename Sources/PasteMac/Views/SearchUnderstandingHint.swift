import SwiftUI

/// A quiet capsule beside the search field that reads back what a plain-language
/// query was understood as, e.g. “✦ 上周 · 来自 微信 · 按意思”.
struct SearchUnderstandingHint: View {
    let understanding: SearchUnderstanding
    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Image(systemName: understanding.symbol)
                .font(.scaled(.caption, weight: .semibold))
                .foregroundStyle(understanding.ranking == .semantic ? PanelPalette.accent : PanelPalette.secondaryText)
            Text(understanding.label)
                .font(.scaled(.caption, weight: .medium))
                .foregroundStyle(PanelPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .frame(height: PanelMetrics.controlSize - 6)
        .background(PanelPalette.raised, in: Capsule())
        .fixedSize()
        .help(understanding.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(understanding.help)
    }
}
