import AppKit
import PasteCore

struct ToolOperations: Sendable {
    var recognize: @Sendable (Data, CloudToolConfiguration) async throws -> CloudOCRResponse
    var translate: @Sendable (String, CloudToolConfiguration) async throws -> CloudTranslationResponse
    static func live() -> Self {
        let service = CloudToolsService()
        return .init(recognize: { data, configuration in
            if configuration.ocrProvider == .system { return try await service.recognize(image: data, configuration: configuration) }
            let work = Task.detached(priority: .utility) { try OCRImagePreparation.uploadData(data) }
            let payload = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            return try await service.recognize(image: payload, configuration: configuration)
        },
                     translate: { try await service.translate(text: $0, configuration: $1) })
    }
}

extension AppModel {
    var activeToolItem: ClipItem? { toolItemID.flatMap { id in snapshot.items.first { $0.id == id } } }
    var toolSourceText: String {
        guard let item = activeToolItem else { return toolInputText }
        return item.enrichment?.ocr?.text ?? item.text
    }
    func performTool(_ action: ToolAction) {
        guard !isPasting else { statusMessage = "正在粘贴，请稍后重试。"; return }
        onToolStart?()
        switch action {
        case .screenshotOCR, .screenshotTranslate:
            lastToolOperation = action; onScreenshotTool?(action == .screenshotTranslate)
        case .selectionTranslate:
            cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolStatus = nil; toolError = nil
            lastToolOperation = action; onSelectionTool?()
        case .inputTranslate:
            cancelToolOperation(); toolItemID = nil; toolInputText = ""; toolStatus = nil; toolError = nil
            lastToolOperation = action; onShowTools?()
        case .clipboardTranslate:
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
        guard let current = snapshot.items.first(where: { $0.id == item.id }) else { return }
        toolItemID = current.id; toolInputText = current.enrichment?.ocr?.text ?? current.text
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
    func recognizeItem(_ item: ClipItem, translateAfter: Bool = false) {
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
                      self.toolConfiguration == configuration else { return }
                var enrichment = live.enrichment ?? .init()
                enrichment.ocr = .init(text: response.text, provider: configuration.ocrProviderTitle)
                live.enrichment = enrichment
                guard self.saveDerivedResult(response.text, source: live, operation: .ocr, provider: configuration.ocrProviderTitle, action: "保存识别结果") else {
                    self.toolError = self.toolError ?? self.statusMessage ?? "识别完成，但卡片未保存。"; return
                }
                self.toolInputText = response.text; self.toolStatus = "原图与识别文字已保存为独立卡片。"
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
    func translateItem(_ item: ClipItem) { showToolItem(item); translateToolInput() }
    func translateToolInput() {
        guard !toolBusy else { return }
        let input = toolInputText
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toolError = "请输入文字，或先识别图片。"; return }
        guard input.utf8.count <= 2 * 1024 * 1024 else { toolError = "文字超过 2 MB，请分段翻译。"; return }
        cancelToolOperation(); toolError = nil
        let item: ClipItem
        if let current = activeToolItem {
            guard saveToolInput() else { return }
            guard let updated = activeToolItem else { return }; item = updated
            if current.kind == .image && current.enrichment?.ocr == nil { toolStatus = "输入内容已保存为识别文字。" }
        } else {
            let created = ClipItem(title: String(input.prefix(80)), text: input, kind: .text,
                                   sourceBundleID: Bundle.main.bundleIdentifier ?? "com.gaoxs.pasteboard", sourceName: "输入翻译",
                                   representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(input.utf8))])
            guard let stored = storeToolItem(created, action: "保存翻译原文") else { return }
            item = stored; toolItemID = stored.id
        }
        let generation = toolGeneration, configuration = toolConfiguration
        toolBusy = true; toolStatus = "正在翻译…"
        lastToolOperation = .inputTranslate
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
              toolInputText == input, toolConfiguration == configuration else { toolStatus = "原文或设置已更改，请重新翻译。"; return }
        var enrichment = live.enrichment ?? .init()
        enrichment.translation = .init(sourceText: input, translatedText: response.text,
                                       sourceLanguage: configuration.sourceLanguage, targetLanguage: configuration.targetLanguage,
                                       provider: configuration.translationProviderTitle, model: response.model)
        live.enrichment = enrichment
        guard saveDerivedResult(response.text, source: live, operation: .translation, provider: configuration.translationProviderTitle, action: "保存译文卡片") else { return }
        toolStatus = "原文与译文已保存为独立卡片。"
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
            toolError = "历史容量不足，结果未保存。请提高历史记录上限或清理记录后重试。原始内容已保留。"; return false
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
        guard let stored = next.items.first(where: { $0.fingerprint == item.fingerprint && $0.derivation == item.derivation }) else { toolError = "历史容量已满，内容未保存。"; return nil }
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
        if toolBusy { toolStatus = "已取消，原始内容已保留。" }
        toolGeneration = UUID(); toolTask?.cancel(); toolTask = nil; toolBusy = false
    }
    func retryToolOperation() {
        guard !toolBusy else { return }
        if lastToolOperation == .selectionTranslate { performTool(.selectionTranslate); return }
        if lastToolOperation == .screenshotOCR || lastToolOperation == .screenshotTranslate {
            if let item = activeToolItem { recognizeItem(item, translateAfter: lastToolOperation == .screenshotTranslate) }
            else { onScreenshotTool?(lastToolOperation == .screenshotTranslate) }
        } else { translateToolInput() }
    }
}
