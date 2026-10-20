import AppKit
import PasteCore

struct ContextSuggestionProgressReporter: Sendable {
    let report: @Sendable (Int, Int) async -> Void
}

struct ContextSuggestionOperations: Sendable {
    var suggest: @Sendable (ContextSuggestionInput, AIServiceConfig) async throws -> [ContextSuggestion]
    var transform: @Sendable (ContextSuggestionInput, ContextSuggestion, AIServiceConfig) async throws -> String

    var summarize: @Sendable (MultiCardContextInput, AIServiceConfig) async throws -> MultiCardContextSummary
    var transformMultiple: @Sendable (MultiCardContextInput, ContextSuggestion, AIServiceConfig) async throws -> String
    var summarizeReporting: @Sendable (MultiCardContextInput, AIServiceConfig, ContextSuggestionProgressReporter) async throws -> MultiCardContextSummary

    init(suggest: @escaping @Sendable (ContextSuggestionInput, AIServiceConfig) async throws -> [ContextSuggestion],
         transform: @escaping @Sendable (ContextSuggestionInput, ContextSuggestion, AIServiceConfig) async throws -> String,
         summarize: @escaping @Sendable (MultiCardContextInput, AIServiceConfig) async throws -> MultiCardContextSummary = { try await ContextSuggestionsService().summarize(input: $0, service: $1) },
         transformMultiple: @escaping @Sendable (MultiCardContextInput, ContextSuggestion, AIServiceConfig) async throws -> String = { try await ContextSuggestionsService().transform(input: $0, suggestion: $1, service: $2) },
         summarizeReporting: (@Sendable (MultiCardContextInput, AIServiceConfig, ContextSuggestionProgressReporter) async throws -> MultiCardContextSummary)? = nil) {
        self.suggest = suggest; self.transform = transform; self.summarize = summarize; self.transformMultiple = transformMultiple
        self.summarizeReporting = summarizeReporting ?? { input, service, _ in try await summarize(input, service) }
    }

    static func live(service: ContextSuggestionsService = ContextSuggestionsService()) -> Self {
        .init(suggest: { try await service.suggest(input: $0, service: $1) },
              transform: { try await service.transform(input: $0, suggestion: $1, service: $2) },
              summarize: { try await service.summarize(input: $0, service: $1) },
              transformMultiple: { try await service.transform(input: $0, suggestion: $1, service: $2) },
              summarizeReporting: { input, configuration, reporter in
                  try await service.summarize(input: input, service: configuration, progress: reporter.report)
              })
    }
}

struct ContextSuggestionRequestKey: Equatable, Sendable {
    var itemID: UUID
    var fingerprint: String
    var input: ContextSuggestionInput
    var service: AIServiceConfig
    var targetPID: pid_t?
    var targetLaunchDate: Date?
    var cards: [MultiCardContextCard] = []
    var multiInput: MultiCardContextInput { .init(cards: cards, targetName: input.targetName, targetBundleID: input.targetBundleID) }
}

extension AppModel {
    var contextSuggestionsPresented: Bool { contextSuggestionsVisible || contextSuggestionsLoading }

