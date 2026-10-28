import Foundation

/// A short message shown at the bottom of the clipboard panel.
///
/// Typed cases replace the old string comparison against "已复制", so a
/// confirmation can be styled and timed differently from a failure.
enum PanelNotice: Equatable {
    /// The selection was written to the clipboard.
    case copied
    /// Neutral status that clears itself.
    case info(String)
    /// A failure the user should read; stays until dismissed or replaced.
    case error(String)

    static let copiedText = "已复制"

    var text: String {
        switch self {
        case .copied: return Self.copiedText
        case .info(let text), .error(let text): return text
        }
    }

    /// How long the notice stays visible, or nil when it waits for the user.
    var autoDismissDelay: Duration? {
        switch self {
        case .copied: return .milliseconds(1500)
        case .info: return .seconds(4)
        case .error: return nil
        }
    }

    /// Bridges legacy `statusMessage` writes: the copy confirmation keeps its
    /// own case; any other free-form message is treated as a failure, which
    /// matches how existing call sites use it.
    init(legacyMessage: String) {
        self = legacyMessage == Self.copiedText ? .copied : .error(legacyMessage)
    }
}
