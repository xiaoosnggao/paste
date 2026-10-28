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
    /// Right column in the preview (suggestions, recognition). Shared by every
    /// item kind so the column sits at the same x and width for text and images.
    static let sideColumnWidth: CGFloat = 300
    /// Diameter of a title-bar glass button.
    static let glassButtonSize: CGFloat = 24
    /// Outer height of a title-bar glass control (pill height = circle diameter).
    static var glassControlHeight: CGFloat { glassButtonSize + 4 }
    /// Vertical center of the traffic lights in a full-size-content window.
    static let trafficLightCenterY: CGFloat = 16
}

/// Title-bar toolbar controls in the macOS 26 Liquid Glass style: buttons sit on one
/// shared glass capsule; older systems get a quiet material capsule instead.
struct PopupGlassToolbar<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let row = HStack(spacing: 0) { content }.padding(.horizontal, 2).frame(height: PopupMetrics.glassControlHeight)
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                GlassEffectContainer { row.glassEffect(.regular, in: Capsule()) }
            } else {
                row.background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .fixedSize()
    }
}

/// A single round glass control (e.g. the ⋯ menu): a true circle, the same diameter as the pill.
struct PopupGlassCircle<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let d = PopupMetrics.glassControlHeight
        let core = content.frame(width: d, height: d).contentShape(Circle()).clipShape(Circle())
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                GlassEffectContainer { core.glassEffect(.regular, in: Circle()) }
            } else {
                core.background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .frame(width: d, height: d)
        .fixedSize()
    }
}

/// Icon button inside a `PopupGlassToolbar`. No focus ring; hover is a soft circle.
struct PopupToolbarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) { PopupToolbarGlyph(symbol: symbol, hovering: hovering && isEnabled) }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
            .help(label).accessibilityLabel(label)
    }
}

struct PopupToolbarGlyph: View {
    let symbol: String
    var hovering = false
    var body: some View {
        Image(systemName: symbol).font(.scaled(.label, weight: .semibold))
            .foregroundStyle(PanelPalette.text)
            .frame(width: PopupMetrics.glassButtonSize, height: PopupMetrics.glassButtonSize)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
            .contentShape(Circle())
    }
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
                // Opaque card one step lighter than the tinted window, so it reads in both modes.
                shape.fill(scheme == .dark ? PanelPalette.surface : Color.white)
                    // Shadow on the card shape only, so text inside stays crisp.
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 10, y: 3)
                if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.10 : 0.06)) }
            }
            .overlay {
                shape.strokeBorder(focused ? PanelPalette.accent.opacity(0.55) : Color.primary.opacity(scheme == .dark ? 0.10 : 0.09),
                                   lineWidth: focused ? 1.5 : 1)
            }
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
        .modifier(GlassTrack())
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

/// The segmented control's track: Liquid Glass on macOS 26, a recessed capsule before.
private struct GlassTrack: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
        }
    }
}
