import AppKit
import SwiftUI
import PasteCore

/// The detail layer above the deck. It replaces the editor, smart and tool
/// windows when they start from the panel, so the panel stays the one place
/// a card is worked on. Tools started by a global shortcut still use their window.
/// The detail window's root: follows the model so page switches reuse the window.
struct PanelDetailWindowView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let detail = model.panelDetail { PanelDetailView(model: model, detail: detail) }
        else { Color.clear }
    }
}

struct PanelDetailView: View {
    @ObservedObject var model: AppModel
    let detail: PanelDetailState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            switch detail.page {
            // Preview never opens here; openPanelDetail sends it to the window.
            case .preview, .edit: EditorView(model: model, itemID: detail.itemID)
            case .translate: QuickToolView(model: model, hosted: true)
            case .intelligence: IntelligenceView(model: model, itemID: detail.itemID)
            case .suggestions: EmptyView() // opens the preview window instead
            }
        }
        .id(detail)
        // A standalone window above the panel; the window's glass is the only background.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("卡片详情")
    }
}

/// Header with the card and its pages, content, and a footer of actions.
struct PanelDetailScaffold<Content: View, Footer: View>: View {
    @ObservedObject var model: AppModel
    let item: ClipItem?
    let page: PanelDetailPage
    let title: String
    var subtitle: String?
    /// Hidden when it would only be an empty bar.
    var showsFooter = true
    let content: Content
    let footer: Footer

    init(model: AppModel, item: ClipItem?, page: PanelDetailPage, title: String, subtitle: String? = nil, showsFooter: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.model = model
        self.item = item
        self.page = page
        self.title = title
        self.subtitle = subtitle
        self.showsFooter = showsFooter
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .font(.scaled(.body))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, PopupMetrics.margin)
                .padding(.top, DesignTokens.Space.xs)
                .padding(.bottom, showsFooter ? 0 : PopupMetrics.margin)
            if showsFooter {
                // Floating toolbar: no divider, the content cards end above it.
                HStack(spacing: DesignTokens.Space.sm) { footer }
                    .font(.scaled(.body))
                    .controlSize(.regular)
                    .padding(.horizontal, PopupMetrics.margin)
                    .frame(height: PopupMetrics.toolbarHeight)
            }
        }
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
    }

    /// Only the traffic lights and the page switcher; the window says nothing else up here.
    private var header: some View {
        ZStack {
            if let item {
                PanelDetailPageBar(model: model, item: item, current: page)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, WindowMetrics.trafficLightInset)
        // Centered on the traffic lights' line, like the preview's toolbar.
        .frame(height: PopupMetrics.trafficLightCenterY * 2)
        .frame(height: PopupMetrics.topBarHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.map { "\(title)：\(Self.cardTitle($0))" } ?? title)
    }

    static func cardTitle(_ item: ClipItem) -> String {
        let raw = item.title.isEmpty ? String(item.text.prefix(80)) : item.title
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? item.kind.displayName : line
    }
}

/// The pages available for a card. Unavailable pages are hidden, matching the context menu.
struct PanelDetailPageBar: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    let current: PanelDetailPage

    var body: some View {
        PopupSegmentedControl(options: PanelDetailPage.layerPages.filter { $0.isAvailable(for: item) },
                              selection: current,
                              title: { $0.title }, symbol: { $0.systemImage },
                              help: { "\($0.title) (\($0.shortcutLabel))" },
                              select: { model.showDetailPage($0, for: item) })
    }
}
