import AppKit
import PasteCore

struct ToolOperations: Sendable {
    var recognize: @Sendable (Data, CloudToolConfiguration) async throws -> CloudOCRResponse
    var translate: @Sendable (String, CloudToolConfiguration) async throws -> CloudTranslationResponse
    static func live(service: CloudToolsService = CloudToolsService()) -> Self {
        return .init(recognize: { data, configuration in
            if configuration.ocrProvider == .system && configuration.ocrAIServiceID == nil { return try await service.recognize(image: data, configuration: configuration) }
            let work = Task.detached(priority: .utility) { try OCRImagePreparation.uploadData(data) }
            let payload = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            return try await service.recognize(image: payload, configuration: configuration)
        },
                     translate: { try await service.translate(text: $0, configuration: $1) })
    }
}

extension AppModel {
    func cancelAutoTranslation() {
        autoTranslationGeneration = UUID()
        autoTranslationTask?.cancel()
        autoTranslationTask = nil
    }

    /// Only native user edits call this; OCR and card loading never schedule uploads.
    func editToolInput(_ text: String, isComposing: Bool) {
        cancelAutoTranslation()
        if toolBusy && (toolInputText != text || isComposing) { cancelToolOperation() }
        if toolInputText != text { toolError = nil; toolStatus = nil }
        toolInputIsComposing = isComposing
        toolInputText = text
        guard !isComposing, !isPasting, !toolBusy,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf8.count <= 2 * 1024 * 1024 else { toolError = "文字超过 2 MB，请分段翻译。"; return }
        let configuration = toolConfiguration, itemID = toolItemID
        if let completed = completedToolTranslation, completed.text == text,
           completed.configuration.hasSameToolSettings(as: configuration), completed.itemID == itemID,
           activeToolItem?.enrichment?.translation?.sourceText == text { return }
        let revision = autoTranslationGeneration, generation = toolGeneration
        let delay = autoTranslationDelayNanoseconds
        autoTranslationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.autoTranslationGeneration == revision else { return }
            self.autoTranslationTask = nil
            guard self.toolGeneration == generation, self.toolInputText == text, self.toolItemID == itemID,
                  self.toolConfiguration.hasSameToolSettings(as: configuration), !self.toolBusy, !self.isPasting else { return }
            self.translateToolInput()
        }
    }

    var activeToolItem: ClipItem? { toolItemID.flatMap { id in snapshot.items.first { $0.id == id } } }
    var toolTranslationIsStale: Bool {
        guard let translation = activeToolItem?.enrichment?.translation else { return false }
        return translation.sourceText != toolInputText || translation.sourceLanguage != toolConfiguration.sourceLanguage
            || translation.targetLanguage != toolConfiguration.targetLanguage || translation.provider != toolConfiguration.translationProviderTitle
    }
    /// All settings surfaces share this path. Initial configuration loading has no active input.
    func refreshToolAfterConfigurationChange(recognizeImage: Bool) {
        guard toolSessionActive, !toolInputIsComposing, !isPasting,
              activeToolItem?.kind == .image || !toolInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelToolOperation()
        if recognizeImage, let item = activeToolItem, item.kind == .image {
            recognizeItem(item, translateAfter: true)
        } else {
            translateToolInput()
        }
    }
    var toolSourceText: String {
        guard let item = activeToolItem else { return toolInputText }
        return item.enrichment?.ocr?.text ?? item.text
    }
    func performTool(_ action: ToolAction) {
        guard contextSuggestionApplyingID == nil else { return }
        dismissContextSuggestions()
        guard !isPasting else { notice = .info("正在粘贴，请稍后重试。"); return }
        onToolStart?()
        switch action {
        case .screenshotOCR, .screenshotTranslate:
            lastToolOperation = .screenshotTranslate; onScreenshotTool?(true)
        case .selectionTranslate:
            cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolStatus = nil; toolError = nil
            lastToolOperation = action; onSelectionTool?()
        case .inputTranslate:
            cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolStatus = nil; toolError = nil
            lastToolOperation = action; onShowTools?()
        case .clipboardTranslate:
            lastToolOperation = action
            // Only this explicit command reads current clipboard text. No history is uploaded.
            guard let text = bridge.currentText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolError = "剪贴板中没有可翻译的文字。"; onShowTools?(); return
            }
            cancelToolOperation(); toolItemID = nil; toolInputText = text; lastToolOperation = action
            onShowTools?(); translateToolInput()
        }
    }
    func beginSelectedTextTranslation(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolStatus = nil
            toolError = "未选中文字。"; onShowTools?(); return
        }
        cancelToolOperation(); toolItemID = nil; toolInputText = text; toolError = nil
        lastToolOperation = .selectionTranslate; onShowTools?(); translateToolInput()
    }
    func showToolItem(_ item: ClipItem) {
        onToolStart?()
        cancelToolOperation()
        guard let current = materializedItems([item]).first else { return }
        if !isDemo {
            loadingHistoryWindow = true
            snapshot.items = snapshot.items.map { $0.id == current.id ? current : $0 }
            loadingHistoryWindow = false
        }
        toolItemID = current.id; toolInputText = current.enrichment?.ocr?.text ?? current.text
        lastToolOperation = current.kind == .image ? .screenshotTranslate : .inputTranslate
        toolStatus = nil; toolError = nil; onShowTools?()
    }
    @discardableResult
    func addScreenshot(_ data: Data, translateAfter: Bool) -> UUID? {
        let item = ClipItem(title: "截图 · \(Date().formatted(date: .omitted, time: .shortened))", text: "", kind: .image,
                            sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: "屏幕截图",
                            representations: [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: data)])
        guard let stored = storeToolItem(item, action: "保存截图") else { return nil }
        showToolItem(stored); recognizeItem(stored, translateAfter: translateAfter)
        return stored.id
    }
    func recognizeItem(_ item: ClipItem, translateAfter: Bool = true) {
        guard contextSuggestionApplyingID == nil else { return }
        showToolItem(item)
        guard let current = activeToolItem, let data = Self.imageData(current) else { toolError = "此卡片不包含图片。"; return }
        cancelToolOperation(); toolBusy = true; toolStatus = "正在识别文字…"; toolError = nil
        lastToolOperation = translateAfter ? .screenshotTranslate : .screenshotOCR
        let generation = toolGeneration, configuration = toolConfiguration, input = current
        toolTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.toolGeneration == generation { self.toolBusy = false; self.toolTask = nil } }
            do {
                let response = try await self.toolOperations.recognize(data, configuration)
                try Task.checkCancellation()
                guard self.toolGeneration == generation,
                      var live = self.snapshot.items.first(where: { $0.id == input.id }),
                      live.fingerprint == input.fingerprint, live.enrichment == input.enrichment,
                      self.toolInputText == (input.enrichment?.ocr?.text ?? input.text),
                      self.toolConfiguration.hasSameToolSettings(as: configuration) else { return }
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.toolError = "未识别到文字，请重新截图。"; self.toolStatus = nil; return
                }
                guard response.text.utf8.count <= 2 * 1024 * 1024 else {
                    self.toolError = "文字超过 2 MB，请分段识别。"; self.toolStatus = nil; return
                }
                var enrichment = live.enrichment ?? .init()
                enrichment.ocr = .init(text: response.text, provider: configuration.ocrProviderTitle)
                live.enrichment = enrichment
                guard self.saveDerivedResult(response.text, source: live, operation: .ocr, provider: configuration.ocrProviderTitle, action: "保存识别结果") else {
                    self.toolError = self.toolError ?? self.statusMessage ?? "识别完成，但卡片未保存。"; return
                }
                self.toolInputText = response.text; self.toolStatus = nil
                if translateAfter {
                    self.lastToolOperation = .inputTranslate
                    self.toolStatus = "正在翻译…"
                    let result = try await self.toolOperations.translate(response.text, configuration)
                    try Task.checkCancellation()
                    guard self.toolGeneration == generation else { return }
                    self.applyTranslation(result, input: response.text, item: live, configuration: configuration)
                }
            } catch is CancellationError { }
            catch { if self.toolGeneration == generation { self.toolError = error.localizedDescription; self.toolStatus = nil } }
        }
    }
    func translateItem(_ item: ClipItem) {
        showToolItem(item)
        if let current = activeToolItem, current.kind == .image, current.enrichment?.ocr == nil {
            recognizeItem(current, translateAfter: true)
        } else { translateToolInput() }
    }
    func translateToolInput() {
        guard contextSuggestionApplyingID == nil else { return }
        cancelAutoTranslation()
        toolInputIsComposing = false
        guard !toolBusy else { return }
        let input = toolInputText
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let item = activeToolItem, item.kind == .image {
            recognizeItem(item, translateAfter: true)
            return
        }
        lastToolOperation = .inputTranslate
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toolError = "请输入文字，或先识别图片。"; return }
        guard input.utf8.count <= 2 * 1024 * 1024 else { toolError = "文字超过 2 MB，请分段翻译。"; return }
        cancelToolOperation(); toolError = nil
        let item: ClipItem
        if activeToolItem != nil {
            guard saveToolInput() else { return }
            guard let updated = activeToolItem else { return }; item = updated
        } else {
            let created = ClipItem(title: String(input.prefix(80)), text: input, kind: .text,
                                   sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: "输入翻译",
                                   representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(input.utf8))])
            guard let stored = storeToolItem(created, action: "保存翻译原文") else { return }
            item = stored; toolItemID = stored.id
        }
        let generation = toolGeneration, configuration = toolConfiguration
        toolBusy = true; toolStatus = "正在翻译…"
        toolTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.toolGeneration == generation { self.toolBusy = false; self.toolTask = nil } }
            do {
                let result = try await self.toolOperations.translate(input, configuration)
                try Task.checkCancellation()
                guard self.toolGeneration == generation else { return }
                self.applyTranslation(result, input: input, item: item, configuration: configuration)
            } catch is CancellationError { }
            catch { if self.toolGeneration == generation { self.toolError = error.localizedDescription; self.toolStatus = nil } }
        }
    }
    private func applyTranslation(_ response: CloudTranslationResponse, input: String, item: ClipItem, configuration: CloudToolConfiguration) {
        guard var live = snapshot.items.first(where: { $0.id == item.id }), live.fingerprint == item.fingerprint,
              (live.enrichment?.ocr?.text ?? live.text) == input,
              toolInputText == input, toolConfiguration.hasSameToolSettings(as: configuration) else { toolStatus = "原文或设置已更改，请重新翻译。"; return }
        var enrichment = live.enrichment ?? .init()
        enrichment.translation = .init(sourceText: input, translatedText: response.text,
                                       sourceLanguage: configuration.sourceLanguage, targetLanguage: configuration.targetLanguage,
                                       provider: configuration.translationProviderTitle, model: response.model)
        live.enrichment = enrichment
        guard saveDerivedResult(response.text, source: live, operation: .translation, provider: configuration.translationProviderTitle, action: "保存译文卡片") else { return }
        completedToolTranslation = (input, configuration, live.id)
        toolStatus = nil
    }
    @discardableResult
    private func saveDerivedResult(_ text: String, source: ClipItem, operation: ClipDerivation.Operation, provider: String, action: String) -> Bool {
        guard snapshot.items.contains(where: { $0.id == source.id }) else { return false }
        let result = ClipItem(title: operation == .ocr ? "识别结果" : "翻译结果", text: text, kind: .text,
                              sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: provider,
                              representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))],
                              derivation: .init(sourceItemID: source.id, operation: operation, provider: provider))
        let updated = SnapshotOperations.replaceItem(source, in: snapshot)
        let next = SnapshotOperations.capture(result, in: updated)
        guard next.items.contains(where: { $0.id == source.id }),
              next.items.contains(where: { $0.fingerprint == result.fingerprint && $0.derivation == result.derivation }) else {
            toolError = "无法保存处理结果，请重试。"; return false
        }
        guard commit(next, action: action) else { toolError = statusMessage ?? "结果卡片未保存。"; return false }
        return true
    }
    @discardableResult
    func saveToolInput() -> Bool {
        guard var item = activeToolItem else { return false }
        guard toolInputText.utf8.count <= 2 * 1024 * 1024 else { toolError = "文字超过 2 MB。"; return false }
        if item.kind == .image {
            var enrichment = item.enrichment ?? .init()
            enrichment.ocr = .init(text: toolInputText, provider: enrichment.ocr?.provider ?? "手动编辑")
            item.enrichment = enrichment
            if !toolInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return saveDerivedResult(toolInputText, source: item, operation: .ocr, provider: enrichment.ocr!.provider, action: "编辑识别文字")
            }
        } else if toolInputText != item.text {
            item.text = toolInputText
            item.representations = [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(toolInputText.utf8))]
            item.kind = ContentClassifier.classify(text: toolInputText)
        }
        return commit(SnapshotOperations.replaceItem(item, in: snapshot), action: "编辑工具原文")
    }
    func saveOCRText(_ item: ClipItem, text: String) {
        guard var current = snapshot.items.first(where: { $0.id == item.id }), text.utf8.count <= 2 * 1024 * 1024 else { return }
        var enrichment = current.enrichment ?? .init()
        enrichment.ocr = .init(text: text, provider: enrichment.ocr?.provider ?? "手动编辑")
        current.enrichment = enrichment
        let saved = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? commit(SnapshotOperations.replaceItem(current, in: snapshot), action: "编辑识别文字")
            : saveDerivedResult(text, source: current, operation: .ocr, provider: enrichment.ocr!.provider, action: "编辑识别文字")
        if saved, toolItemID == item.id { toolInputText = text }
    }
    private func storeToolItem(_ item: ClipItem, action: String) -> ClipItem? {
        let next = SnapshotOperations.capture(item, in: snapshot)
        guard let stored = next.items.first(where: { $0.fingerprint == item.fingerprint && $0.derivation == item.derivation }) else { toolError = "无法保存内容，请重试。"; return nil }
        guard commit(next, action: action) else { toolError = statusMessage ?? "保存失败。"; return nil }
        select(stored)
        return stored
    }
    func copyToolText(_ text: String) {
        guard !isPasting else { return }
        do { try bridge.write([.init(text: text, kind: .text)], plainText: true); toolStatus = "文字已复制。" }
        catch { toolError = error.localizedDescription }
    }
    func copyToolOriginal(_ item: ClipItem) {
        guard !isPasting else { return }
        do { try bridge.write([item], plainText: false); toolStatus = "原始内容已复制。" }
        catch { toolError = error.localizedDescription }
    }
    func cancelToolOperation() {
        cancelAutoTranslation()
        toolInputIsComposing = false
        if toolBusy { toolStatus = "已取消，原始内容已保留。" }
        toolGeneration = UUID(); toolTask?.cancel(); toolTask = nil; toolBusy = false
    }
    func retryToolOperation() {
        guard !toolBusy else { return }
        if lastToolOperation == .clipboardTranslate { performTool(.clipboardTranslate); return }
        if lastToolOperation == .selectionTranslate { performTool(.selectionTranslate); return }
        if lastToolOperation == .screenshotOCR || lastToolOperation == .screenshotTranslate {
            if let item = activeToolItem { recognizeItem(item, translateAfter: lastToolOperation == .screenshotTranslate) }
            else { onScreenshotTool?(lastToolOperation == .screenshotTranslate) }
        } else { translateToolInput() }
    }
}