    var contextSuggestionService: AIServiceConfig? {
        let available = toolConfiguration.aiServices.filter {
            $0.isEnabled && !$0.translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var service: AIServiceConfig?
        if let selectedID = toolConfiguration.translationAIServiceID {
            service = available.first { $0.id == selectedID }
        } else {
            service = available.first
        }
        // Vision settings do not affect text suggestions or invalidate their cache.
        service?.ocrModel = ""
        return service
    }

    func currentContextSuggestionKey() -> ContextSuggestionRequestKey? {
        guard suggestionSessionActive, toolConfiguration.contextSuggestionsEnabled,
              (!isDemo || suggestionOperationsInjected), !isPasting, !toolBusy,
              !selectedIDs.isEmpty, let item = selectedItems.first,
              (selectedItems.count > 1 || (!item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.kind != .image && item.kind != .file)),
              let service = contextSuggestionService else { return nil }
        let cards: [MultiCardContextCard] = selectedItems.count > 1 ? selectedItems.map { card in
            let text = card.enrichment?.ocr?.text ?? (card.kind == .image || card.kind == .file ? "" : card.text)
            let missing = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (card.kind == .image ? "图片尚未识别文字" : "没有可提取的正文") : nil
            return .init(id: card.id, version: card.fingerprint + text, text: text, sourceName: card.sourceName,
                         sourceBundleID: card.sourceBundleID, copiedAt: card.lastCopiedAt, missingReason: missing)
        } : []
        let target = pasteEngine.target
        return .init(itemID: item.id, fingerprint: item.fingerprint,
                     input: .init(text: item.text, kind: item.kind.rawValue,
                                  sourceName: item.sourceName, sourceBundleID: item.sourceBundleID,
                                  targetName: target?.name ?? "", targetBundleID: target?.bundleID ?? ""),
                     service: service, targetPID: target?.pid, targetLaunchDate: target?.launchDate, cards: cards)
    }

    func scheduleContextSuggestions() {
        guard !contextSuggestionMutationInProgress, !isPasting else { return }
        guard let key = currentContextSuggestionKey() else {
            clearContextSuggestions()
            return
        }
        guard dismissedContextSuggestionKey != key else { return }
        guard contextSuggestionKey != key else { return }
        clearContextSuggestions(keepVisible: true)
        contextSuggestionKey = key
        if !key.cards.isEmpty, key.cards.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            contextSuggestionsError = "所选卡片没有可读取的正文。图片需先识别文字，文件需先提取内容。"
            setContextSuggestionsVisible(true)
            return
        }
        guard !key.cards.isEmpty || (key.input.text.count <= 8192 && key.input.text.utf8.count <= 32_768) else {
            contextSuggestionsError = "文字过长，请缩短至 8,192 字以内。"
            setContextSuggestionsVisible(true)
            return
        }
        if !key.cards.isEmpty, let cached = multiCardSummaryCache.first(where: { $0.0 == key })?.1 {
            multiCardSummary = cached; contextSuggestions = cached.suggestions
            setContextSuggestionsVisible(true); return
        }
        if let cached = contextSuggestionCache.first(where: { $0.0 == key })?.1 {
            contextSuggestions = cached
            setContextSuggestionsVisible(true)
            return
        }
        contextSuggestionsLoading = true
        let generation = contextSuggestionGeneration
        let operations = suggestionOperations, delay = key.cards.isEmpty ? suggestionDelayNanoseconds : max(suggestionDelayNanoseconds, 500_000_000)
        contextSuggestionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                let summary: MultiCardContextSummary?
                let suggestions: [ContextSuggestion]
                if key.cards.isEmpty {
                    summary = nil; suggestions = try await operations.suggest(key.input, key.service)
                } else {
                    self?.contextSuggestionProgress = "正在整理 \(key.cards.count) 项内容…"
                    let reporter = ContextSuggestionProgressReporter { [weak self] done, total in
                        await self?.updateContextSuggestionProgress(done: done, total: total, key: key, generation: generation)
                    }
                    let result = try await operations.summarizeReporting(key.multiInput, key.service, reporter)
                    summary = result; suggestions = result.suggestions
                }
                guard let self, self.contextSuggestionIsCurrent(key, generation: generation) else { return }
                self.multiCardSummary = summary
                self.contextSuggestionProgress = nil
                if let summary {
                    self.multiCardSummaryCache.removeAll { $0.0 == key }
                    self.multiCardSummaryCache.append((key, summary))
                    if self.multiCardSummaryCache.count > 12 { self.multiCardSummaryCache.removeFirst() }
                }
                self.contextSuggestions = Array(suggestions.prefix(5))
                self.setContextSuggestionsVisible(true)
                self.contextSuggestionsLoading = false
                self.contextSuggestionTask = nil
                if suggestions.isEmpty { self.contextSuggestionsError = "暂无建议，请重试。" }
                else {
                    self.contextSuggestionCache.removeAll { $0.0 == key }
                    self.contextSuggestionCache.append((key, self.contextSuggestions))
                    if self.contextSuggestionCache.count > 24 { self.contextSuggestionCache.removeFirst() }
                }
            } catch {
                guard let self, self.contextSuggestionIsCurrent(key, generation: generation) else { return }
                self.contextSuggestionProgress = nil
                self.contextSuggestionsError = error is CancellationError ? nil : error.localizedDescription
                if !(error is CancellationError) { self.setContextSuggestionsVisible(true) }
                self.contextSuggestionsLoading = false
                self.contextSuggestionTask = nil
            }
        }
    }

    func invalidateContextSuggestionCache() {
        contextSuggestionCache = []; multiCardSummaryCache = []
        retryContextSuggestions()
    }

    func retryContextSuggestions() {
        // Dismissal clears the active key; an explicit retry must still bypass its cache.
        if let key = contextSuggestionKey ?? currentContextSuggestionKey() ?? dismissedContextSuggestionKey {
            contextSuggestionCache.removeAll { $0.0 == key }
            multiCardSummaryCache.removeAll { $0.0 == key }
        }
        dismissedContextSuggestionKey = nil
        clearContextSuggestions(keepVisible: true)
        scheduleContextSuggestions()
    }

    func dismissContextSuggestions() {
        dismissedContextSuggestionKey = contextSuggestionKey
        clearContextSuggestions()
    }

    func applyContextSuggestion(_ suggestion: ContextSuggestion) {
        guard contextSuggestionApplyingID == nil, !contextSuggestionsLoading,
              let key = contextSuggestionKey, currentContextSuggestionKey() == key,
              contextSuggestions.contains(where: { $0 == suggestion }) else { return }
        contextSuggestionTask?.cancel()
        contextSuggestionGeneration = UUID()
        let generation = contextSuggestionGeneration, operations = suggestionOperations
        contextSuggestionApplyingID = suggestion.id
        contextSuggestionsError = nil
        contextSuggestionTask = Task { @MainActor [weak self] in
            do {
                let text: String
                if key.cards.isEmpty { text = try await operations.transform(key.input, suggestion, key.service) }
                else { text = try await operations.transformMultiple(key.multiInput, suggestion, key.service) }
                guard let self, self.contextSuggestionIsCurrent(key, generation: generation) else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finishContextSuggestionFailure("处理结果为空，请重试。")
                    return
                }
                guard text.utf8.count <= 2 * 1024 * 1024 else {
                    self.finishContextSuggestionFailure("处理结果超过 2 MB。")
                    return
                }
                if !key.cards.isEmpty {
                    self.contextSuggestionApplyingID = nil; self.contextSuggestionTask = nil
                    let result = ContextSuggestionPreviewResult(id: UUID(), title: suggestion.title, text: text,
                                                               sourceIDs: key.cards.map(\.id), provider: key.service.name)
                    self.onSuggestionPreview?(result)
                    return
                }
                let result = ClipItem(title: suggestion.title, text: text, kind: .text,
                                      sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard",
                                      sourceName: key.service.name,
                                      representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))],
                                      derivation: .init(sourceItemID: key.itemID, operation: .aiTransform, provider: key.service.name))
                let next = SnapshotOperations.capture(result, in: self.snapshot)
                guard next.items.contains(where: { $0.id == key.itemID }),
                      let stored = next.items.first(where: { $0.fingerprint == result.fingerprint && $0.derivation == result.derivation }) else {
                    self.finishContextSuggestionFailure("历史容量不足，请清理后重试。")
                    return
                }
                // The snapshot observer must not schedule a second request for our own save.
                self.contextSuggestionMutationInProgress = true
                let committed = self.commit(next, action: "保存 AI 处理结果")
                self.contextSuggestionMutationInProgress = false
                guard committed else {
                    self.finishContextSuggestionFailure(self.statusMessage ?? "结果未保存。")
                    return
                }
                // Release the paste guard, but retain visible content until the panel exits.
                self.contextSuggestionApplyingID = nil
                self.contextSuggestionMutationInProgress = true
                self.activate(stored)
                self.contextSuggestionMutationInProgress = false
            } catch {
                guard let self, self.contextSuggestionIsCurrent(key, generation: generation) else { return }
                self.finishContextSuggestionFailure(error is CancellationError ? "处理已取消。" : error.localizedDescription)
            }
        }
    }

    private func updateContextSuggestionProgress(done: Int, total: Int, key: ContextSuggestionRequestKey, generation: UUID) {
        guard contextSuggestionIsCurrent(key, generation: generation) else { return }
        contextSuggestionProgress = done == total ? "正在合并摘要…" : "已处理 \(done) / \(total) 段"
    }

    private func contextSuggestionIsCurrent(_ key: ContextSuggestionRequestKey, generation: UUID) -> Bool {
        !Task.isCancelled && contextSuggestionGeneration == generation && contextSuggestionKey == key
            && currentContextSuggestionKey() == key
    }

    private func finishContextSuggestionFailure(_ message: String) {
        contextSuggestionApplyingID = nil
        contextSuggestionTask = nil
        contextSuggestionsError = message
    }

    private func clearContextSuggestions(keepVisible: Bool = false) {
        if keepVisible, contextSuggestionsPresented { setContextSuggestionsVisible(true) }
        contextSuggestionGeneration = UUID()
        contextSuggestionTask?.cancel()
        contextSuggestionTask = nil
        contextSuggestionKey = nil
        contextSuggestions = []
        contextSuggestionsLoading = false
        contextSuggestionApplyingID = nil
        contextSuggestionsError = nil
        multiCardSummary = nil; multiCardSummaryExpanded = false; contextSuggestionProgress = nil
        if !keepVisible { setContextSuggestionsVisible(false) }
    }

    @discardableResult
    func saveContextSuggestionPreview(_ preview: ContextSuggestionPreviewResult, text: String, paste: Bool = false) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2 * 1024 * 1024,
              !preview.sourceIDs.isEmpty else { return false }
        let result = ClipItem(title: preview.title, text: text, kind: .text,
                              sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: preview.provider,
                              representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))],
                              derivation: .init(sourceItemIDs: preview.sourceIDs, operation: .aiTransform, provider: preview.provider))
        let next = SnapshotOperations.capture(result, in: snapshot)
        guard let stored = next.items.first(where: { $0.fingerprint == result.fingerprint && $0.derivation == result.derivation }),
              commit(next, action: "保存多卡处理结果") else { return false }
        if paste {
            contextSuggestionMutationInProgress = true
            activate(stored)
            contextSuggestionMutationInProgress = false
        }
        else { statusMessage = "已保存" }
        return true
    }

    private func setContextSuggestionsVisible(_ visible: Bool) {
        guard contextSuggestionsVisible != visible else { return }
        contextSuggestionsVisible = visible
        onSuggestionPanelChange?(contextSuggestionsPresented)
    }
}
