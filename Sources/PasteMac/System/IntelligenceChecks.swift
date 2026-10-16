#if DEBUG
import AppKit
import PasteCore

@MainActor
enum IntelligenceChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: message) }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-intelligence-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("pasteboard.intelligence.checks.\(UUID())"))
        defer { board.releaseGlobally() }
        let model = AppModel(isDemo: true, storageDirectory: root, bridge: ClipboardBridge(pasteboard: board))
        let allIDs = model.visibleItems.map(\.id)
        try check(model.visibleItems.map(\.id) == allIDs, "repeat filtering changed ordering")
        model.filter = .init(kind: .image)
        try check(model.visibleItems.allSatisfy { $0.kind == .image }, "kind filter did not invalidate results")
        model.filter = .init()
        model.selectedPinboardID = model.snapshot.pinboards.first?.id
        try check(Set(model.visibleItems.map(\.id)).isSubset(of: Set(model.snapshot.pinboards.first?.itemIDs ?? [])), "pinboard filter returned other rows")
        model.selectedPinboardID = nil
        model.snapshot.items.removeAll()
        try check(model.visibleItems.isEmpty, "snapshot content mutation retained old results")
        model.snapshot = DemoData.snapshot()
        AppIntegration.shared.model = model
        var opened = 0
        AppIntegration.shared.openPanel = { opened += 1 }
        defer { AppIntegration.shared.model = nil; AppIntegration.shared.openPanel = nil }
        try AppIntegration.shared.run(.search("灵感"))
        try check(opened == 1 && model.queryString == "灵感" && !model.visibleItems.isEmpty, "integration search did not open filtered results")
        try AppIntegration.shared.run(.add(text: "App Intent isolation", title: "fixture"))
        guard let item = model.snapshot.items.first(where: { $0.text == "App Intent isolation" }) else { throw SystemChecks.Failure(message: "integration add missing") }
        try AppIntegration.shared.run(.copy(item.id))
        try check(board.string(forType: .string) == item.text, "integration copy did not write named board")
        try check(!IntelligenceService.availability.message.isEmpty, "model availability missing explanation")
        print("INTELLIGENCE: \(IntelligenceService.availability.message)")
        try check(try TextTools.apply(.links, to: "地址 https://example.com") == "https://example.com", "local link extraction failed")
        if !IntelligenceService.availability.available {
            do { _ = try await IntelligenceService.run(.summarize, text: "Isolated fixture"); throw SystemChecks.Failure(message: "unavailable model pretended success") }
            catch is IntelligenceService.Failure { count += 1 }
        }
        return count
    }
}
#endif
