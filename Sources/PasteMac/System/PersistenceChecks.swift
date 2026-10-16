#if DEBUG
import Foundation
import PasteCore

@MainActor
enum PersistenceChecks {
    private final class LegacyCounters: @unchecked Sendable {
        let lock = NSLock()
        var pending = 0
        var peak = 0
        var writes = 0
        var failure: String?
        func submitted() { lock.lock(); pending += 1; peak = max(peak, pending); lock.unlock() }
        func started() { lock.lock(); pending -= 1; lock.unlock() }
        func completed(_ error: String?) { lock.lock(); writes += 1; failure = error ?? failure; lock.unlock() }
    }
    static func run() async throws -> Int { try runSynchronous() }

    private static func runSynchronous() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SystemChecks.Failure(message: message) }
            count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-persistence-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let legacyQueue = DispatchQueue(label: "pasteboard.tests.legacy-storage")
        let legacyStarted = DispatchSemaphore(value: 0)
        let legacyRelease = DispatchSemaphore(value: 0)
        let legacy = LegacyCounters()
        func submitLegacy(_ index: Int) {
            let snapshot = ClipboardSnapshot(items: [ClipItem(text: "burst-\(index)", kind: .text)])
            legacy.submitted()
            legacyQueue.async {
                legacy.started()
                if index == 0 {
                    legacyStarted.signal()
                    _ = legacyRelease.wait(timeout: .now() + 10)
                }
                do { try repository.save(snapshot); legacy.completed(nil) }
                catch { legacy.completed(error.localizedDescription) }
            }
        }
        submitLegacy(0)
        guard legacyStarted.wait(timeout: .now() + 10) == .success else { throw SystemChecks.Failure(message: "legacy writer did not start") }
        for index in 1..<100 { submitLegacy(index) }
        legacyRelease.signal()
        legacyQueue.sync {}
        try check(legacy.writes == 100 && legacy.peak == 99 && legacy.failure == nil, "legacy burst baseline failed")
        try check(try repository.load().items.first?.text == "burst-99", "legacy baseline lost final state")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = SnapshotPersistence { snapshot in
            if snapshot.items.first?.text == "burst-0" {
                started.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw SystemChecks.Failure(message: "burst test timed out") }
            }
            try repository.save(snapshot)
        }
        writer.enqueue(.init(items: [ClipItem(text: "burst-0", kind: .text)])) { _, _ in }
        guard started.wait(timeout: .now() + 10) == .success else { throw SystemChecks.Failure(message: "writer did not start") }
        for index in 1..<100 {
            writer.enqueue(.init(items: [ClipItem(text: "burst-\(index)", kind: .text)])) { _, _ in }
        }
        release.signal()
        writer.flush()
        let metrics = writer.metrics
        try check(try repository.load().items.first?.text == "burst-99", "flush did not save latest state")
        try check(metrics.submitted == 100 && metrics.completedWrites == 2, "burst did not coalesce to two writes")
        try check(metrics.maximumPendingSnapshots == 1, "pending snapshot queue exceeded one")
        let imported = ClipboardSnapshot(items: [ClipItem(text: "imported", kind: .text)])
        try writer.performSynchronous { try repository.save(imported) }
        writer.flush()
        try check(try repository.load() == imported, "old queued write overwrote import")
        let failures = SnapshotPersistence { _ in throw SnapshotRepositoryError.invalidData("synthetic") }
        var failedRevision: UInt64 = 0
        let callbackLock = NSLock()
        let revision = failures.enqueue(imported) { revision, error in
            callbackLock.lock()
            if error != nil { failedRevision = revision }
            callbackLock.unlock()
        }
        failures.flush()
        callbackLock.lock(); let reported = failedRevision; callbackLock.unlock()
        try check(reported == revision && failures.isLatest(revision), "latest write failure was not reported")
        let newer = failures.enqueue(imported) { _, _ in }
        failures.flush()
        try check(!failures.isLatest(revision) && failures.isLatest(newer), "stale error callback remained eligible")
        let retryWriter = SnapshotPersistence { snapshot in
            if snapshot.items.first?.text == "bad" { throw SnapshotRepositoryError.invalidData("synthetic") }
            try repository.save(snapshot)
        }
        var results: [String?] = []
        retryWriter.enqueue(.init(items: [ClipItem(text: "bad", kind: .text)])) { _, error in
            callbackLock.lock(); results.append(error); callbackLock.unlock()
        }
        retryWriter.flush()
        retryWriter.enqueue(imported) { _, error in
            callbackLock.lock(); results.append(error); callbackLock.unlock()
        }
        retryWriter.flush()
        callbackLock.lock(); let retryResults = results; callbackLock.unlock()
        try check(retryResults.count == 2 && retryResults[0] != nil && retryResults[1] == nil, "successful retry did not clear the storage failure result")
        try check(try repository.load() == imported, "successful retry did not save latest snapshot")
        print("Persistence burst: old queue \(legacy.writes) writes / \(legacy.peak) pending; bounded queue \(metrics.completedWrites) writes / \(metrics.maximumPendingSnapshots) pending; final burst-99 saved")
        return count
    }
}
#endif
