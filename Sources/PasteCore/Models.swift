import Foundation
import CryptoKit

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, image, link, color, file, unknown
    public var displayName: String {
        switch self { case .text: return "文本"; case .image: return "图片"; case .link: return "链接"; case .color: return "颜色"; case .file: return "文件"; case .unknown: return "其他" }
    }
    public var symbolName: String {
        switch self { case .text: return "text.alignleft"; case .image: return "photo"; case .link: return "link"; case .color: return "paintpalette"; case .file: return "doc"; case .unknown: return "doc.on.clipboard" }
    }
}
public struct PasteboardRepresentation: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data
    public var itemIndex: Int
    public init(type: String, data: Data, itemIndex: Int = 0) { self.type = type; self.data = data; self.itemIndex = itemIndex }
}
public struct ClipOCR: Codable, Equatable, Sendable {
    public var text: String
    public var provider: String
    public var createdAt: Date
    public init(text: String, provider: String = "火山 OCR", createdAt: Date = Date()) {
        self.text = text; self.provider = provider; self.createdAt = createdAt
    }
}
public struct ClipTranslation: Codable, Equatable, Sendable {
    public var sourceText: String
    public var translatedText: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var provider: String
    public var model: String
    public var createdAt: Date
    public init(sourceText: String, translatedText: String, sourceLanguage: String, targetLanguage: String, provider: String = "智谱 GLM", model: String, createdAt: Date = Date()) {
        self.sourceText = sourceText; self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.provider = provider; self.model = model; self.createdAt = createdAt
    }
}
public struct ClipEnrichment: Codable, Equatable, Sendable {
    public var ocr: ClipOCR?
    public var translation: ClipTranslation?
    public init(ocr: ClipOCR? = nil, translation: ClipTranslation? = nil) { self.ocr = ocr; self.translation = translation }
    var payloadByteCount: Int {
        let ocrBytes = ocr.map { $0.text.utf8.count + $0.provider.utf8.count + 16 } ?? 0
        let translationBytes = translation.map { $0.sourceText.utf8.count + $0.translatedText.utf8.count + $0.sourceLanguage.utf8.count + $0.targetLanguage.utf8.count + $0.provider.utf8.count + $0.model.utf8.count + 16 } ?? 0
        return ocrBytes + translationBytes
    }
}
public struct ClipDerivation: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case ocr, translation }
    public var sourceItemID: UUID
    public var operation: Operation
    public var provider: String
    public init(sourceItemID: UUID, operation: Operation, provider: String) {
        self.sourceItemID = sourceItemID; self.operation = operation; self.provider = provider
    }
}
public struct ClipItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var title: String
    public var text: String { didSet { fingerprintValue = makeFingerprint() } }
    public var kind: ClipKind { didSet { fingerprintValue = makeFingerprint() } }
    public var sourceBundleID: String
    public var sourceName: String
    public var representations: [PasteboardRepresentation] { didSet { fingerprintValue = makeFingerprint() } }
    public var filePaths: [String] { didSet { fingerprintValue = makeFingerprint() } }
    public var originalRepresentations: [PasteboardRepresentation]?
    public var derivation: ClipDerivation?
    public var enrichment: ClipEnrichment?
    // Value-owned, nonserialized cache: all content writes refresh it, including nested array edits.
    // Metadata changes never hash binary payloads again. No shared mutable cache crosses actors.
    private var fingerprintValue = ""
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, lastCopiedAt, title, text, kind, sourceBundleID, sourceName
        case representations, filePaths, originalRepresentations, enrichment, derivation
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            lastCopiedAt: try values.decode(Date.self, forKey: .lastCopiedAt),
            title: try values.decode(String.self, forKey: .title),
            text: try values.decode(String.self, forKey: .text),
            kind: try values.decode(ClipKind.self, forKey: .kind),
            sourceBundleID: try values.decode(String.self, forKey: .sourceBundleID),
            sourceName: try values.decode(String.self, forKey: .sourceName),
            representations: try values.decode([PasteboardRepresentation].self, forKey: .representations),
            filePaths: try values.decode([String].self, forKey: .filePaths),
            originalRepresentations: try values.decodeIfPresent([PasteboardRepresentation].self, forKey: .originalRepresentations),
            enrichment: try values.decodeIfPresent(ClipEnrichment.self, forKey: .enrichment),
            derivation: try values.decodeIfPresent(ClipDerivation.self, forKey: .derivation)
        )
    }
    public init(id: UUID = UUID(), createdAt: Date = Date(), lastCopiedAt: Date = Date(), title: String = "", text: String, kind: ClipKind, sourceBundleID: String = "", sourceName: String = "", representations: [PasteboardRepresentation] = [], filePaths: [String] = [], originalRepresentations: [PasteboardRepresentation]? = nil, enrichment: ClipEnrichment? = nil, derivation: ClipDerivation? = nil) {
        self.id = id; self.createdAt = createdAt; self.lastCopiedAt = lastCopiedAt; self.title = title
        self.text = text; self.kind = kind; self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        self.representations = representations; self.filePaths = filePaths; self.originalRepresentations = originalRepresentations; self.enrichment = enrichment; self.derivation = derivation
        self.fingerprintValue = makeFingerprint()
    }
    public var characterCount: Int { text.count }
    /// A translation is stale when its exact original differs from current OCR text
    /// (when nonblank), or clipboard text. Missing translations are never stale.
    public var translationIsStale: Bool {
        guard let translation = enrichment?.translation else { return false }
        let ocr = enrichment?.ocr?.text ?? ""
        let source = ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : ocr
        return translation.sourceText != source
    }
    public var fingerprint: String { fingerprintValue }
    private func makeFingerprint() -> String {
        var hasher = SHA256()
        func append(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        append(Data(kind.rawValue.utf8)); append(Data(text.utf8))
        append(Data(String(filePaths.count).utf8))
        for path in filePaths { append(Data(path.utf8)) }
        let sorted = representations.sorted {
            if $0.itemIndex != $1.itemIndex { return $0.itemIndex < $1.itemIndex }
            if $0.type != $1.type { return $0.type < $1.type }
            return $0.data.lexicographicallyPrecedes($1.data)
        }
        append(Data(String(sorted.count).utf8))
        for representation in sorted {
            append(Data(String(representation.itemIndex).utf8))
            append(Data(representation.type.utf8)); append(representation.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
public struct Pinboard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var itemIDs: [UUID]
    public init(id: UUID = UUID(), name: String, colorHex: String = "#F5B64A", itemIDs: [UUID] = []) { self.id = id; self.name = name; self.colorHex = colorHex; self.itemIDs = itemIDs }
}
public struct AppPreferences: Codable, Equatable, Sendable {
    public var monitoringEnabled = true
    public var pasteToFrontmost = true
    public var alwaysPlainText = false
    public var ignoreConfidential = true
    public var ignoreTransient = true
    public var ignoreGenerated = true
    public var ignoredBundleIDs = ["com.apple.keychainaccess"]
    public var retentionDays: Int? = 30
    public var maxHistoryItems = 1000
    public var soundEnabled = false
    public init() {}
}
public struct ClipFilter: Equatable, Sendable {
    public var kind: ClipKind?
    public var sourceBundleID: String?
    public var since: Date?
    public init(kind: ClipKind? = nil, sourceBundleID: String? = nil, since: Date? = nil) { self.kind = kind; self.sourceBundleID = sourceBundleID; self.since = since }
}
public struct SessionState: Codable, Equatable, Sendable {
    public var stackItemIDs: [UUID]
    public var stackReversed: Bool
    public var pauseUntil: Date?
    public var pauseIndefinitely: Bool
    public init(stackItemIDs: [UUID] = [], stackReversed: Bool = false, pauseUntil: Date? = nil, pauseIndefinitely: Bool = false) {
        self.stackItemIDs = stackItemIDs; self.stackReversed = stackReversed
        self.pauseUntil = pauseUntil; self.pauseIndefinitely = pauseIndefinitely
    }
}
public struct ClipboardSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var items: [ClipItem]
    public var pinboards: [Pinboard]
    public var preferences: AppPreferences
    public var session: SessionState?
    public init(version: Int = 1, items: [ClipItem] = [], pinboards: [Pinboard] = [], preferences: AppPreferences = .init(), session: SessionState? = nil) { self.version = version; self.items = items; self.pinboards = pinboards; self.preferences = preferences; self.session = session }
}
public enum ContentClassifier {
    public static func classify(text: String, filePaths: [String] = [], hasImage: Bool = false) -> ClipKind {
        if !filePaths.isEmpty { return .file }
        if hasImage { return .image }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown }
        if trimmed.range(of: "^#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) != nil { return .color }
        if !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil { return .link }
        return .text
    }
}
