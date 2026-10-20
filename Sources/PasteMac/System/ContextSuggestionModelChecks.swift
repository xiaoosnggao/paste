#if DEBUG
import AppKit
import PasteCore

/// All requests are injected fixtures, clipboard writes use a private pasteboard, and no native events are sent.
@MainActor
enum ContextSuggestionModelChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: "Context suggestion model: \(message)") }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-suggestion-\(UUID())")
        let suite = "context-suggestion-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        let bridge = ClipboardBridge(pasteboard: board)
        var models = [AppModel]()
        let source = ClipItem(text: "{\"ok\":true}", kind: .text,
                              sourceBundleID: "com.microsoft.VSCode", sourceName: "Visual Studio Code")
        let other = ClipItem(text: "Another selected card", kind: .text, sourceBundleID: "test.source", sourceName: "Fixture")
        let service = AIServiceConfig(name: "Fixture AI", vendor: .ollama)
        defer {
            for model in models { model.suggestionSessionActive = false; model.cancelToolOperation() }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func make(_ recorder: ContextSuggestionRecorder, configured: Bool = true, target: PasteTarget? = nil,
                  environment: ContextSuggestionPasteEnvironment? = nil) -> AppModel {
            let operations = ContextSuggestionOperations(suggest: { input, _ in try await recorder.suggest(input) },
                                                        transform: { input, _, _ in try await recorder.transform(input) },
                                                        summarize: { input, _ in await recorder.summarize(input) },
                                                        transformMultiple: { input, _, _ in "Merged: " + input.cards.map(\.text).joined(separator: "\n") })
            let engine = PasteEngine(trackApplications: false, environment: environment ?? ContextSuggestionPasteEnvironment(), target: target)
            let model = AppModel(isDemo: true, storageDirectory: root.appendingPathComponent(UUID().uuidString),
                                 bridge: bridge, toolDefaults: defaults, pasteEngine: engine,
                                 suggestionOperations: operations, suggestionDelayNanoseconds: 5_000_000)
            model.snapshot = .init(items: [source, other])
            model.snapshot.preferences.pasteToFrontmost = false
            model.toolConfiguration = .init()
            if configured { model.toolConfiguration.aiServices = [service]; model.toolConfiguration.translationAIServiceID = service.id }
            model.suggestionSessionActive = true
            model.select(source)
            models.append(model)
            return model
        }

        let unconfiguredCalls = ContextSuggestionRecorder()
        let unconfigured = make(unconfiguredCalls, configured: false)
        try await settle()
        try check(await unconfiguredCalls.inputs.isEmpty, "unconfigured service uploaded a selected card")
        try check(!unconfigured.contextSuggestionsVisible, "unconfigured service exposed an empty suggestions region")

        let contextCalls = ContextSuggestionRecorder()
        let target = PasteTarget(pid: 42, name: "Lark", bundleID: "com.bytedance.lark")
        let context = make(contextCalls, target: target)
        try await eventually { !context.contextSuggestions.isEmpty }
        let sent = await contextCalls.inputs.first
        try check(sent?.text == source.text && sent?.kind == "text", "selected source content or kind changed")
        try check(sent?.sourceName == source.sourceName && sent?.sourceBundleID == source.sourceBundleID,
                  "source application attribution was omitted")
        try check(sent?.targetName == target.name && sent?.targetBundleID == target.bundleID,
                  "captured paste destination was omitted")
        context.scheduleContextSuggestions()
        try await settle()
        try check(await contextCalls.inputs.count == 1, "unchanged selection repeated the request")
        context.select(other)
        try await eventually { context.contextSuggestions.first?.title == other.text }
        context.select(source)
        try await eventually { context.contextSuggestions.first?.title == source.text }
        try check(await contextCalls.inputs.count == 2, "returning to a completed selection did not reuse bounded cache")
        context.dismissContextSuggestions()
        context.scheduleContextSuggestions()
        try await settle()
        try check(!context.contextSuggestionsVisible && context.contextSuggestions.isEmpty,
                  "dismissed suggestions immediately reopened for the unchanged card")
        context.retryContextSuggestions()
        try await eventually { !context.contextSuggestions.isEmpty }
        try check(await contextCalls.inputs.count == 3, "explicit retry did not refresh the provider result")

        let latestCalls = ContextSuggestionRecorder(blockSuggestion: true)
        let latest = make(latestCalls)
        try await eventually { await latestCalls.inputs.count == 1 }
        latest.select(other)
        try await eventually { latest.contextSuggestions.first?.title == other.text }
        await latestCalls.release()
        try await settle()
        try check(latest.contextSuggestions.first?.title == other.text, "late previous selection replaced latest suggestions")

        let closedCalls = ContextSuggestionRecorder(blockSuggestion: true)
        let closed = make(closedCalls)
        try await eventually { await closedCalls.inputs.count == 1 }
        try check(!closed.contextSuggestionsVisible && closed.contextSuggestionsLoading,
                  "first pending request displayed result content before results arrived")
        closed.suggestionSessionActive = false
        await closedCalls.release()
        try await settle()
        try check(closed.contextSuggestions.isEmpty && !closed.contextSuggestionsVisible && !closed.contextSuggestionsLoading
                  && !closed.contextSuggestionsPresented,
                  "closed panel accepted a late suggestion response")

        let busyCalls = ContextSuggestionRecorder(blockSuggestion: true)
        let busy = make(busyCalls)
        try await eventually { await busyCalls.inputs.count == 1 }
        busy.toolBusy = true
        await busyCalls.release()
        try await settle()
        try check(busy.contextSuggestions.isEmpty && !busy.contextSuggestionsLoading,
                  "tool processing left a discarded suggestion request spinning")
        busy.toolBusy = false
        try await eventually { !busy.contextSuggestions.isEmpty && !busy.contextSuggestionsLoading }
        try check(await busyCalls.inputs.count == 2,
                  "ending tool processing failed to reschedule the selected card")

        let multiCalls = ContextSuggestionRecorder()
        let multi = make(multiCalls)
        multi.selectedIDs = [source.id, other.id]
        try await eventually { multi.multiCardSummary != nil }
        let multiSent = await multiCalls.multiInputs.first
        try check(multiSent?.cards.map(\.id) == [source.id, other.id], "multi-card ordering differs from displayed order")
        try check(multi.multiCardSummary?.sourceIDs == [source.id, other.id], "multi-card provenance omitted a source")
        try check(multi.contextSuggestions.count == 3, "multi-card summary omitted actionable suggestions")
        var preview: ContextSuggestionPreviewResult?
        multi.onSuggestionPreview = { preview = $0 }
        multi.applyContextSuggestion(multi.contextSuggestions[0])
        try await eventually { preview != nil }
        try check(multi.snapshot.items.count == 2, "multi-card result bypassed editable preview")
        if let preview {
            try check(multi.saveContextSuggestionPreview(preview, text: "Edited merged content"), "preview save failed")
            let derived = multi.snapshot.items.first { $0.text == "Edited merged content" }
            try check(derived?.derivation?.sourceItemIDs == [source.id, other.id], "preview save lost multi-source provenance")
        }

        let ordinaryEnvironment = ContextSuggestionPasteEnvironment()
        let ordinary = make(ContextSuggestionRecorder(), target: target, environment: ordinaryEnvironment)
        ordinary.snapshot.preferences.pasteToFrontmost = true
        ordinary.selectedIDs = [source.id, other.id]
        try await eventually { ordinary.multiCardSummary != nil }
        var multiRetainedDuringExit = false
        ordinary.onPreparePaste = {
            multiRetainedDuringExit = ordinary.selectedIDs.count == 2 && ordinary.multiCardSummary != nil
        }
        ordinary.activate(source)
        try await eventually { ordinaryEnvironment.sendCount == 1 && !ordinary.isPasting }
        try check(multiRetainedDuringExit, "ordinary card activation collapsed the multi-card summary before exit")

        let lateMultiCalls = ContextSuggestionRecorder(blockMulti: true)
        let lateMulti = make(lateMultiCalls)
        lateMulti.selectedIDs = [source.id, other.id]
        try await eventually { await lateMultiCalls.multiInputs.count == 1 }
        lateMulti.select(source)
        await lateMultiCalls.release()
        try await eventually { !lateMulti.contextSuggestions.isEmpty && !lateMulti.contextSuggestionsLoading }
        try check(lateMulti.multiCardSummary == nil, "late multi-card response replaced current single-card selection")

        let disabledCalls = ContextSuggestionRecorder()
        let disabled = make(disabledCalls)
        disabled.toolConfiguration.contextSuggestionsEnabled = false
        try await settle()
        try check(await disabledCalls.inputs.isEmpty, "disabled suggestions still made a request")

        let disabledServiceCalls = ContextSuggestionRecorder()
        let disabledService = make(disabledServiceCalls)
        disabledService.toolConfiguration.aiServices[0].isEnabled = false
        try await settle()
        try check(await disabledServiceCalls.inputs.isEmpty, "disabled AI service still received selected text")

        let missingSelectionCalls = ContextSuggestionRecorder()
        let missingSelection = make(missingSelectionCalls)
        missingSelection.toolConfiguration.translationAIServiceID = UUID()
        try await settle()
        try check(await missingSelectionCalls.inputs.isEmpty,
                  "missing explicitly selected service uploaded to another enabled service")
        let disabledSelectionCalls = ContextSuggestionRecorder()
        let disabledSelection = make(disabledSelectionCalls)
        var disabledSelectionConfig = disabledSelection.toolConfiguration
        disabledSelectionConfig.aiServices[0].isEnabled = false
        disabledSelectionConfig.aiServices.append(AIServiceConfig(name: "Unselected AI", vendor: .ollama))
        disabledSelection.toolConfiguration = disabledSelectionConfig
        try await settle()
        try check(await disabledSelectionCalls.inputs.isEmpty,
                  "disabled explicitly selected service uploaded to another enabled service")

        let expansionCalls = ContextSuggestionRecorder(blockSuggestion: true)
        let expansion = make(expansionCalls)
        var presentationChanges = [Bool]()
        expansion.onSuggestionPanelChange = { presentationChanges.append($0) }
        try await eventually { await expansionCalls.inputs.count == 1 }
        try check(!expansion.contextSuggestionsVisible && expansion.contextSuggestionsLoading,
                  "pending first suggestions displayed result content")
        try check(expansion.contextSuggestionsPresented,
                  "pending first suggestions failed to present their loading skeleton")
        await expansionCalls.release()
        try await eventually { !expansion.contextSuggestionsLoading && !expansion.contextSuggestions.isEmpty }
        try check(expansion.contextSuggestionsVisible,
                  "successful suggestions failed to display result content")
        try check(!presentationChanges.contains(false),
                  "loading-to-results transition briefly collapsed the suggestions region")
        presentationChanges.removeAll()
        expansion.select(other)
        try check(expansion.contextSuggestionsLoading && expansion.contextSuggestionsPresented,
                  "selecting another card collapsed the existing region instead of showing loading")
        try await eventually { !expansion.contextSuggestionsLoading && expansion.contextSuggestions.first?.title == other.text }
        try check(!presentationChanges.contains(false),
                  "card-switch loading transition briefly collapsed the suggestions region")
        expansion.dismissContextSuggestions()
        try check(!expansion.contextSuggestionsPresented && presentationChanges.last == false,
                  "dismissing suggestions failed to remove the presented region")

        let oversizedCalls = ContextSuggestionRecorder()
        let oversized = make(oversizedCalls)
        let long = ClipItem(text: String(repeating: "x", count: 65_537), kind: .text)
        oversized.snapshot.items = [long]
        oversized.select(long)
        try await settle()
        try check(await oversizedCalls.inputs.isEmpty, "oversized card reached request injection")
        try check(oversized.contextSuggestionsError != nil, "oversized card did not produce a recoverable local error")

        let applyCalls = ContextSuggestionRecorder(blockTransform: true)
        let apply = make(applyCalls)
        apply.snapshot.preferences.pasteToFrontmost = true
        try await eventually { !apply.contextSuggestions.isEmpty }
        let action = apply.contextSuggestions[0]
        apply.applyContextSuggestion(action)
        apply.applyContextSuggestion(action)
        try await eventually { await applyCalls.transformInputs.count == 1 }
        await applyCalls.release()
        try await eventually { apply.snapshot.items.contains { $0.derivation?.operation == .aiTransform } && !apply.isPasting }
        try check(await applyCalls.transformInputs.count == 1, "rapid action double-click transformed twice")
        try check(apply.snapshot.items.contains { $0.id == source.id && $0.text == source.text }, "transformation replaced its source card")
        let derived = apply.snapshot.items.first { $0.derivation?.operation == .aiTransform }
        try check(derived?.derivation?.sourceItemID == source.id && derived?.derivation?.provider == service.name,
                  "derived result lost its source/provider relation")
        try check(bridge.currentText == "Transformed: \(source.text)", "copy-only action did not write transformed text")

        let dispatchCalls = ContextSuggestionRecorder()
        let dispatchEnvironment = ContextSuggestionPasteEnvironment()
        let dispatch = make(dispatchCalls, target: target, environment: dispatchEnvironment)
        dispatch.snapshot.preferences.pasteToFrontmost = true
        var retainedDuringExit = false
        dispatch.onPreparePaste = {
            retainedDuringExit = dispatch.suggestionSessionActive && !dispatch.contextSuggestions.isEmpty
        }
        try await eventually { !dispatch.contextSuggestions.isEmpty }
        dispatch.applyContextSuggestion(dispatch.contextSuggestions[0])
        try await eventually { dispatchEnvironment.sendCount == 1 && !dispatch.isPasting }
        try check(retainedDuringExit, "AI paste cleared visible suggestions before the panel exit")
        try check(dispatchEnvironment.sendCount == 1 && dispatch.pasteIssue == nil, "selected suggestion did not use existing paste dispatcher")

        for output in ["   \n", String(repeating: "x", count: 2 * 1024 * 1024 + 1)] {
            let badCalls = ContextSuggestionRecorder(output: output)
            let bad = make(badCalls)
            try await eventually { !bad.contextSuggestions.isEmpty }
            bad.applyContextSuggestion(bad.contextSuggestions[0])
            try await eventually { bad.contextSuggestionsError != nil }
            try check(bad.snapshot.items.count == 2 && bad.contextSuggestionApplyingID == nil,
                      "invalid transformation stored a card or left processing stuck")
        }
        let failureCalls = ContextSuggestionRecorder(failTransform: true)
        let failure = make(failureCalls)
        try await eventually { !failure.contextSuggestions.isEmpty }
        failure.applyContextSuggestion(failure.contextSuggestions[0])
        try await eventually { failure.contextSuggestionsError != nil }
        try check(failure.snapshot.items.count == 2 && failure.contextSuggestionApplyingID == nil, "provider error saved output or blocked retry")

        let forgedCalls = ContextSuggestionRecorder()
        let forged = make(forgedCalls)
        try await eventually { !forged.contextSuggestions.isEmpty }
        forged.applyContextSuggestion(.init(id: "unknown", title: "Injected action", instruction: "Unexpected instruction"))
        try await settle()
        try check(await forgedCalls.transformInputs.isEmpty, "an action outside the displayed provider suggestions was executed")

        let staleCalls = ContextSuggestionRecorder(blockTransform: true)
        let stale = make(staleCalls)
        try await eventually { !stale.contextSuggestions.isEmpty }
        stale.applyContextSuggestion(stale.contextSuggestions[0])
        try await eventually { await staleCalls.transformInputs.count == 1 }
        stale.select(other)
        await staleCalls.release()
        try await settle()
        try check(stale.snapshot.items.count == 2, "late transformation for previous selection created a result")
        return count
    }

    private static func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw SystemChecks.Failure(message: "Context suggestion model: asynchronous fixture timed out")
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 40_000_000) }
}

