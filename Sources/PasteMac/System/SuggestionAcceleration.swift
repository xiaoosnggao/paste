import CryptoKit
import Foundation
import PasteCore

/// Instant, on-device suggestions shown before (or instead of) the AI reply.
enum RuleSuggestions {
    static func make(text raw: String, kind: String) -> [ContextSuggestion] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var picks: [(String, String, SuggestionAction)] = []
        let lines = text.components(separatedBy: .newlines)
        let isURL = kind == ClipKind.link.rawValue || (text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil)
        let isJSON = (text.hasPrefix("{") || text.hasPrefix("[")) && (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
        let codeMarkers = ["func ", "def ", "class ", "import ", "return ", "const ", "let ", "var ", "=>", "};", "#include", "SELECT ", "public "]
        let isCode = !isJSON && lines.count >= 2 && codeMarkers.filter({ text.contains($0) }).count >= 2
        let isTable = lines.count >= 2 && lines.prefix(6).allSatisfy { $0.contains("\t") || $0.filter({ $0 == "," }).count >= 2 }
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let mostlyChinese = letters > 0 && Double(cjk) / Double(letters) > 0.3
        if isURL {
            picks = [("生成 Markdown 链接", "整理成 [标题](链接) 格式", .format), ("提取链接参数", "列出域名、路径和查询参数", .extract), ("解释这个链接", "说明链接可能指向的内容", .explain)]
        } else if isJSON {
            picks = [("格式化 JSON", "缩进整理层级，保留全部字段", .format), ("压缩 JSON", "去掉多余空白，便于粘贴", .format), ("解释字段", "用中文说明各字段含义", .explain)]
        } else if isCode {
            picks = [("解释代码", "用中文说明这段代码做什么", .explain), ("检查问题", "找出潜在错误并给出修正", .fix), ("添加注释", "为关键步骤补充简短注释", .rewrite)]
        } else if isTable {
            picks = [("转为 Markdown 表格", "按列整理成 Markdown 表格", .format), ("总结表格", "概括表格中的关键数据", .summarize), ("提取列", "按列拆出并逐行列出", .extract)]
        } else if mostlyChinese {
            picks = [("翻译成英文", "译成自然流畅的英文", .translate), ("润色文字", "让表达更通顺、专业", .rewrite)]
            if text.count > 160 { picks.insert(("总结要点", "提炼几条核心要点", .summarize), at: 1) } else { picks.append(("修正错别字", "纠正错字和标点", .fix)) }
        } else {
            picks = [("翻译成中文", "译成通顺的中文", .translate), ("修正语法", "纠正拼写和语法错误", .fix)]
            if text.count > 300 { picks.insert(("总结要点", "用中文提炼核心要点", .summarize), at: 1) } else { picks.append(("改写得更正式", "调整为正式的商务语气", .rewrite)) }
        }
        return picks.enumerated().map { index, pick in
            ContextSuggestion(id: "rule-\(index)-\(pick.0)", title: pick.0,
                              instruction: pick.2.instruction(title: pick.0, detail: pick.1), detail: pick.1, origin: .rule)
        }
    }
}

/// Suggestions remembered across launches, keyed by content hash, target app and model.
/// Only titles, details and instructions are stored, never the copied text itself.
@MainActor
final class SuggestionDiskCache {
    struct Entry: Codable { var key: String; var rows: [Row]; var savedAt: Date }
    struct Row: Codable { var title: String; var detail: String; var instruction: String }
    static let capacity = 200
    private let url: URL?
    private var entries: [Entry]

    /// A nil directory keeps the cache in memory only (demo and self-check models).
    init(directory: URL?) {
        url = directory?.appendingPathComponent("suggestion-cache.json")
        entries = url.flatMap { try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: $0)) } ?? []
    }

    static func key(text: String, targetBundleID: String, service: AIServiceConfig) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return [digest, targetBundleID.isEmpty ? "*" : targetBundleID, service.id.uuidString, service.translationModel].joined(separator: "|")
    }

    func lookup(text: String, targetBundleID: String, service: AIServiceConfig) -> [ContextSuggestion]? {
        let exact = Self.key(text: text, targetBundleID: targetBundleID, service: service)
        let any = Self.key(text: text, targetBundleID: "", service: service)
        guard let entry = entries.last(where: { $0.key == exact }) ?? entries.last(where: { $0.key == any }) else { return nil }
        return entry.rows.map { ContextSuggestion(id: UUID().uuidString, title: $0.title, instruction: $0.instruction, detail: $0.detail) }
    }

    func store(_ suggestions: [ContextSuggestion], text: String, targetBundleID: String, service: AIServiceConfig) {
        let rows = suggestions.filter { $0.origin == .ai }.map { Row(title: $0.title, detail: $0.detail, instruction: $0.instruction) }
        guard !rows.isEmpty else { return }
        let key = Self.key(text: text, targetBundleID: targetBundleID, service: service)
        entries.removeAll { $0.key == key }
        entries.append(.init(key: key, rows: rows, savedAt: Date()))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        save()
    }

    func remove(text: String, targetBundleID: String, service: AIServiceConfig) {
        let keys = [Self.key(text: text, targetBundleID: targetBundleID, service: service), Self.key(text: text, targetBundleID: "", service: service)]
        entries.removeAll { keys.contains($0.key) }
        save()
    }

    func removeAll() { entries = []; save() }
    var count: Int { entries.count }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

enum SuggestionPrecompute {
    static let maximumCharacters = 4000

    /// Only plain text and links that do not look like secrets are sent ahead of time.
    static func eligible(_ item: ClipItem) -> Bool {
        guard item.kind == .text || item.kind == .link else { return false }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= maximumCharacters else { return false }
        let markers = ["Concealed", "Transient", "AutoGenerated"]
        guard !item.representations.contains(where: { rep in markers.contains { rep.type.contains($0) } }) else { return false }
        return !looksSensitive(text)
    }

    static func looksSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if ["-----begin", "password", "passwd", "密码", "secret", "api_key", "apikey", "token="].contains(where: { lowered.contains($0) }) { return true }
        // A single long token that mixes letters, digits and symbols is probably a key or password.
        if !text.contains(where: { $0.isWhitespace }), text.count >= 12, text.count <= 128 {
            let hasDigit = text.contains(where: \.isNumber), hasLetter = text.contains(where: \.isLetter)
            let hasSymbol = text.contains(where: { !$0.isLetter && !$0.isNumber })
            if hasDigit && hasLetter && (hasSymbol || text.count >= 20), !text.hasPrefix("http") { return true }
        }
        return false
    }
}
