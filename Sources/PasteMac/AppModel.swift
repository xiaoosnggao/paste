import AppKit
import ApplicationServices
import Combine
import PasteCore
import Carbon
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: ClipboardSnapshot { didSet { cachedVisibleItems = nil; restoreSession() } }
    @Published var queryString = "" { didSet { cachedVisibleItems = nil } }
    @Published var selectedPinboardID: UUID? { didSet { cachedVisibleItems = nil } }
    @Published var selectedIDs: Set<UUID> = []
    @Published var filter = ClipFilter() { didSet { cachedVisibleItems = nil } }
    @Published var isSearchVisible = false
    @Published var usesRecommendations = false { didSet { cachedVisibleItems = nil } }
    private var cachedVisibleItems: [ClipItem]?
    private var cachedRecommendationTarget: String?
    @Published var statusMessage: String?
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
    @Published private(set) var isPasting = false
    @Published private(set) var storageError: String?
    @Published var toolConfiguration = CloudToolConfiguration() {
        didSet { if let data = try? JSONEncoder().encode(toolConfiguration) { toolDefaults.set(data, forKey: "cloudToolConfiguration.v1") } }
    }
    @Published var toolInputText = ""
    @Published var toolItemID: UUID?
    @Published var toolBusy = false
    @Published var toolStatus: String?
    @Published var toolError: String?
    @Published var toolPinned = false
    @Published var toolShortcuts: ToolShortcutManager?
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
    let pasteEngine = PasteEngine()
    let bridge: ClipboardBridge
    let repository: SnapshotRepository
    let storageDirectory: URL
    private lazy var persistence = SnapshotPersistence(save: repository.save)
    private var captureTimer: Timer?
    private var corruptStore = false
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

    init(isDemo: Bool = false, storageDirectory: URL? = nil, bridge: ClipboardBridge? = nil, toolOperations: ToolOperations? = nil, toolDefaults: UserDefaults = .standard) {
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
            do { snapshot = SnapshotOperations.prune(try repository.load()) }
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
        if !isDemo && !corruptStore { persist() }
    }

    var visibleItems: [ClipItem] {
        let target = usesRecommendations ? pasteEngine.target?.bundleID : nil
        if let cachedVisibleItems, cachedRecommendationTarget == target { return cachedVisibleItems }
        let items = SnapshotOperations.filteredItems(in: snapshot, query: queryString, pinboardID: selectedPinboardID, filter: filter)
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
    var pasteFailureText: String? { pasteIssue?.message }
    func refreshDirectPastePermission() {
        guard pasteEngine.accessibilityChecksEnabled else { return }
        hasCheckedDirectPastePermission = true
        directPastePermissionGranted = pasteEngine.accessibilityGranted
    }
    func requestDirectPastePermission() {
        pasteEngine.enableAccessibilityChecks()
        refreshDirectPastePermission()
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
            let captured = SnapshotOperations.capture(item, in: snapshot)
            guard captured.items.contains(where: { $0.fingerprint == item.fingerprint }) else {
                statusMessage = "历史容量已满，内容未保存。请取消部分收藏或提高历史记录上限。"
                return
            }
            try repository.validate(captured)
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
        selectFirstIfNeeded()
        paste(selectedItems, plainText: plainText)
    }

    func activate(_ item: ClipItem, plainText: Bool = false) {
        select(item)
        paste([item], plainText: plainText)
    }

    private func paste(_ items: [ClipItem], plainText: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isPasting else { return }
        pasteIssue = nil
        if snapshot.preferences.pasteToFrontmost { pasteEngine.enableAccessibilityChecks() }
        refreshDirectPastePermission()
        do { try bridge.write(items, plainText: plainText || snapshot.preferences.alwaysPlainText) }
        catch { statusMessage = error.localizedDescription; completion?(false); return }
        guard snapshot.preferences.pasteToFrontmost else {
            statusMessage = "已复制"
            onClose?()
            completion?(true)
            return
        }
        isPasting = true
        Task { @MainActor in
            let dispatched = await pasteEngine.dispatchPaste(closePanel: { [weak self] in
                if let prepare = self?.onPreparePaste { await prepare() }
                else { self?.onClose?() }
            })
            isPasting = false
            if !dispatched {
                pasteIssue = pasteEngine.lastIssue
                statusMessage = pasteIssue?.message
                if pasteIssue == .accessibilityPermissionRequired, onAccessibilityGuide != nil { requestDirectPastePermission() }
                else { onPasteFailure?() }
            }
            else { statusMessage = nil }
            completion?(dispatched)
        }
    }

    func copySelected(plainText: Bool = false) {
        guard !isPasting else { return }
        selectFirstIfNeeded()
        do { try bridge.write(selectedItems, plainText: plainText); statusMessage = "已复制" }
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
        commit(SnapshotOperations.pin(itemIDs: selectedItems.map(\.id), to: id, in: snapshot), action: "收藏卡片")
    }
    func unpinSelection() {
        guard let id = selectedPinboardID else { return }
        commit(SnapshotOperations.unpin(itemIDs: selectedItems.map(\.id), from: id, in: snapshot), action: "移出收藏夹")
    }
    func deleteSelected() {
        commit(SnapshotOperations.deleteItems(ids: Set(selectedItems.map(\.id)), in: snapshot), action: "删除卡片")
        selectFirstIfNeeded()
    }
    func clearHistory() {
        let pinned = Set(snapshot.pinboards.flatMap(\.itemIDs))
        let ids = Set(snapshot.items.map(\.id)).subtracting(pinned)
        commit(SnapshotOperations.deleteItems(ids: ids, in: snapshot), action: "清除历史")
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
        do { try repository.validate(pruned) }
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
    func edit(_ item: ClipItem) { onEditor?(item) }
    func closeEditor() { onEditorClose?() }
    func preview(_ item: ClipItem) { onPreview?(item) }
    func intelligence(_ item: ClipItem) { onIntelligence?(item) }
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
        let value = SnapshotOperations.normalizeSession(value)
        guard value != snapshot else { return true }
        do { try repository.validate(value) }
        catch { statusMessage = "修改未保存：\(error.localizedDescription)"; return false }
        let previous = snapshot
        undoManager.registerUndo(withTarget: self) { target in
            let restored = SnapshotOperations.undoChange(before: previous, after: value, in: target.snapshot)
            target.commit(restored, action: action)
        }
        undoManager.setActionName(action)
        snapshot = value
        persist()
        return true
    }

    func recoverStorageForImport(_ imported: ClipboardSnapshot) throws {
        guard corruptStore else { return }
        try persistence.performSynchronous {
            let file = storageDirectory.appendingPathComponent("clipboard.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = storageDirectory.appendingPathComponent("clipboard-damaged-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: file, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try repository.save(imported)
        }
        corruptStore = false
        storageError = nil
    }

    func persist() {
        guard !isDemo, !corruptStore else { return }
        persistence.enqueue(snapshot) { [weak self] revision, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.persistence.isLatest(revision) else { return }
                self.storageError = error.map { "保存失败，未保存的修改已暂存：\($0)" }
            }
        }
    }

    func retrySave() {
        if corruptStore { statusMessage = "无法读取数据文件。请备份原文件后导入有效备份。原文件已保留。" }
        else { persist() }
    }
    func flushPersistence() { persistence.flush() }
}
