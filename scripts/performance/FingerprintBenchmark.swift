import Foundation

@main struct FingerprintBenchmark {
    static var sink = 0
    static func measure(_ name: String, iterations: Int = 25, _ work: () throws -> Void) rethrows -> [String: Any] {
        try work()
        var values: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        values.sort()
        return ["name": name, "iterations": iterations, "median_ms": values[values.count / 2], "p95_ms": values[Int(Double(values.count - 1) * 0.95)]]
    }
    static func main() throws {
        let images = (0..<32).map { index in ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: Data(repeating: UInt8(index), count: 1024 * 1024))]) }
        let texts = (0..<1000).map { ClipItem(text: "Synthetic row \($0) " + String(repeating: "clipboard ", count: 50), kind: .text) }
        var imageSnapshot = ClipboardSnapshot(items: images)
        imageSnapshot.preferences.retentionDays = nil
        var textSnapshot = ClipboardSnapshot(items: texts)
        textSnapshot.preferences.retentionDays = nil
        let imageCandidate = ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: Data(repeating: 255, count: 1024 * 1024))])
        let textCandidate = ClipItem(text: "synthetic new row", kind: .text)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let results = try [
            measure("fingerprint_scan_32MiB") { sink += images.reduce(0) { $0 + $1.fingerprint.count } },
            measure("capture_new_image_32x1MiB") { sink += SnapshotOperations.capture(imageCandidate, in: imageSnapshot).items.count },
            measure("capture_new_text_1000x514B") { sink += SnapshotOperations.capture(textCandidate, in: textSnapshot).items.count },
            measure("search_1000_text_rows") { sink += SnapshotOperations.filteredItems(in: textSnapshot, query: "row 999", pinboardID: nil, filter: .init()).count },
            measure("save_32MiB_atomic_fsync", iterations: 5) { try repository.save(imageSnapshot) },
            measure("create_and_fingerprint_1MiB") { sink += ClipItem(text: "", kind: .image, representations: imageCandidate.representations).fingerprint.count }
        ]
        let output: [String: Any] = ["configuration": "swiftc -O, arm64, macOS SDK 27", "process": ProcessInfo.processInfo.operatingSystemVersionString, "method": "one warm-up, sequential monotonic clock, synthetic only, no real clipboard/history", "text_rows": texts.count, "text_utf8_bytes": texts.reduce(0) { $0 + $1.text.utf8.count }, "binary_payload_bytes": 32 * 1024 * 1024, "results": results, "sink": sink]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