private actor ContextSuggestionRecorder {
    var inputs = [ContextSuggestionInput]()
    var transformInputs = [ContextSuggestionInput]()
    var multiInputs = [MultiCardContextInput]()
    func summarize(_ input: MultiCardContextInput) async -> MultiCardContextSummary {
        multiInputs.append(input)
        if blockMulti { await withCheckedContinuation { continuation = $0 } }
        return .init(sentence: "合并两项所选内容。", facts: ["第一项保留条件", "第二项保留差异"],
                     suggestions: (0..<3).map { .init(id: "multi-\($0)", title: "整理\($0)", instruction: "合并所选内容") },
                     sourceIDs: input.cards.map(\.id), processedChunks: input.cards.count)
    }
    let blockMulti: Bool
    let blockSuggestion: Bool
    let blockTransform: Bool
    let output: String?
    let failTransform: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(blockSuggestion: Bool = false, blockTransform: Bool = false, blockMulti: Bool = false, output: String? = nil, failTransform: Bool = false) {
        self.blockMulti = blockMulti; self.blockSuggestion = blockSuggestion; self.blockTransform = blockTransform
        self.output = output; self.failTransform = failTransform
    }
    func suggest(_ input: ContextSuggestionInput) async throws -> [ContextSuggestion] {
        inputs.append(input)
        if blockSuggestion && inputs.count == 1 { await withCheckedContinuation { continuation = $0 } }
        return [.init(id: input.text, title: input.text, instruction: "Format this text")]
    }
    func transform(_ input: ContextSuggestionInput) async throws -> String {
        transformInputs.append(input)
        if blockTransform { await withCheckedContinuation { continuation = $0 } }
        if failTransform { throw CloudToolsError.invalidResponse }
        return output ?? "Transformed: \(input.text)"
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ContextSuggestionPasteEnvironment: PasteDispatchEnvironment {
    var accessibilityGranted = true
    var lastSendIssue: PasteIssue?
    var lastRestoreIssue: PasteIssue?
    var sendCount = 0
    func isAlive(_ target: PasteTarget) -> Bool { true }
    func activate(_ target: PasteTarget) -> Bool { true }
    func restoreFocus(_ target: PasteTarget) async -> Bool { true }
    func frontmostPID() -> pid_t? { 42 }
    func sendPaste(_ target: PasteTarget) async -> Bool { sendCount += 1; return true }
    func settle() async { await Task.yield() }
}
#endif
