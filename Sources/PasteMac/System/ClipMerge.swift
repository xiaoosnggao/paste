import AppKit
import Foundation
import PasteCore

/// 多条合成一条: how several selected cards become one new card.
/// The local modes never leave the Mac; the AI modes use the AI service configured in Settings.
enum ClipMergeMode: String, CaseIterable, Identifiable, Sendable {
    case lines, paragraphs, bullets, minutes, email, points
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: return "逐行拼接"
        case .paragraphs: return "分段拼接"
        case .bullets: return "合成列表"
        case .minutes: return "整理成纪要"
        case .email: return "写成邮件"
        case .points: return "提炼要点"
        }
    }
    var symbol: String {
        switch self {
        case .lines: return "text.append"
        case .paragraphs: return "text.justify.left"
        case .bullets: return "list.bullet"
        case .minutes: return "doc.text"
        case .email: return "envelope"
        case .points: return "sparkles"
        }
    }
    var usesAI: Bool { self == .minutes || self == .email || self == .points }
    static var local: [Self] { allCases.filter { !$0.usesAI } }
    static var ai: [Self] { allCases.filter(\.usesAI) }

    /// The instruction for AI modes. The model only sees the selected cards' text.
    var suggestion: ContextSuggestion? {
        switch self {
        case .minutes:
            return .init(id: "merge-minutes", title: "合成纪要",
                         instruction: "把所选内容整理成一份中文会议纪要：主题、要点、结论、待办（负责人和时间如有）。保留数字、日期、链接和专名，不编造内容，只输出纪要正文。")
        case .email:
            return .init(id: "merge-email", title: "合成邮件",
                         instruction: "根据所选内容写一封简洁、礼貌的邮件：主题行、称呼、正文分段、结尾。沿用材料的主要语言，保留数字、日期、链接和专名，不编造事实，只输出邮件。")
        case .points:
            return .init(id: "merge-points", title: "合成要点",
                         instruction: "合并所选内容中重复的信息，提炼成不超过八条的要点列表，每条一行，以“- ”开头。冲突的信息并列保留并注明来源。")
        default: return nil
        }
    }

    /// Joins texts locally. Empty parts are dropped; surrounding whitespace is trimmed.
    func join(_ parts: [String]) -> String {
        let texts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch self {
        case .lines: return texts.joined(separator: "\n")
        case .bullets: return texts.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
        default: return texts.joined(separator: "\n\n")
        }
    }

    /// The text a card contributes: its text, or recognized text for images.
    static func text(of item: ClipItem) -> String {
        switch item.kind {
        case .image: return item.enrichment?.ocr?.text ?? ""
        case .file: return item.filePaths.joined(separator: "\n")
        default: return item.text
        }
    }

    /// Cards in the order they were copied (oldest first), which reads naturally after merging.
    static func ordered(_ items: [ClipItem]) -> [ClipItem] {
        items.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
}

extension AppModel {
    /// Cards in the current multi-selection that have text to merge.
    var mergeableSelection: [ClipItem] {
        ClipMergeMode.ordered(selectedItems).filter { !ClipMergeMode.text(of: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var canMergeSelection: Bool { selectedIDs.count > 1 && mergeableSelection.count > 1 && mergeInProgress == nil }
    var mergeAIServiceName: String? { contextSuggestionService?.name }

    func mergeSelection(_ mode: ClipMergeMode) {
        let items = mergeableSelection
        guard selectedIDs.count > 1, items.count > 1, mergeInProgress == nil else {
            statusMessage = "请至少选择两项含文字的内容（图片需先识别文字）。"; return
        }
        if !mode.usesAI {
            saveMerged(mode.join(items.map(ClipMergeMode.text(of:))), title: "合并 \(items.count) 项", sources: items, provider: "本机")
            return
        }
        guard let service = contextSuggestionService, let suggestion = mode.suggestion else {
            statusMessage = "请先在设置中启用 AI 服务。"; return
        }
        let cards = items.map { card -> MultiCardContextCard in
            let text = ClipMergeMode.text(of: card)
            return .init(id: card.id, version: card.fingerprint + text, text: text, sourceName: card.sourceName,
                         sourceBundleID: card.sourceBundleID, copiedAt: card.lastCopiedAt, missingReason: nil)
        }
        let target = pasteEngine.target
        let input = MultiCardContextInput(cards: cards, targetName: target?.name ?? "", targetBundleID: target?.bundleID ?? "")
        let operations = suggestionOperations
        mergeInProgress = mode
        statusMessage = "正在用 \(service.name) \(mode.title)…"
        mergeTask = Task { @MainActor [weak self] in
            do {
                let text = try await operations.transformMultiple(input, suggestion, service)
                try Task.checkCancellation()
                guard let self else { return }
                self.mergeInProgress = nil; self.mergeTask = nil
                self.saveMerged(ContextSuggestionsService.removingFence(text), title: suggestion.title, sources: items, provider: service.name)
            } catch is CancellationError {
                self?.mergeInProgress = nil; self?.mergeTask = nil
            } catch {
                self?.mergeInProgress = nil; self?.mergeTask = nil
                self?.statusMessage = "合成失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelMerge() {
        mergeTask?.cancel(); mergeTask = nil; mergeInProgress = nil
        statusMessage = nil
    }

    @discardableResult
    func saveMerged(_ text: String, title: String, sources: [ClipItem], provider: String) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2 * 1024 * 1024 else {
            statusMessage = "合成结果为空或过大。"; return nil
        }
        let result = ClipItem(title: title, text: text, kind: .text,
                              sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: provider,
                              representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))],
                              derivation: .init(sourceItemIDs: sources.map(\.id), operation: .merge, provider: provider))
        let next = SnapshotOperations.capture(result, in: snapshot)
        guard let stored = next.items.first(where: { $0.fingerprint == result.fingerprint && $0.derivation == result.derivation }),
              commit(next, action: "合成一条") else { return nil }
        if !historyResultIDs.contains(stored.id) { historyResultIDs.insert(stored.id, at: 0) }
        selectedIDs = [stored.id]
        statusMessage = "已把 \(sources.count) 项合成一条，可按 ⌘Z 撤销。"
        return stored
    }
}
