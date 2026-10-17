#if DEBUG
import AppKit
import PasteCore

@MainActor
enum AutoTranslationChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Auto translation: \(message)") }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-translation-\(UUID())")
        let suite = "auto-translation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: .init(suite))
        let bridge = ClipboardBridge(pasteboard: board, sourceProvider: { .init(bundleID: "test.auto", name: "Fixture") })
        var models: [AppModel] = []
        defer {
            for model in models { model.cancelAutoTranslation(); model.cancelToolOperation() }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func make(_ recorder: AutoTranslationRecorder, delay: UInt64 = 25_000_000) -> AppModel {
            let operations = ToolOperations(recognize: { _, _ in .init(text: "Fixture OCR") }, translate: { text, _ in
                await recorder.record(text)
                return .init(text: "Translated: \(text)", model: "fixture")
            })
            let model = AppModel(isDemo: true, storageDirectory: root.appendingPathComponent(UUID().uuidString),
                                 bridge: bridge, toolOperations: operations, toolDefaults: defaults,
                                 autoTranslationDelayNanoseconds: delay)
            model.snapshot = .init()
            model.toolSessionActive = true
            models.append(model)
            return model
        }
        let production = AppModel(isDemo: true, storageDirectory: root.appendingPathComponent("default"),
                                  bridge: bridge, toolDefaults: defaults)
        models.append(production)
        try check(production.autoTranslationDelayNanoseconds == 750_000_000, "production delay is not 750 milliseconds")

        let mergedCalls = AutoTranslationRecorder()
        let merged = make(mergedCalls)
        merged.editToolInput("H", isComposing: false)
        merged.editToolInput("He", isComposing: false)
        merged.editToolInput("Hello", isComposing: false)
        try check(await mergedCalls.texts.isEmpty, "input translated synchronously before idle")
        try await eventually { !merged.toolBusy && merged.activeToolItem?.enrichment?.translation != nil }
        try await settle()
        try check(await mergedCalls.texts == ["Hello"], "debounce did not merge input into the latest request")
        try check(merged.snapshot.items.count == 2 && merged.activeToolItem?.text == "Hello", "automatic translation lost standalone original/result cards")
        try check(merged.snapshot.items.contains { $0.derivation?.operation == .translation && $0.text == "Translated: Hello" }, "automatic result was not saved")

        merged.editToolInput("Hello", isComposing: false)
        try await settle()
        try check(await mergedCalls.texts == ["Hello"], "completed input was translated again without a change")

        let largeCalls = AutoTranslationRecorder()
        let large = make(largeCalls)
        large.editToolInput(String(repeating: "x", count: 2 * 1024 * 1024 + 1), isComposing: false)
        try await settle()
        try check(await largeCalls.texts.isEmpty && large.toolError != nil, "oversized source triggered an automatic request")

        let composingCalls = AutoTranslationRecorder()
        let composing = make(composingCalls)
        composing.editToolInput("中文", isComposing: true)
        try await settle()
        try check(await composingCalls.texts.isEmpty, "marked text started a request")
        composing.editToolInput("中文", isComposing: false)
        try await eventually { composing.activeToolItem?.enrichment?.translation != nil }
        try check(await composingCalls.texts == ["中文"], "committing unchanged marked text did not schedule translation")

        let blankCalls = AutoTranslationRecorder()
        let blank = make(blankCalls)
        blank.editToolInput("\n  \t", isComposing: false)
        try await settle()
        try check(await blankCalls.texts.isEmpty && blank.snapshot.items.isEmpty, "blank input translated or created cards")

        let cancelledCalls = AutoTranslationRecorder()
        let cancelled = make(cancelledCalls)
        cancelled.editToolInput("Closed window", isComposing: false)
        cancelled.cancelAutoTranslation()
        try await settle()
        try check(await cancelledCalls.texts.isEmpty, "closing/cancellation left a pending automatic request")

        let manualCalls = AutoTranslationRecorder()
        let manual = make(manualCalls)
        manual.editToolInput("Manual", isComposing: false)
        manual.translateToolInput()
        try await eventually { manual.activeToolItem?.enrichment?.translation != nil }
        try await settle()
        try check(await manualCalls.texts == ["Manual"], "manual translation was followed by a duplicate automatic request")

        let assignedCalls = AutoTranslationRecorder()
        let assigned = make(assignedCalls)
        assigned.toolInputText = "Programmatic text"
        try await settle()
        try check(await assignedCalls.texts.isEmpty, "programmatic assignment automatically uploaded text")

        let configurationCalls = AutoTranslationRecorder()
        let configuration = make(configurationCalls)
        configuration.editToolInput("Old settings", isComposing: false)
        configuration.toolConfiguration.targetLanguage = "en"
        try await settle()
        try check(await configurationCalls.texts == ["Old settings"] && configuration.activeToolItem?.enrichment?.translation?.targetLanguage == "en", "configuration change failed to replace the pending timer with one fresh translation")
        let unrelatedCalls = AutoTranslationRecorder()
        let unrelated = make(unrelatedCalls)
        unrelated.editToolInput("Keep pending input", isComposing: false)
        unrelated.toolConfiguration.aiServices.append(AIServiceConfig(vendor: .deepseek))
        try await eventually { unrelated.activeToolItem?.enrichment?.translation != nil }
        try check(await unrelatedCalls.texts == ["Keep pending input"], "unrelated service edit cancelled pending translation")

        let inFlightCalls = AutoTranslationRecorder(blockFirst: true)
        let inFlight = make(inFlightCalls)
        inFlight.toolInputText = "Keep running input"
        inFlight.translateToolInput()
        try await eventually { await inFlightCalls.texts.count == 1 }
        inFlight.toolConfiguration.aiServices.append(AIServiceConfig(vendor: .openai))
        await inFlightCalls.release()
        try await eventually { !inFlight.toolBusy }
        try check(inFlight.activeToolItem?.enrichment?.translation?.translatedText == "Translated: Keep running input", "unrelated service edit discarded running translation")

        let selectedCalls = AutoTranslationRecorder()
        let selected = make(selectedCalls)
        let selectedService = AIServiceConfig(vendor: .ollama)
        var selectedConfig = selected.toolConfiguration
        selectedConfig.aiServices = [selectedService]
        selectedConfig.translationAIServiceID = selectedService.id
        selected.toolConfiguration = selectedConfig
        selected.toolInputText = "Refresh active model"
        selected.translateToolInput()
        try await eventually { !selected.toolBusy && selected.activeToolItem?.enrichment?.translation != nil }
        selected.toolConfiguration.aiServices[0].translationModel = "another-model"
        try await eventually { await selectedCalls.texts.count == 2 && !selected.toolBusy }
        try check(await selectedCalls.texts.count == 2, "editing selected AI model did not refresh translation")

        let builtinCalls = AutoTranslationRecorder()
        let builtin = make(builtinCalls)
        builtin.editToolInput("Keep local translation", isComposing: false)
        builtin.toolConfiguration.openAITranslationModel = "unused-model"
        try await eventually { builtin.activeToolItem?.enrichment?.translation != nil }
        try check(await builtinCalls.texts == ["Keep local translation"], "editing unused builtin model interrupted translation")

        let closedCalls = AutoTranslationRecorder()
        let closed = make(closedCalls)
        closed.toolInputText = "Closed source"
        closed.toolSessionActive = false
        closed.toolConfiguration.targetLanguage = "ja"
        try await settle()
        try check(await closedCalls.texts.isEmpty, "changing settings uploaded a closed tool session")
        let imeCalls = AutoTranslationRecorder()
        let ime = make(imeCalls)
        ime.editToolInput("中文", isComposing: true)
        ime.toolConfiguration.targetLanguage = "en"
        try await settle()
        try check(await imeCalls.texts.isEmpty, "configuration change translated uncommitted IME text")
        ime.editToolInput("中文", isComposing: false)
        try await eventually { ime.activeToolItem?.enrichment?.translation != nil }
        try check(await imeCalls.texts == ["中文"], "IME commit failed to use updated configuration")

        let contextCalls = AutoTranslationRecorder()
        let context = make(contextCalls)
        let card = ClipItem(text: "Other card", kind: .text)
        context.snapshot.items = [card]
        context.editToolInput("Old context", isComposing: false)
        context.showToolItem(card)
        try await settle()
        try check(await contextCalls.texts.isEmpty && context.toolInputText == "Other card", "scheduled request survived a card context switch")

        let staleCalls = AutoTranslationRecorder(blockFirst: true)
        let stale = make(staleCalls, delay: 100_000_000)
        stale.editToolInput("Old input", isComposing: false)
        try await eventually { await staleCalls.texts.count == 1 }
        let oldTask = stale.toolTask
        stale.editToolInput("New input", isComposing: false)
        await staleCalls.release()
        await oldTask?.value
        try check(stale.toolInputText == "New input" && stale.snapshot.items.allSatisfy { $0.enrichment?.translation?.sourceText != "Old input" }, "late response applied after source editing")
        try await eventually { !stale.toolBusy && stale.activeToolItem?.enrichment?.translation?.sourceText == "New input" }
        try check(await staleCalls.texts == ["Old input", "New input"], "edited input failed to translate after cancelling an older request")
        return count
    }

    private static func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    private static func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw SystemChecks.Failure(message: "Auto translation: timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor AutoTranslationRecorder {
    private(set) var texts: [String] = []
    private let blockFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    func record(_ text: String) async {
        texts.append(text)
        if blockFirst && texts.count == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
