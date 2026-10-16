import Foundation

public enum LocalTextAction: String, CaseIterable, Identifiable, Sendable {
    case links = "提取链接", emails = "提取邮箱", clean = "清理空白"
    public var id: String { rawValue }
}
public enum TextTools {
    public enum Failure: LocalizedError {
        case tooLong
        public var errorDescription: String? { "文本超过 100 KB，请选取部分文字后重试。" }
    }
    public static func apply(_ action: LocalTextAction, to text: String) throws -> String {
        guard text.utf8.count <= 100_000 else { throw Failure.tooLong }
        if action == .clean {
            return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pattern = action == .links ? #"https?://[^\s<>\"']+"# : #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        let matches = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            var value = String(text[range])
            if action == .links {
                while let last = value.last, ").,;!，。；！）".contains(last) { value.removeLast() }
                guard let url = URL(string: value), url.host != nil else { return nil }
            }
            return seen.insert(value).inserted ? value : nil
        }
        return matches.joined(separator: "\n")
    }
    public static func recommended(_ items: [ClipItem], for bundleID: String?, limit: Int = 9, now: Date = Date()) -> [ClipItem] {
        func score(_ item: ClipItem) -> Double {
            let source = bundleID != nil && !item.sourceBundleID.isEmpty && item.sourceBundleID == bundleID ? 30.0 : 0
            let age = max(0, now.timeIntervalSince(item.lastCopiedAt))
            return source + 20 / (1 + age / 3600)
        }
        return items.enumerated().sorted {
            let left = score($0.element), right = score($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.prefix(max(0, min(limit, 100))).map(\.element)
    }
}
