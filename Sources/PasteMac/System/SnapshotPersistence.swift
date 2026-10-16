import Foundation
import PasteCore

/// At most one snapshot is being encoded and one newer snapshot is waiting.
/// State uses a condition lock; serialization and file I/O remain off the main thread.
final class SnapshotPersistence: @unchecked Sendable {
    struct Metrics {
        var submitted = 0
        var completedWrites = 0
        var maximumPendingSnapshots = 0
    }
    private struct Pending {
        let revision: UInt64
        let snapshot: ClipboardSnapshot
        let completion: (UInt64, String?) -> Void
    }
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "com.gaoxs.pasteboard.storage", qos: .utility)
    private let save: (ClipboardSnapshot) throws -> Void
    private var pending: Pending?
    private var draining = false
    private var revision: UInt64 = 0
    private var counters = Metrics()

    init(save: @escaping (ClipboardSnapshot) throws -> Void) { self.save = save }

    @discardableResult
    func enqueue(_ snapshot: ClipboardSnapshot, completion: @escaping (UInt64, String?) -> Void) -> UInt64 {
        condition.lock()
        revision &+= 1
        let token = revision
        counters.submitted += 1
        pending = Pending(revision: token, snapshot: snapshot, completion: completion)
        counters.maximumPendingSnapshots = max(counters.maximumPendingSnapshots, 1)
        let start = !draining
        draining = true
        condition.unlock()
        if start { queue.async { [self] in drain() } }
        return token
    }

    func isLatest(_ token: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return token == revision
    }
    var metrics: Metrics {
        condition.lock(); defer { condition.unlock() }
        return counters
    }
    func flush() {
        condition.lock(); defer { condition.unlock() }
        while draining { condition.wait() }
    }
    /// Call from the owning model after stopping new submissions (the model is main-actor isolated).
    /// Invalidates already delivered callbacks before a recovery/import replaces the file.
    func performSynchronous(_ operation: () throws -> Void) rethrows {
        flush()
        condition.lock(); revision &+= 1; condition.unlock()
        try queue.sync(execute: operation)
    }
    private func drain() {
        while let work = takeNext() {
            let failure: String?
            do { try save(work.snapshot); failure = nil }
            catch { failure = error.localizedDescription }
            condition.lock(); counters.completedWrites += 1; condition.unlock()
            work.completion(work.revision, failure)
        }
    }
    private func takeNext() -> Pending? {
        condition.lock(); defer { condition.unlock() }
        guard let value = pending else {
            draining = false
            condition.broadcast()
            return nil
        }
        pending = nil
        return value
    }
}
