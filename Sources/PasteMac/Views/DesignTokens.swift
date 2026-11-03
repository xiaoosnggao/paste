import SwiftUI

/// The app's type, radius and spacing scales.
///
/// Views pick a step from these scales instead of a raw number, so sizes stay
/// consistent across the panel, the quick tool and settings. CI rejects new
/// `.system(size: <number>)` and `cornerRadius: <number>` literals outside
/// this file.
enum DesignTokens {
    /// Point sizes for text and SF Symbols.
    enum TextSize: CGFloat {
        /// Badges, timestamps, keyboard hints.
        case micro = 10
        /// Secondary lines, metadata, notices.
        case caption = 11
        /// Control labels, card headers, tabs.
        case label = 12
        /// Body text, list rows, editors.
        case body = 13
        /// Card and section titles, toolbar symbols.
        case title = 15
        /// Toolbar overflow symbol, onboarding step titles.
        case heading = 19
        /// Window and empty-hero headlines.
        case display = 22
        /// Large illustrative symbols (empty states, file cards).
        case hero = 36
    }

    enum Radius {
        /// Skeleton bars and other tiny fills.
        static let xs: CGFloat = 4
        /// Small controls and chips.
        static let sm: CGFloat = 6
        /// Buttons, rows, fields.
        static let md: CGFloat = 8
        /// Cards, banners, grouped containers.
        static let lg: CGFloat = 12
        /// Large swatches and previews.
        static let xl: CGFloat = 20
        /// Floating glass windows (quick tool, onboarding).
        static let window: CGFloat = 14
        /// The clipboard panel itself.
        static let panel: CGFloat = 25
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }
}

extension Font {
    /// A system font at a step of the app's type scale.
    static func scaled(_ size: DesignTokens.TextSize, weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
    }
}
