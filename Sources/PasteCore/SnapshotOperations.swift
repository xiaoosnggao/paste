import Foundation

public enum SnapshotOperations {
    public static func capture(_ item: ClipItem, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot
        let fingerprint = item.fingerprint
        if let index = result.items.firstIndex(where: { $0.fingerprint == fingerprint && $0.derivation == item.derivation }) {
            var promoted = item
            promoted.id = result.items[index].id
            promoted.createdAt = result.items[index].createdAt
            // Preserve a user's explicit title when recopying the same content.
            promoted.title = result.items[index].title
            promoted.enrichment = result.items[index].enrichment ?? item.enrichment
            promoted.originalRepresentations = item.originalRepresentations ?? result.items[index].originalRepresentations
            result.items.remove(at: index)
            result.items.insert(promoted, at: 0)
        } else { result.items.insert(item, at: 0) }
        return prune(result)
    }
    public static func prune(_ snapshot: ClipboardSnapshot, now: Date = Date()) -> ClipboardSnapshot {
        // Legacy retention preferences never remove captured content. Only explicit deletion does.
        normalizeSession(snapshot, now: now)
    }
    /// Keeps session references valid without restoring already consumed queue entries.
    public static func normalizeSession(_ snapshot: ClipboardSnapshot, now: Date = Date()) -> ClipboardSnapshot {
        guard var session = snapshot.session else { return snapshot }
        let valid = Set(snapshot.items.map(\.id))
        var seen: Set<UUID> = []
        session.stackItemIDs = session.stackItemIDs.filter { valid.contains($0) && seen.insert($0).inserted }
        if session.pauseIndefinitely { session.pauseUntil = nil }
        else if let until = session.pauseUntil, until <= now { session.pauseUntil = nil }
        var result = snapshot
        result.session = session
        return result
    }
    public static func filteredItems(in snapshot: ClipboardSnapshot, query: String, pinboardID: UUID?, filter: ClipFilter) -> [ClipItem] {
        let candidates: [ClipItem]
        if let pinboardID {
            let itemsByID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            candidates = (snapshot.pinboards.first(where: { $0.id == pinboardID })?.itemIDs ?? []).compactMap { itemsByID[$0] }
        } else { candidates = snapshot.items }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { item in
            if let kind = filter.kind, item.kind != kind { return false }
            if let source = filter.sourceBundleID, item.sourceBundleID != source { return false }
            if let source = filter.sourceName {
                let aliases = ["微信": "wechat", "飞书": "lark", "VS Code": "code", "Chrome": "chrome"]
                let alias = aliases[source] ?? source
                guard [item.sourceName, item.sourceBundleID].contains(where: { $0.localizedCaseInsensitiveContains(source) || $0.localizedCaseInsensitiveContains(alias) }) else { return false }
            }
            if let since = filter.since, item.lastCopiedAt < since { return false }
            if let until = filter.until, item.lastCopiedAt >= until { return false }
            return term.isEmpty || [item.title, item.text, item.sourceName, item.enrichment?.ocr?.text ?? "", item.enrichment?.translation?.translatedText ?? "", item.enrichment?.translation?.sourceText ?? ""].joined(separator: "\n").range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil || item.filePaths.contains { $0.range(of: term, options: .caseInsensitive) != nil }
        }
    }
    public static func addPinboard(name: String, to snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.pinboards.append(.init(name: trimmed)) }; return result
    }
    public static func renamePinboard(id: UUID, name: String, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let index = result.pinboards.firstIndex(where: { $0.id == id }) { result.pinboards[index].name = trimmed }; return result
    }
    public static func deletePinboard(id: UUID, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; result.pinboards.removeAll { $0.id == id }; return result
    }
    public static func pin(itemIDs: [UUID], to pinboardID: UUID, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot
        guard let index = result.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return result }
        let existing = Set(snapshot.items.map(\.id)); var members = Set(result.pinboards[index].itemIDs)
        for id in itemIDs where existing.contains(id) { if members.insert(id).inserted { result.pinboards[index].itemIDs.append(id) } }
        return result
    }
    public static func unpin(itemIDs: [UUID], from pinboardID: UUID, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; let removed = Set(itemIDs)
        if let index = result.pinboards.firstIndex(where: { $0.id == pinboardID }) { result.pinboards[index].itemIDs.removeAll { removed.contains($0) } }; return result
    }
    public static func deleteItems(ids: Set<UUID>, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; result.items.removeAll { ids.contains($0.id) }
        result.pinboards = result.pinboards.map { board in var copy = board; copy.itemIDs.removeAll { ids.contains($0) }; return copy }; return normalizeSession(result)
    }
    public static func replaceItem(_ item: ClipItem, in snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var result = snapshot; if let index = result.items.firstIndex(where: { $0.id == item.id }) { result.items[index] = item }; return result
    }
    /// Reverses a user operation against current state, retaining later clipboard captures.
    public static func undoChange(before: ClipboardSnapshot, after: ClipboardSnapshot, in current: ClipboardSnapshot, preserveUnloadedReferences: Bool = false) -> ClipboardSnapshot {
        var result = current
        result.items = inverseEntries(before: before.items, after: after.items, current: current.items) { old, changed, live in
            var item = live
            revert(\.createdAt, before: old, after: changed, value: &item)
            revert(\.lastCopiedAt, before: old, after: changed, value: &item)
            revert(\.title, before: old, after: changed, value: &item)
            revert(\.text, before: old, after: changed, value: &item)
            revert(\.kind, before: old, after: changed, value: &item)
            revert(\.sourceBundleID, before: old, after: changed, value: &item)
            revert(\.sourceName, before: old, after: changed, value: &item)
            revert(\.representations, before: old, after: changed, value: &item)
            revert(\.originalRepresentations, before: old, after: changed, value: &item)
            revert(\.derivation, before: old, after: changed, value: &item)
            revert(\.filePaths, before: old, after: changed, value: &item)
            if old.enrichment != changed.enrichment {
                var enrichment = live.enrichment ?? ClipEnrichment()
                revert(\.ocr, before: old.enrichment ?? .init(), after: changed.enrichment ?? .init(), value: &enrichment)
                revert(\.translation, before: old.enrichment ?? .init(), after: changed.enrichment ?? .init(), value: &enrichment)
                item.enrichment = enrichment.ocr == nil && enrichment.translation == nil && old.enrichment == nil ? nil : enrichment
            }
            return item
        }
        let validIDs = Set(result.items.map(\.id))
        result.pinboards = inverseEntries(before: before.pinboards, after: after.pinboards, current: current.pinboards) { old, changed, live in
            var board = live
            revert(\.name, before: old, after: changed, value: &board)
            revert(\.colorHex, before: old, after: changed, value: &board)
            board.itemIDs = inverseMembership(before: old.itemIDs, after: changed.itemIDs, current: live.itemIDs)
            return board
        }.map { board in
            var value = board; if !preserveUnloadedReferences { value.itemIDs = value.itemIDs.filter { validIDs.contains($0) } }; return value
        }
        result.pinboards = inverseOrder(before: before.pinboards, after: after.pinboards, current: result.pinboards)
        if before.preferences != after.preferences && current.preferences == after.preferences { result.preferences = before.preferences }
        return preserveUnloadedReferences ? result : normalizeSession(result)
    }
    private static func revert<Value, Field: Equatable>(_ key: WritableKeyPath<Value, Field>, before: Value, after: Value, value: inout Value) {
        if before[keyPath: key] != after[keyPath: key] && value[keyPath: key] == after[keyPath: key] { value[keyPath: key] = before[keyPath: key] }
    }
    private static func inverseEntries<Entry: Identifiable & Equatable>(before: [Entry], after: [Entry], current: [Entry], update: (Entry, Entry, Entry) -> Entry) -> [Entry] where Entry.ID == UUID {
        let oldByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = current.filter { entry in
            // Keep a newly created entry if a later operation has changed it.
            !(oldByID[entry.id] == nil && afterByID[entry.id] == entry)
        }.map { entry -> Entry in
            guard let old = oldByID[entry.id], let changed = afterByID[entry.id], old != changed else { return entry }
            return update(old, changed, entry)
        }
        for (index, entry) in before.enumerated() where afterByID[entry.id] == nil && !result.contains(where: { $0.id == entry.id }) {
            let successors = Set(before.dropFirst(index + 1).map(\.id))
            let position = result.firstIndex(where: { successors.contains($0.id) }) ?? result.endIndex
            result.insert(entry, at: position)
        }
        return result
    }
    private static func inverseMembership(before: [UUID], after: [UUID], current: [UUID]) -> [UUID] {
        let beforeSet = Set(before); let afterSet = Set(after)
        let additions = afterSet.subtracting(beforeSet)
        var result = current.filter { !additions.contains($0) }
        for (index, id) in before.enumerated() where !afterSet.contains(id) && !result.contains(id) {
            let successors = Set(before.dropFirst(index + 1))
            let position = result.firstIndex(where: { successors.contains($0) }) ?? result.endIndex
            result.insert(id, at: position)
        }
        let common = beforeSet.intersection(afterSet)
        if before.filter({ common.contains($0) }) != after.filter({ common.contains($0) }) {
            // Restore only operation-owned ordering slots, retaining later added members.
            var ordered = before.filter { common.contains($0) && result.contains($0) }.makeIterator()
            result = result.map { common.contains($0) ? (ordered.next() ?? $0) : $0 }
        }
        return result
    }

    private static func inverseOrder<Entry: Identifiable>(before: [Entry], after: [Entry], current: [Entry]) -> [Entry] where Entry.ID == UUID {
        let commonIDs = Set(before.map(\.id)).intersection(after.map(\.id))
        let oldOrder = before.map(\.id).filter { commonIDs.contains($0) }
        let changedOrder = after.map(\.id).filter { commonIDs.contains($0) }
        guard oldOrder != changedOrder else { return current }
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var restored = oldOrder.compactMap { currentByID[$0] }.makeIterator()
        return current.map { commonIDs.contains($0.id) ? (restored.next() ?? $0) : $0 }
    }

}
