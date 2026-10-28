import AppKit
import SwiftUI

/// Layout shared by the windows and sheets opened from a card's context menu.
enum WindowMetrics {
    /// The drawn title strip. Windows hide their native title and use a
    /// full-size content view, so the traffic lights sit inside this strip.
    static let titleBarHeight: CGFloat = 44
    /// Clears the close, minimize and zoom buttons.
    static let trafficLightInset: CGFloat = 76
    static let contentPadding = DesignTokens.Space.lg
    static let sectionSpacing = DesignTokens.Space.md
    static let footerHeight: CGFloat = 52
    static let footerSpacing = DesignTokens.Space.sm
    /// Space taken by the title strip, the footer and their dividers.
    static var chromeHeight: CGFloat { titleBarHeight + footerHeight }
}

/// Title strip, padded content and a footer with the window's actions.
///
/// Put the primary button last in the footer and give it `.windowPrimaryAction()`
/// so Return triggers it; give Cancel or Close `.windowCancelAction()` so Esc does.
struct WindowScaffold<Accessory: View, Content: View, Footer: View>: View {
    enum Chrome {
        /// A titled window: the title strip clears the traffic lights.
        case window
        /// A sheet: no traffic lights, the title lines up with the content.
        case sheet
    }

    let title: String
    var subtitle: String?
    /// Quiet line centered in a window's title bar, between the traffic lights and the toolbar.
    var caption: String?
    var chrome: Chrome
    /// Content scrolls when the window or sheet is too short for it.
    var scrolls: Bool
    let accessory: Accessory
    let content: Content
    let footer: Footer
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ title: String, subtitle: String? = nil, caption: String? = nil, chrome: Chrome = .window, scrolls: Bool = false,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.caption = caption
        self.chrome = chrome
        self.scrolls = scrolls
        self.accessory = accessory()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if chrome == .sheet { Divider().opacity(0.45) }
            Group {
                if scrolls {
                    ScrollView { paddedContent }.scrollIndicators(.automatic)
                } else {
                    paddedContent.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            if chrome == .sheet { Divider().opacity(0.45) }
            HStack(spacing: WindowMetrics.footerSpacing) { footer }
                .font(.scaled(.body))
                .controlSize(.regular)
                .padding(.horizontal, WindowMetrics.contentPadding)
                .frame(height: WindowMetrics.footerHeight)
        }
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
        .ignoresSafeArea(.container, edges: chrome == .window ? .top : [])
        .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency && chrome == .window ? 1 : 0))
    }

    private var paddedContent: some View {
        content
            .font(.scaled(.body))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(WindowMetrics.contentPadding)
    }

    private var titleBar: some View {
        HStack(spacing: WindowMetrics.footerSpacing) {
            // Windows carry no title text: the traffic lights and the content speak for themselves.
            if chrome == .sheet {
            Text(title).font(.scaled(.label, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .help(title).layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText).lineLimit(1).truncationMode(.tail)
                    .help(subtitle)
            }
            }
            Spacer(minLength: WindowMetrics.footerSpacing)
            accessory.fixedSize()
        }
        .padding(.leading, chrome == .window ? WindowMetrics.trafficLightInset : WindowMetrics.contentPadding)
        .padding(.trailing, chrome == .window ? DesignTokens.Space.md : WindowMetrics.contentPadding)
        .frame(height: WindowMetrics.titleBarHeight)
        .overlay {
            if chrome == .window, let caption, !caption.isEmpty {
                Text(caption).font(.scaled(.caption, weight: .medium)).foregroundStyle(PanelPalette.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(caption)
                    .padding(.horizontal, 140).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension WindowScaffold where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, chrome: Chrome = .window, scrolls: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(title, subtitle: subtitle, chrome: chrome, scrolls: scrolls, accessory: { EmptyView() }, content: content, footer: footer)
    }
}

extension View {
    /// The window's main action: accent fill, triggered by Return.
    func windowPrimaryAction() -> some View {
        primaryActionStyle().keyboardShortcut(.defaultAction)
    }

    /// Accent capsule that stays legible in non-key windows and the non-activating panel,
    /// where `.borderedProminent` falls back to a pale bezel under white text.
    func primaryActionStyle(fill: Color = PanelPalette.accent) -> some View {
        buttonStyle(PrimaryActionButtonStyle(fill: fill))
    }

    /// Cancel or Close, triggered by Esc.
    func windowCancelAction() -> some View {
        keyboardShortcut(.cancelAction)
    }

    /// A recessed area for text, lists and images inside a glass window.
    func windowWell(padding: CGFloat = DesignTokens.Space.md) -> some View {
        modifier(WindowWell(padding: padding))
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var fill: Color = PanelPalette.accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    func makeBody(configuration: Configuration) -> some View {
        let compact = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.scaled(compact ? .caption : .label, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(PanelPalette.onAccent)
            .padding(.horizontal, compact ? DesignTokens.Space.sm : DesignTokens.Space.md)
            .frame(minHeight: compact ? 22 : 28)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .fixedSize()
            .contentShape(Capsule())
    }
}

/// Status text at the leading edge of a footer.
struct WindowFooterNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText)
            .lineLimit(1).truncationMode(.tail).help(text)
    }
}

/// Section caption inside window content.
struct WindowSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.scaled(.caption, weight: .semibold)).foregroundStyle(PanelPalette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Closes the window that holds the button. Used for windows without a Cancel.
struct WindowCloseButton: View {
    var title = "关闭"
    var body: some View {
        Button(title) { NSApp.keyWindow?.performClose(nil) }.windowCancelAction()
    }
}

private struct WindowWell: ViewModifier {
    let padding: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.45), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
    }
}
