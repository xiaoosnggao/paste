import AppKit
import SwiftUI
import PasteCore

/// The detail layer above the deck. It replaces the editor, smart and tool
/// windows when they start from the panel, so the panel stays the one place
/// a card is worked on. Tools started by a global shortcut still use their window.
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
            }
        }
        .id(detail)
        .frame(maxWidth: PanelDetailLayout.maxContentWidth)
        .frame(height: model.panelDetailContentHeight)
        .background(PanelPalette.canvas.opacity(reduceTransparency ? 1 : 0.86), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.xl).strokeBorder(PanelPalette.border.opacity(0.45), lineWidth: 0.75) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
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
    let content: Content
    let footer: Footer

    init(model: AppModel, item: ClipItem?, page: PanelDetailPage, title: String, subtitle: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.model = model
        self.item = item
        self.page = page
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
                .font(.scaled(.body))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, DesignTokens.Space.lg)
                .padding(.vertical, DesignTokens.Space.md)
            Divider().opacity(0.45)
            HStack(spacing: DesignTokens.Space.sm) { footer }
                .font(.scaled(.body))
                .controlSize(.regular)
                .padding(.horizontal, DesignTokens.Space.lg)
                .frame(height: PanelDetailLayout.footerHeight)
        }
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.accent)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            Button { model.closePanelDetail() } label: {
                Image(systemName: "xmark").font(.scaled(.label, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(PanelPalette.secondaryText)
            .help("关闭详情 (Esc)").accessibilityLabel("关闭详情")
            if let item { SourceIcon(item: item).frame(width: 20, height: 20).accessibilityHidden(true) }
            Text(title).font(.scaled(.label, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.scaled(.caption)).foregroundStyle(PanelPalette.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: DesignTokens.Space.md)
            if let item { PanelDetailPageBar(model: model, item: item, current: page) }
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .frame(height: PanelDetailLayout.headerHeight)
    }
}

/// The pages available for a card. Unavailable pages are hidden, matching the context menu.
struct PanelDetailPageBar: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    let current: PanelDetailPage

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            ForEach(PanelDetailPage.allCases.filter { $0.isAvailable(for: item) }) { page in
                let selected = page == current
                Button { model.showDetailPage(page, for: item) } label: {
                    Label(page.title, systemImage: page.systemImage)
                        .font(.scaled(.label, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, DesignTokens.Space.sm).padding(.vertical, DesignTokens.Space.xs)
                        .background(selected ? PanelPalette.hover : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? PanelPalette.text : PanelPalette.secondaryText)
                .help("\(page.title) (\(page.shortcutLabel))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
