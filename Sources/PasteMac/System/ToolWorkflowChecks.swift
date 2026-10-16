#if DEBUG
import AppKit
import PasteCore

@MainActor
enum ToolWorkflowChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Tool workflow: \(message)") }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-check-\(UUID())")
        let suite = "tools-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let bridge = ClipboardBridge(pasteboard: board, sourceProvider: { .init(bundleID: "test.tools", name: "Synthetic") })
        let image = try png()
        let operations = ToolOperations(recognize: { _, _ in .init(text: "Hello OCR") }, translate: { text, _ in .init(text: "译文：\(text)", model: "fixture") })
        func make(_ operations: ToolOperations) -> AppModel {
            let model = AppModel(isDemo: true, storageDirectory: root, bridge: bridge, toolOperations: operations, toolDefaults: defaults)
            model.snapshot = .init(); return model
        }
        let model = make(operations)
        let id = model.addScreenshot(image, translateAfter: true)
        try check(id != nil && model.snapshot.items.count == 1, "screenshot not immediately admitted as one card")
        try await finished(model)
        guard let card = model.activeToolItem else { throw SystemChecks.Failure(message: "Tool workflow: lost card") }
        try check(card.id == id && model.snapshot.items.count == 3, "OCR/translation did not create original + OCR + translation cards")
        try check(card.representations.first?.data == image && card.kind == .image, "original screenshot replaced by derived text")
        try check(card.enrichment?.ocr?.text == "Hello OCR", "OCR did not persist in card")
        try check(card.enrichment?.translation?.sourceText == "Hello OCR" && card.enrichment?.translation?.translatedText == "译文：Hello OCR", "translation lost source/result association")
        try model.repository.save(model.snapshot)
        let restored = try model.repository.load()
        try check(restored.items == model.snapshot.items, "combined card did not restore")
        model.copyToolText(card.enrichment!.translation!.translatedText)
        try check(board.string(forType: .string) == "译文：Hello OCR" && board.types?.contains(.string) == true && board.data(forType: .png) == nil && board.data(forType: .tiff) == nil && board.data(forType: .html) == nil && board.data(forType: .rtf) == nil, "translation copy did not produce plain text")
        model.copyToolOriginal(card)
        try check(board.data(forType: .png) == image && board.string(forType: .string) == nil, "image copy included unrelated translation or lost original")
        model.undoManager.removeAllActions()
        model.saveOCRText(card, text: "Edited OCR")
        try check(model.snapshot.items.contains { $0.derivation?.operation == .ocr && $0.text == "Edited OCR" }, "OCR edit did not save updated standalone card")
        try check(model.activeToolItem?.translationIsStale == true, "edited OCR retained apparently current translation")
        model.undo()
        try check(model.activeToolItem?.enrichment?.ocr?.text == "Hello OCR", "OCR edit undo lost original")
        model.showToolItem(model.activeToolItem!)
        model.recognizeItem(model.activeToolItem!)
        try await finished(model)
        try check(model.snapshot.items.count == 3 && model.activeToolItem?.id == id, "re-recognition changed original ID")

        let failed = make(.init(recognize: { _, _ in throw CloudToolsError.authentication }, translate: { _, _ in throw CloudToolsError.authentication }))
        let failedID = failed.addScreenshot(image, translateAfter: true)
        try await finished(failed)
        try check(failed.snapshot.items.first?.id == failedID && failed.snapshot.items.first?.representations.first?.data == image, "failed OCR discarded screenshot")
        try check(failed.toolError != nil && failed.activeToolItem?.enrichment == nil, "failed request was reported as enrichment success")

        let typed = make(operations)
        typed.toolInputText = "Original translation input"
        typed.translateToolInput(); try await finished(typed)
        try check(typed.snapshot.items.count == 2 && typed.activeToolItem?.text == "Original translation input", "typed translation did not save original")
        try check(typed.activeToolItem?.enrichment?.translation?.translatedText == "译文：Original translation input", "typed translation was not retained")
        typed.translateToolInput(); try await finished(typed)
        try check(typed.snapshot.items.count == 2, "repeated typed translation duplicated card")

        let retryCapture = make(operations)
        var captures: [Bool] = []
        retryCapture.onScreenshotTool = { captures.append($0) }
        retryCapture.performTool(.screenshotTranslate); retryCapture.retryToolOperation()
        try check(captures == [true, true], "capture failure retry did not restart screenshot translation")

        let partial = make(.init(recognize: operations.recognize, translate: { _, _ in throw CloudToolsError.authentication }))
        _ = partial.addScreenshot(image, translateAfter: true); try await finished(partial)
        try check(partial.activeToolItem?.enrichment?.ocr?.text == "Hello OCR" && partial.toolError != nil, "translation failure lost successful OCR")
        partial.toolInputText = "Corrected OCR"
        partial.retryToolOperation(); try await finished(partial)
        try check(partial.activeToolItem?.enrichment?.ocr?.text == "Corrected OCR" && partial.toolError != nil, "translation retry discarded corrected OCR")

        let gate = ToolResponseGate()
        let delayed = make(.init(recognize: { _, _ in await gate.wait(); return .init(text: "Late OCR") }, translate: operations.translate))
        let delayedID = delayed.addScreenshot(image, translateAfter: false)!
        try await waiting(gate)
        delayed.commit(SnapshotOperations.deleteItems(ids: [delayedID], in: delayed.snapshot), action: "remove")
        await gate.release(); try await finished(delayed)
        try check(delayed.snapshot.items.isEmpty, "late OCR resurrected a deleted card")

        let editGate = ToolResponseGate()
        let edited = make(.init(recognize: { _, _ in await editGate.wait(); return .init(text: "Old request") }, translate: operations.translate))
        _ = edited.addScreenshot(image, translateAfter: false)
        try await waiting(editGate)
        edited.toolInputText = "New unsaved text"
        await editGate.release(); try await finished(edited)
        try check(edited.toolInputText == "New unsaved text" && edited.activeToolItem?.enrichment == nil, "late OCR overwrote edited input")

        let cancelGate = ToolResponseGate()
        let cancelled = make(.init(recognize: { _, _ in await cancelGate.wait(); return .init(text: "Cancelled response") }, translate: operations.translate))
        _ = cancelled.addScreenshot(image, translateAfter: false)
        try await waiting(cancelGate)
        let oldTask = cancelled.toolTask
        cancelled.cancelToolOperation(); await cancelGate.release(); await oldTask?.value
        try check(!cancelled.toolBusy && cancelled.activeToolItem?.enrichment == nil, "cancelled OCR submitted late result")
        try check(cancelled.snapshot.items.count == 1, "cancellation discarded original card")

        let translationGate = ToolResponseGate()
        let staleTranslation = make(.init(recognize: operations.recognize, translate: { _, _ in await translationGate.wait(); return .init(text: "Stale translation", model: "fixture") }))
        staleTranslation.toolInputText = "Before edit"; staleTranslation.translateToolInput()
        try await waiting(translationGate)
        let busyTask = staleTranslation.toolTask
        staleTranslation.translateToolInput(); staleTranslation.retryToolOperation()
        try check(staleTranslation.toolBusy && staleTranslation.toolTask != nil && busyTask?.isCancelled == false, "busy keyboard action cancelled in-flight request")
        staleTranslation.toolInputText = "After edit"; _ = staleTranslation.saveToolInput()
        await translationGate.release(); try await finished(staleTranslation)
        try check(staleTranslation.activeToolItem?.text == "After edit" && staleTranslation.activeToolItem?.enrichment?.translation == nil, "stale translation replaced new original")
        let equal = make(.init(recognize: operations.recognize, translate: { text, _ in .init(text: text, model: "same-language") }))
        equal.toolInputText = "Hello"; equal.translateToolInput(); try await finished(equal)
        try check(equal.snapshot.items.count == 2 && equal.snapshot.items.filter { $0.derivation != nil }.count == 1, "identical source/result merged into one card")
        let selectionRetry = make(operations)
        selectionRetry.toolInputText = "Previous unrelated input"
        var selections = 0
        selectionRetry.onSelectionTool = { selections += 1 }
        selectionRetry.performTool(.selectionTranslate); selectionRetry.retryToolOperation()
        try check(selections == 2 && selectionRetry.toolInputText.isEmpty && selectionRetry.snapshot.items.isEmpty, "failed selection retried previous input instead of recapturing")
        let selected = make(operations)
        selected.beginSelectedTextTranslation("Selected sample")
        try await finished(selected)
        try check(selected.snapshot.items.count == 2 && selected.activeToolItem?.text == "Selected sample", "selected text was not saved separately from translation")
        let full = make(operations)
        full.snapshot.preferences.maxHistoryItems = 1
        let originalID = full.addScreenshot(image, translateAfter: false)
        try await finished(full)
        try check(full.snapshot.items.count == 1 && full.snapshot.items.first?.id == originalID && full.toolError != nil, "result evicted original when history was full")
        return count
    }
    private static func waiting(_ gate: ToolResponseGate) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await gate.waiting) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard await gate.waiting else { throw SystemChecks.Failure(message: "Tool request did not start") }
    }
    private static func finished(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.toolBusy && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard !model.toolBusy else { throw SystemChecks.Failure(message: "Tool workflow timed out") }
    }
    private static func png() throws -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 24, bitsPerComponent: 8, bytesPerRow: 256,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageProcessing.Failure.invalidImage }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
        return try ImageProcessing.png(context.makeImage()!)
    }
}
private actor ToolResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
