import Foundation

public enum DeepLinkCommand: Equatable, Sendable {
    case open, search(String), add(text: String, title: String), copy(UUID)
}
public enum DeepLinkParser {
    public enum Failure: LocalizedError {
        case invalid
        public var errorDescription: String? { "无效的 Pasteboard 链接或参数。" }
    }
    public static func parse(_ url: URL) throws -> DeepLinkCommand {
        guard url.scheme?.lowercased() == "pasteboard", let action = url.host?.lowercased(),
              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Failure.invalid }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value, !value.contains("\0") else { throw Failure.invalid }
            values[item.name] = value
        }
        switch action {
        case "open": guard values.isEmpty else { throw Failure.invalid }; return .open
        case "search":
            guard Set(values.keys) == ["query"], let query = values["query"], query.utf8.count <= 1024 else { throw Failure.invalid }
            return .search(query)
        case "add":
            guard Set(values.keys).isSubset(of: ["text", "title"]), let text = values["text"], !text.isEmpty,
                  text.utf8.count <= 2 * 1024 * 1024, (values["title"] ?? "").utf8.count <= 1024 else { throw Failure.invalid }
            return .add(text: text, title: values["title"] ?? "")
        case "copy":
            guard Set(values.keys) == ["id"], let value = values["id"], let id = UUID(uuidString: value) else { throw Failure.invalid }
            return .copy(id)
        default: throw Failure.invalid
        }
    }
}
