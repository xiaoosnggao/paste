import Foundation
import Combine
import LinkPresentation

@MainActor
final class LinkPreviewService: ObservableObject {
    struct Preview { let title: String; let url: URL }
    @Published private(set) var preview: Preview?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    private var provider: LPMetadataProvider?
    private var generation = UUID()
    private static var cache: [URL: (Preview, Date)] = [:]
    static func allowedURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    func load(_ text: String) {
        cancel(); preview = nil; errorMessage = nil
        guard let url = Self.allowedURL(text) else { errorMessage = "仅支持 HTTP / HTTPS 网页链接。"; return }
        let now = Date()
        Self.cache = Self.cache.filter { now.timeIntervalSince($0.value.1) < 600 }
        if let cached = Self.cache[url] { preview = cached.0; return }
        let token = UUID(); generation = token
        let fetcher = LPMetadataProvider()
        fetcher.timeout = 8
        fetcher.shouldFetchSubresources = false
        provider = fetcher; loading = true
        fetcher.startFetchingMetadata(for: url) { [weak self] metadata, error in
            let title = String((metadata?.title ?? "").prefix(500))
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.provider = nil; self.loading = false
                guard failure == nil, !title.isEmpty else { self.errorMessage = failure ?? "此网页未提供预览信息。"; return }
                let value = Preview(title: title, url: url)
                if Self.cache.count >= 20, let oldest = Self.cache.min(by: { $0.value.1 < $1.value.1 })?.key { Self.cache.removeValue(forKey: oldest) }
                Self.cache[url] = (value, Date()); self.preview = value
            }
        }
    }
    func reset() { cancel(); preview = nil; errorMessage = nil }
    func cancel() { generation = UUID(); provider?.cancel(); provider = nil; loading = false }
}
