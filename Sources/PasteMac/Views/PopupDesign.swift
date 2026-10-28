import AppKit
import SwiftUI

/// The look shared by the popup windows (preview, 编辑, 翻译, 智能):
/// no title text, content running up under a transparent title bar, soft
/// rounded cards on the window's glass, and a floating toolbar with one accent action.
enum PopupMetrics {
    /// Title strip that holds only the traffic lights and the page switcher.
    static let topBarHeight: CGFloat = 52
    static let margin: CGFloat = 20
    static let gap: CGFloat = 12
    static let toolbarHeight: CGFloat = 56
}

extension View {
    /// A soft content card: a light lift off the glass, no hard border.
    func popupCard(padding: CGFloat = DesignTokens.Space.lg, tint: Color? = nil, focused: Bool = false) -> some View {
        modifier(PopupCard(padding: padding, tint: tint, focused: focused))
    }
}

private struct PopupCard: ViewModifier {
    let padding: CGFloat
    let tint: Color?
    let focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        content
            .padding(padding)
            .background {
                shape.fill(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : (scheme == .dark ? 0.32 : 0.78)))
                if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.10 : 0.06)) }
            }
            .overlay {
                shape.strokeBorder(focused ? PanelPalette.accent.opacity(0.55) : Color.primary.opacity(scheme == .dark ? 0.08 : 0.05),
                                   lineWidth: focused ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.06), radius: 10, y: 3)
    }
}

/// Icon + label segments on a recessed capsule track; the current one is raised.
struct PopupSegmentedControl<Value: Hashable & Identifiable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String
    var help: (Value) -> String = { _ in "" }
    let select: (Value) -> Void
    @Environment(\.colorScheme) private var scheme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button { if !selected { select(option) } } label: {
                    Label(title(option), systemImage: symbol(option))
                        .font(.scaled(.label, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? PanelPalette.text : PanelPalette.secondaryText)
                        .padding(.horizontal, DesignTokens.Space.md)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(scheme == .dark ? 0.22 : 1))
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
        .fixedSize()
    }
}

/// Round, quiet icon button for card corners and toolbars.
struct PopupIconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(.label, weight: .medium))
                .foregroundStyle(active ? PanelPalette.accent : PanelPalette.secondaryText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(active ? PanelPalette.accent.opacity(0.14) : (hovering ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

/// Text button for secondary actions in a popup toolbar.
struct PopupSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.scaled(.label, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(PanelPalette.text)
            .padding(.horizontal, DesignTokens.Space.md)
            .frame(minHeight: 28)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (scheme == .dark ? 0.10 : 0.06))))
            .opacity(isEnabled ? 1 : 0.45)
            .fixedSize()
            .contentShape(Capsule())
    }
}

extension View {
    func popupSecondaryStyle() -> some View { buttonStyle(PopupSecondaryButtonStyle()) }
}

/// A calm placeholder: a symbol in a soft circle, a line and an optional hint.
struct PopupEmptyState: View {
    let symbol: String
    let title: String
    var hint: String?
    var busy = false
    var body: some View {
        VStack(spacing: DesignTokens.Space.sm) {
            ZStack {
                Circle().fill(PanelPalette.accent.opacity(0.10)).frame(width: 52, height: 52)
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.scaled(.title, weight: .medium)).foregroundStyle(PanelPalette.accent) }
            }
            Text(title).font(.scaled(.body, weight: .medium)).foregroundStyle(PanelPalette.secondaryText)
            if let hint { Text(hint).font(.scaled(.caption)).foregroundStyle(.tertiary) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small caption above a card's content, with optional trailing controls.
struct PopupCardHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    let trailing: Trailing
    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.symbol = symbol; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            if let symbol { Image(systemName: symbol).font(.scaled(.caption, weight: .semibold)) }
            Text(title).font(.scaled(.caption, weight: .semibold))
            Spacer(minLength: DesignTokens.Space.sm)
            trailing
        }
        .foregroundStyle(PanelPalette.secondaryText)
        .frame(height: 28)
        .accessibilityAddTraits(.isHeader)
    }
}

extension PopupCardHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) { self.init(title, symbol: symbol) { EmptyView() } }
}
