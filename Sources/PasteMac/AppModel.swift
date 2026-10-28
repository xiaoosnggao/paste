import AppKit
import ApplicationServices
import Combine
import PasteCore
import Carbon
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: ClipboardSnapshot { didSet { trackStorageChanges(from: oldValue); cachedVisibleItems = nil; restoreSession(); scheduleContextSuggestions() } }
    @Published var queryString = "" { didSet { cachedVisibleItems = nil; scheduleHistoryQuery(); scheduleContextSuggestions() } }
    @Published var selectedPinboardID: UUID? { didSet { cachedVisibleItems = nil; scheduleHistoryQuery(); scheduleContextSuggestions() } }
    @Published var selectedIDs: Set<UUID> = [] { didSet { scheduleContextSuggestions(); syncPanelDetailToSelection() } }
    @Published var filter = ClipFilter() { didSet { cachedVisibleItems = nil; scheduleHistoryQuery(); scheduleContextSuggestions() } }
    @Published var isSearchVisible = false
    /// The detail layer above the deck, or nil when only the deck shows.
    @Published var panelDetail: PanelDetailState? { didSet { if panelDetail != oldValue { panelDetailChanged(from: oldValue) } } }
    /// The detail card height for the panel's current screen.
    @Published var panelDetailContentHeight = PanelDetailLayout.contentHeight
    var onPanelDetailChange: (() -> Void)?
    /// Unsaved editor text per card (nil key: a new text). Kept while the panel hides.
    var panelEditorDrafts: [UUID?: PanelEditorDraft] = [:]
    /// Set while a detail page starts a translation, so the tool shows in the panel instead of its window.
    var toolsHostedInPanel = false
    @Published var usesRecommendations = false { didSet { cachedVisibleItems = nil } }
    private var cachedVisibleItems: [ClipItem]?
    private var cachedRecommendationTarget: String?
    /// The panel's bottom notice. Confirmations and info clear themselves.
    @Published var notice: PanelNotice? { didSet { scheduleNoticeDismissal() } }
    private var noticeDismissal: Task<Void, Never>?
    /// Compatibility shim for call sites that still read or write plain text.
    var statusMessage: String? {
        get { notice?.text }
        set { notice = newValue.map(PanelNotice.init(legacyMessage:)) }
    }
    @Published var pasteIssue: PasteIssue?
    @Published private(set) var directPastePermissionGranted = false
    @Published private(set) var hasCheckedDirectPastePermission = false
    @Published private(set) var pauseUntil: Date?
    @Published var processingImageIDs: Set<UUID> = []
    var imageProcessingTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var stackItems: [ClipItem] = []
    @Published private(set) var stackReversed = false
    @Published private(set) var hotKeyDescription = "⇧⌘V"
    @Published private(set) var stackHotKeyDescription = "⇧⌘C"
    @Published private(set) var isPasting = false { didSet { scheduleContextSuggestions() } }
    @Published var storageError: String?
    @Published var toolConfiguration = CloudToolConfiguration() {
        didSet {
            if let data = try? JSONEncoder().encode(toolConfiguration) { toolDefaults.set(data, forKey: "cloudToolConfiguration.v1") }
            scheduleContextSuggestions()
            let ocrChanged = !toolConfiguration.hasSameOCRSettings(as: oldValue)
            let translationChanged = !toolConfiguration.hasSameTranslationSettings(as: oldValue)
            if ocrChanged || translationChanged {
                cancelAutoTranslation()
                refreshToolAfterConfigurationChange(recognizeImage: ocrChanged)
            }
        }
    }
    @Published var multiCardSummary: MultiCardContextSummary? { didSet { onSuggestionPanelChange?(contextSuggestionsPresented) } }
    @Published var multiCardSummaryExpanded = false { didSet { onSuggestionPanelChange?(contextSuggestionsPresented) } }
    @Published var contextSuggestionProgress: String?
    var onSuggestionPreview: ((ContextSuggestionPreviewResult) -> Void)?
    var multiCardSummaryCache: [(ContextSuggestionRequestKey, MultiCardContextSummary)] = []
    @Published var contextSuggestions: [ContextSuggestion] = []
    @Published var contextSuggestionsLoading = false {
        didSet {
            if contextSuggestionsLoading != oldValue { onSuggestionPanelChange?(contextSuggestionsPresented) }
        }
    }
    @Published var contextSuggestionApplyingID: String?
    @Published var contextSuggestionsError: String?
    @Published var contextSuggestionsVisible = false
    var suggestionSessionActive = false {
        didSet {
            if !suggestionSessionActive { dismissContextSuggestions() }
            else if !oldValue { dismissedContextSuggestionKey = nil }
        }
    }
    var onSuggestionPanelChange: ((Bool) -> Void)?
    let suggestionOperations: ContextSuggestionOperations
    let suggestionOperationsInjected: Bool
    let suggestionDelayNanoseconds: UInt64
    var contextSuggestionTask: Task<Void, Never>?
    var contextSuggestionMutationInProgress = false
    var contextSuggestionGeneration = UUID()
    var contextSuggestionKey: ContextSuggestionRequestKey?
    var dismissedContextSuggestionKey: ContextSuggestionRequestKey?
    var contextSuggestionCache: [(ContextSuggestionRequestKey, [ContextSuggestion])] = []
    @Published var toolInputText = ""
    @Published var toolItemID: UUID?
    @Published var toolBusy = false { didSet { scheduleContextSuggestions() } }
    @Published var toolStatus: String?
    @Published var toolError: String?
    @Published var toolPinned = false
    @Published var toolShortcuts: ToolShortcutManager?
    var autoTranslationTask: Task<Void, Never>?
    var toolInputIsComposing = false
    var toolSessionActive = false
    var autoTranslationGeneration = UUID()
    var completedToolTranslation: (text: String, configuration: CloudToolConfiguration, itemID: UUID)?
    let autoTranslationDelayNanoseconds: UInt64
    var toolTask: Task<Void, Never>?
    var toolGeneration = UUID()
    var lastToolOperation: ToolAction = .inputTranslate
    let toolOperations: ToolOperations
    let toolDefaults: UserDefaults
    var onShowTools: (() -> Void)?
    var onScreenshotTool: ((Bool) -> Void)?
    var onSelectionTool: (() -> Void)?
    var onToolStart: (() -> Void)?
    let isDemo: Bool
    let undoManager = UndoManager()
    let pasteEngine: PasteEngine
    let bridge: ClipboardBridge
    let repository: SnapshotRepository
    let storageDirectory: URL
    lazy var persistence = SnapshotPersistence(save: repository.save)
    private var captureTimer: Timer?
    var corruptStore = false
    var loadingHistoryWindow = false
    var dirtyHistoryItems: [UUID: ClipItem] = [:]
    var deletedHistoryIDs: Set<UUID> = []
    @Published var historyManagementPreview: HistoryManagementPreview? { didSet { if historyManagementPreview == nil { onHistoryManagementClose?() } } }
    var onHistoryManagementClose: (() -> Void)?
    var onHistoryManagementPreview: ((HistoryManagementPreview) -> Void)?
    @Published var historyResultIDs: [UUID] = [] { didSet { cachedVisibleItems = nil } }
    var activeHistoryReferences: [String: Set<UUID>] = [:]
    @Published var historyLoading = false
    @Published var historyHasMore = false
    @Published var historyTotalCount = 0
    var historyPageOffset = 0
    var historyQueryGeneration = UUID()
    var historyQueryTask: Task<Void, Never>?
    var knowledgeCoordinator: LocalKnowledgeCoordinator?
    @Published var localIndexStatus: String?
    @Published var automaticClassificationEnabled = true
    @Published var suggestedCategories: [UUID: [UUID]] = [:]
    var manualClassificationOverrides: [UUID: Set<UUID>] = [:]
    private var pendingPauseIndefinite = false
    private var lastSelection: UUID?
    var onClose: (() -> Void)?
    var onPreparePaste: (() async -> Void)?
    var onPasteFailure: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAccessibilityGuide: (() -> Void)?
    var onEditor: ((ClipItem?) -> Void)?
    var onEditorClose: (() -> Void)?
    var onPreview: ((ClipItem) -> Void)?
    var onIntelligence: ((ClipItem) -> Void)?
    var onStack: (() -> Void)?
    var onShortcut: ((UInt32, UInt32) -> Bool)?
    var onStackShortcut: ((UInt32, UInt32) -> Bool)?

    init(isDemo: Bool = false, storageDirectory: URL? = nil, bridge: ClipboardBridge? = nil, toolOperations: ToolOperations? = nil, toolDefaults: UserDefaults = .standard, pasteEngine: PasteEngine? = nil, autoTranslationDelayNanoseconds: UInt64 = 750_000_000, suggestionOperations: ContextSuggestionOperations? = nil, suggestionDelayNanoseconds: UInt64 = 250_000_000) {
        self.suggestionOperations = suggestionOperations ?? .live()
        self.suggestionOperationsInjected = suggestionOperations != nil
        self.suggestionDelayNanoseconds = suggestionDelayNanoseconds
        self.autoTranslationDelayNanoseconds = autoTranslationDelayNanoseconds
        self.pasteEngine = pasteEngine ?? PasteEngine()
        self.isDemo = isDemo
        self.toolOperations = toolOperations ?? .live()
        self.toolDefaults = toolDefaults
        self.bridge = bridge ?? ClipboardBridge()
        let root = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDemo ? "Pasteboard-Demo" : "Pasteboard", isDirectory: true)
        self.storageDirectory = root
        repository = SnapshotRepository(directory: root)
        if isDemo {
            snapshot = DemoData.snapshot()
        } else {
            do {
                var initial = try repository.loadMetadata()
                let page = try repository.loadItems(limit: 50, offset: 0, query: "", pinboardID: nil, filter: .init(), includePayload: false)
                let stacked = try repository.loadItems(ids: initial.session?.stackItemIDs ?? [])
                var seen = Set<UUID>()
                initial.items = (page + stacked).filter { seen.insert($0.id).inserted }
                snapshot = initial
                historyResultIDs = page.map(\.id)
                historyTotalCount = try repository.itemCount()
                historyHasMore = page.count == 50 && historyTotalCount > page.count
            }
            catch {
                snapshot = .init()
                corruptStore = true
                storageError = "无法读取已有数据，原文件已保留：\(error.localizedDescription)"
            }
        }
        restoreSession()
        if let data = toolDefaults.data(forKey: "cloudToolConfiguration.v1"),
           let configuration = try? JSONDecoder().decode(CloudToolConfiguration.self, from: data) { toolConfiguration = configuration }
        selectFirstIfNeeded()
        if !isDemo && !corruptStore && storageDirectory == nil { startLocalKnowledge() }
    }

    var visibleItems: [ClipItem] {
        let target = usesRecommendations ? pasteEngine.target?.bundleID : nil
        if let cachedVisibleItems, cachedRecommendationTarget == target { return cachedVisibleItems }
        let items: [ClipItem]
        if !isDemo {
            let byID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            items = historyResultIDs.compactMap { byID[$0] }
        } else {
            items = SnapshotOperations.filteredItems(in: snapshot, query: queryString, pinboardID: selectedPinboardID, filter: filter)
        }
        let result = usesRecommendations && queryString.isEmpty && selectedPinboardID == nil
            ? TextTools.recommended(items, for: target, limit: 100) : items
        cachedRecommendationTarget = target
        cachedVisibleItems = result
        return result
    }
    var selectedItems: [ClipItem] { visibleItems.filter { selectedIDs.contains($0.id) } }
    var activePinboard: Pinboard? { snapshot.pinboards.first { $0.id == selectedPinboardID } }
    var isPaused: Bool { pendingPauseIndefinite || (pauseUntil.map { $0 > Date() } ?? false) || !snapshot.preferences.monitoringEnabled }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var pasteFailureText: String? {
        pasteIssue == .accessibilityPermissionRequired ? nil : pasteIssue?.message
    }
    func refreshDirectPastePermission() {
        guard pasteEngine.accessibilityChecksEnabled else { return }
        hasCheckedDirectPastePermission = true
        directPastePermissionGranted = pasteEngine.accessibilityGranted
    }
    func requestDirectPastePermission() {
        if !isDemo {
            pasteEngine.enableAccessibilityChecks()
            refreshDirectPastePermission()
        }
        onAccessibilityGuide?()
    }

    func startMonitoring() {
        guard !isDemo else { return }
        stopMonitoring()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
        captureTimer?.tolerance = 0.05
    }
    func stopMonitoring() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    func capture() {
        if let until = pauseUntil, until <= Date() {
            pauseUntil = nil
            persistSession()
        }
        do {
            guard let item = try bridge.capture(preferences: snapshot.preferences, paused: isPaused) else { return }
            let captured = captureInHistory(item)
            try validateCurrentWindow(captured)
            snapshot = captured
            persist()
            if snapshot.preferences.soundEnabled { NSSound(named: "Pop")?.play() }
        } catch { statusMessage = error.localizedDescription }
    }

    func select(_ item: ClipItem, extend: Bool = false) {
        if extend {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else { selectedIDs = [item.id] }
        lastSelection = item.id
    }

    func moveSelection(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == lastSelection } ?? items.firstIndex { selectedIDs.contains($0.id) } ?? 0
        select(items[max(0, min(items.count - 1, current + delta))])
    }

    func selectFirstIfNeeded() {
        let valid = Set(visibleItems.map(\.id))
        selectedIDs = selectedIDs.intersection(valid)
        if selectedIDs.isEmpty, let first = visibleItems.first { select(first) }
    }

    func activateSelected(plainText: Bool = false) {
        guard contextSuggestionApplyingID == nil else { return }
        selectFirstIfNeeded()
        paste(selectedItems, plainText: plainText)
    }

    func activate(_ item: ClipItem, plainText: Bool = false) {
        guard contextSuggestionApplyingID == nil else { return }
        // Preserve the visible AI context (including multi-selection) until the panel exits.
        // The clicked item is passed directly to paste; changing the selection would collapse it early.
        if !contextSuggestionsPresented { select(item) }
        paste([item], plainText: plainText)
    }

    private func paste(_ requested: [ClipItem], plainText: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isPasting, contextSuggestionApplyingID == nil else { return }
        let items = materializedItems(requested)
        guard !items.isEmpty else { completion?(false); return }
        pasteIssue = nil
        if snapshot.preferences.pasteToFrontmost { pasteEngine.enableAccessibilityChecks() }
        refreshDirectPastePermission()
        do { try bridge.write(items, plainText: plainText || snapshot.preferences.alwaysPlainText) }
        catch { statusMessage = error.localizedDescription; completion?(false); return }
        guard snapshot.preferences.pasteToFrontmost else {
            notice = .copied
            onClose?()
            completion?(true)
            return
        }
        isPasting = true
        Task { @MainActor in
            var panelClosed = false
            let dispatched = await pasteEngine.dispatchPaste(closePanel: { [weak self] in
                if let prepare = self?.onPreparePaste { await prepare() }
                else { self?.onClose?() }
                panelClosed = true
            })
            isPasting = false
            if !dispatched, pasteEngine.lastIssue?.usesCopyOnlyFallback == true {
                // The clip is already written. Missing destinations are normal copy-only use.
                notice = .copied
                if !panelClosed { onClose?() }
            } else if !dispatched {
                pasteIssue = pasteEngine.lastIssue
                if pasteIssue == .accessibilityPermissionRequired, onAccessibilityGuide != nil {
                    statusMessage = nil
                    requestDirectPastePermission()
                } else {
                    statusMessage = pasteIssue?.message
                    onPasteFailure?()
                }
            }
            else { statusMessage = nil }
            completion?(dispatched)
        }
    }

    private func scheduleNoticeDismissal() {
        noticeDismissal?.cancel()
        guard let current = notice, let delay = current.autoDismissDelay else { noticeDismissal = nil; return }
        noticeDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.notice == current else { return }
            self.notice = nil
        }
    }

    func copySelected(plainText: Bool = false) {
        guard contextSuggestionApplyingID == nil, !isPasting else { return }
        selectFirstIfNeeded()
        do { try bridge.write(materializedItems(selectedItems), plainText: plainText); notice = .copied }
        catch { statusMessage = error.localizedDescription }
    }

    func createPinboard(name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let result = SnapshotOperations.addPinboard(name: name.isEmpty ? "未命名" : name, to: snapshot)
        if commit(result, action: "创建收藏夹") { selectedPinboardID = result.pinboards.last?.id }
    }
    func renamePinboard(_ id: UUID, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commit(SnapshotOperations.renamePinboard(id: id, name: String(name.prefix(100)), in: snapshot), action: "重命名收藏夹")
    }
    func deletePinboard(_ id: UUID) {
        commit(SnapshotOperations.deletePinboard(id: id, in: snapshot), action: "删除收藏夹")
        if selectedPinboardID == id { selectedPinboardID = nil }
    }
    func pinSelection(to id: UUID) {
        let ids = selectedItems.map(\.id)
        if commit(SnapshotOperations.pin(itemIDs: ids, to: id, in: snapshot), action: "收藏卡片") { recordManualClassification(ids: ids, categoryID: id, removing: false) }
    }
    func unpinSelection() {
        guard let id = selectedPinboardID else { return }
        let ids = selectedItems.map(\.id)
        if commit(SnapshotOperations.unpin(itemIDs: ids, from: id, in: snapshot), action: "移出收藏夹") { recordManualClassification(ids: ids, categoryID: id, removing: true) }
    }
    func deleteSelected() {
        commit(SnapshotOperations.deleteItems(ids: Set(selectedItems.map(\.id)), in: snapshot), action: "删除卡片")
        selectFirstIfNeeded()
    }
    func clearHistory() {
        if isDemo {
            let pinned = Set(snapshot.pinboards.flatMap(\.itemIDs))
            _ = commit(SnapshotOperations.deleteItems(ids: Set(snapshot.items.map(\.id)).subtracting(pinned), in: snapshot), action: "清除历史")
        } else {
            do { try deleteHistoryBatch(ids: Set(repository.allItemIDs(unfiledOnly: true))) }
            catch { statusMessage = "删除失败：\(error.localizedDescription)" }
        }
        selectFirstIfNeeded()
    }
    func reorderPinboard(_ id: UUID, itemIDs: [UUID]) {
        guard let board = snapshot.pinboards.first(where: { $0.id == id }), Set(board.itemIDs) == Set(itemIDs) else { return }
        var next = snapshot
        next.pinboards = next.pinboards.map { $0.id == id ? Pinboard(id: $0.id, name: $0.name, colorHex: $0.colorHex, itemIDs: itemIDs) : $0 }
        commit(next, action: "调整顺序")
    }
    func updatePreferences(_ value: AppPreferences) {
        var next = snapshot
        next.preferences = value
        let pruned = SnapshotOperations.prune(next)
        do { try validateCurrentWindow(pruned) }
        catch { statusMessage = error.localizedDescription; return }
        snapshot = pruned
        persist()
    }
    func pause(minutes: Int?) {
        pendingPauseIndefinite = minutes == nil
        pauseUntil = minutes.map { Date().addingTimeInterval(Double(max(0, $0)) * 60) }
        persistSession()
    }
    func resume() {
        pendingPauseIndefinite = false
        pauseUntil = nil
        persistSession()
        if !snapshot.preferences.monitoringEnabled {
            var value = snapshot.preferences
            value.monitoringEnabled = true
            updatePreferences(value)
        }
    }
    func openSettings() { onSettings?() }
    func newText() { onEditor?(nil) }
    func edit(_ item: ClipItem) { if let loaded = materializedItems([item]).first { onEditor?(loaded) } }
    func closeEditor() { onEditorClose?() }
    func preview(_ item: ClipItem) { if let loaded = materializedItems([item]).first { onPreview?(loaded) } }
    func intelligence(_ item: ClipItem) { if let loaded = materializedItems([item]).first { onIntelligence?(loaded) } }
    func showStack() {
        if stackItems.isEmpty { setStack(selectedItems) }
        onStack?()
    }
    func setStack(_ items: [ClipItem]) {
        let valid = Set(snapshot.items.map(\.id))
        var seen: Set<UUID> = []
        stackItems = items.filter { valid.contains($0.id) && seen.insert($0.id).inserted }
        persistSession()
    }
    func setStackReversed(_ reversed: Bool) {
        stackReversed = reversed
        persistSession()
    }
    private func restoreSession() {
        let session = SnapshotOperations.normalizeSession(snapshot).session ?? SessionState()
        let itemsByID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stackItems = session.stackItemIDs.compactMap { itemsByID[$0] }
        stackReversed = session.stackReversed
        pauseUntil = session.pauseUntil
        pendingPauseIndefinite = session.pauseIndefinitely
    }
    private func persistSession() {
        var next = snapshot
        next.session = SessionState(stackItemIDs: stackItems.map(\.id), stackReversed: stackReversed,
                                    pauseUntil: pauseUntil, pauseIndefinitely: pendingPauseIndefinite)
        next = SnapshotOperations.normalizeSession(next)
        guard next != snapshot else { restoreSession(); return }
        snapshot = next
        persist()
    }
    func pasteNextStack() {
        guard let next = stackReversed ? stackItems.last : stackItems.first else { return }
        paste([next]) { [weak self] successful in
            guard successful, let self else { return }
            self.setStack(self.stackItems.filter { $0.id != next.id })
        }
    }
    func undo() { undoManager.undo(); selectFirstIfNeeded() }
    func redo() { undoManager.redo(); selectFirstIfNeeded() }

    func setShortcut(keyCode: UInt32, modifiers: UInt32, description: String) {
        guard modifiers != 0, onShortcut?(keyCode, modifiers) == true else {
            statusMessage = "无法设置快捷键。请使用包含 ⌘、⌥ 或 ⌃ 且未被占用的组合。"
            return
        }
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "shortcutModifiers")
        UserDefaults.standard.set(description, forKey: "shortcutDescription")
        hotKeyDescription = description
    }
    func restoreShortcutDescription(_ value: String) { hotKeyDescription = value }
    func restoreStackShortcutDescription(_ value: String) { stackHotKeyDescription = value }
    func setStackShortcut(keyCode: UInt32, modifiers: UInt32, description: String) {
        guard modifiers != 0, onStackShortcut?(keyCode, modifiers) == true else {
            statusMessage = "连续粘贴快捷键已被占用，请更换组合。"; return
        }
        UserDefaults.standard.set(Int(keyCode), forKey: "stackShortcutKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "stackShortcutModifiers")
        UserDefaults.standard.set(description, forKey: "stackShortcutDescription")
        stackHotKeyDescription = description
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { statusMessage = "无法更改登录时启动设置：\(error.localizedDescription)" }
    }

    @discardableResult
    func commit(_ value: ClipboardSnapshot, action: String) -> Bool {
        let value = isDemo ? SnapshotOperations.normalizeSession(value) : value
        guard value != snapshot else { return true }
        do { try validateCurrentWindow(value) }
        catch { statusMessage = "修改未保存：\(error.localizedDescription)"; return false }
        let previous = snapshot
        let changedIDs = Set(previous.items.map(\.id)).symmetricDifference(Set(value.items.map(\.id))).union(previous.items.compactMap { old in value.items.first(where: { $0.id == old.id }) != old ? old.id : nil })
        var undoBefore = previous; undoBefore.items = materializedItems(previous.items.filter { changedIDs.contains($0.id) })
        var undoAfter = value; undoAfter.items = value.items.filter { changedIDs.contains($0.id) }
        undoManager.registerUndo(withTarget: self) { target in
            target.ensureHistoryItemsLoaded(changedIDs)
            let restored = SnapshotOperations.undoChange(before: undoBefore, after: undoAfter, in: target.snapshot, preserveUnloadedReferences: !target.isDemo)
            let priorBoards = target.snapshot.pinboards
            if target.commit(restored, action: action) {
                for board in priorBoards {
                    let nextIDs = Set(restored.pinboards.first(where: { $0.id == board.id })?.itemIDs ?? [])
                    let oldIDs = Set(board.itemIDs)
                    target.recordManualClassification(ids: Array(oldIDs.subtracting(nextIDs)), categoryID: board.id, removing: true)
                    target.recordManualClassification(ids: Array(nextIDs.subtracting(oldIDs)), categoryID: board.id, removing: false)
                }
            }
        }
        undoManager.setActionName(action)
        snapshot = value
        persist()
        return true
    }

    func recoverStorageForImport(_ imported: ClipboardSnapshot) throws {
        if corruptStore { try recoverCorruptHistory(imported) }
    }

    func persist() {
        guard !isDemo, !corruptStore else { return }
        let upserts = Array(dirtyHistoryItems.values), deleted = deletedHistoryIDs
        let metadata = snapshot
        persistence.enqueue(snapshot, operation: { [repository] in
            try repository.applyChanges(metadata: metadata, upserting: upserts, deleting: deleted)
        }) { [weak self] revision, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.persistence.isLatest(revision) else { return }
                self.storageError = error.map { "保存失败，未保存的修改已暂存：\($0)" }
                if error == nil {
                    self.dirtyHistoryItems.removeAll(); self.deletedHistoryIDs.removeAll()
                    self.indexSavedItems(upserts, deleted: deleted)
                    self.scheduleHistoryQuery()
                }
            }
        }
    }

    func retrySave() {
        if corruptStore { statusMessage = "无法读取数据文件。请备份原文件后导入有效备份。原文件已保留。" }
        else { persist() }
    }
    func flushPersistence() { persistence.flush() }
}
