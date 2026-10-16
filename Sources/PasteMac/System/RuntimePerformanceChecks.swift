#if DEBUG
import AppKit
import ImageIO
import PasteCore
import Darwin

/// Opt-in synthetic measurements inside the native self-test process, with no personal history.
@MainActor
enum RuntimePerformanceChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SystemChecks.Failure(message: message) }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-runtime-performance-\(UUID())")
        let board = NSPasteboard(name: .init("pasteboard.runtime.performance.\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageDirectory: root, bridge: ClipboardBridge(pasteboard: board))
        defer { model.stopMonitoring(); model.flushPersistence() }
        model.flushPersistence()
        var measurements: [[String: Any]] = []
        let boardChange = board.changeCount
        for size in [0, 1000] {
            model.stopMonitoring()
            model.snapshot = syntheticSnapshot(count: size)
            model.flushPersistence()
            model.startMonitoring()
            let startCPU = try cpuSeconds()
            let startRSS = residentBytes()
            try check(startRSS > 0, "task_info resident memory sampling failed")
            var maximumObservedRSS = startRSS
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                maximumObservedRSS = max(maximumObservedRSS, residentBytes())
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let elapsedCPU = max(0, try cpuSeconds() - startCPU)
            model.stopMonitoring()
            try check(board.changeCount == boardChange, "performance polling mutated the named pasteboard")
            try check(model.snapshot.items.count == size, "unchanged clipboard polling mutated synthetic history")
            measurements.append([
                "name": "native_model_monitoring_unchanged_named_board", "synthetic_items": size,
                "wall_seconds": elapsed, "process_cpu_seconds": elapsedCPU,
                "one_core_cpu_percent": 100 * elapsedCPU / elapsed,
                "rss_start_bytes": startRSS, "rss_end_bytes": residentBytes(),
                "rss_max_observed_bytes": maximumObservedRSS, "rss_sample_interval_seconds": 1,
                "monitoring_interval_seconds": 0.4, "pasteboard_changes": 0
            ])
        }
        model.snapshot = syntheticSnapshot(count: 1000)
        var sink = 0
        measurements.append(measure("model_search_first_read_1000_rows", iterations: 25) {
            model.queryString = "row 999"
            sink += model.visibleItems.count
        })
        model.queryString = "row 999"
        let expected = model.visibleItems
        try check(expected.count == 1, "synthetic search did not match the expected row")
        measurements.append(measure("model_search_cached_read_1000_rows", iterations: 25, operationsPerIteration: 1000) {
            for _ in 0..<1000 { sink += model.visibleItems.count }
        })
        try check(model.visibleItems == expected, "cached repeated reads changed visible items")
        let imageResults = try await Task.detached(priority: .utility) { try imageMeasurements() }.value
        measurements.append(contentsOf: imageResults.measurements)
        try check(imageResults.fullSize == [4096, 3072], "synthetic full-resolution decoding changed dimensions")
        try check(imageResults.thumbnailSize == [384, 288], "ImageIO thumbnail dimensions were not bounded to 384 pixels")
        let output: [String: Any] = [
            "configuration": "native --self-test DEBUG build; optimization follows packaged build configuration",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "native model/clipboard polling and image processing only; no visible application UI, real clipboard, or personal history; process CPU and sampled resident memory include other native test-process work",
            "cpu_percent_definition": "100% is one CPU core; getrusage user+system CPU delta / monotonic elapsed wall time",
            "memory_definition": "task_info MACH_TASK_BASIC_INFO resident_size sampled once per second; maximum observed sample is not whole-app UI peak memory",
            "timing_method": "one warm-up then monotonic clock; image cases force CGContext bitmap draw, 10 samples; model search 25; cached reads measured in batches of 1000",
            "results": measurements, "sink": sink
        ]
        let destination = ProcessInfo.processInfo.environment["PASTE_PERFORMANCE_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-runtime-performance.json")
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        print("RUNTIME_PERFORMANCE: \(destination.path)")
        for row in measurements { print("RUNTIME_PERFORMANCE_ROW: \(row)") }
        return count
    }

    private static func syntheticSnapshot(count: Int) -> ClipboardSnapshot {
        let items = (0..<count).map {
            ClipItem(text: "Synthetic row \($0) " + String(repeating: "clipboard ", count: 50), kind: .text)
        }
        var snapshot = ClipboardSnapshot(items: items)
        snapshot.preferences.retentionDays = nil
        return snapshot
    }

    private static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw SystemChecks.Failure(message: "getrusage CPU sampling failed") }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private nonisolated static func measure(_ name: String, iterations: Int, operationsPerIteration: Int = 1, _ work: () throws -> Void) rethrows -> [String: Any] {
        try work()
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(operationsPerIteration))
        }
        samples.sort()
        return ["name": name, "iterations": iterations, "operations_per_iteration": operationsPerIteration,
                "median_ms_per_operation": samples[samples.count / 2],
                "p95_ms_per_operation": samples[Int(Double(samples.count - 1) * 0.95)]]
    }

    private struct ImageResults {
        let measurements: [[String: Any]]
        let fullSize: [Int]
        let thumbnailSize: [Int]
    }

    private nonisolated static func forceBitmapDecode(_ image: CGImage) throws {
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageProcessing.Failure.encoding }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard bitmap.data != nil else { throw ImageProcessing.Failure.encoding }
    }

    private nonisolated static func imageMeasurements() throws -> ImageResults {
        guard let context = CGContext(data: nil, width: 4096, height: 3072, bitsPerComponent: 8,
            bytesPerRow: 4096 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessing.Failure.encoding
        }
        for line in 0..<3072 {
            context.setFillColor(CGColor(red: CGFloat(line % 257) / 256, green: CGFloat(line % 127) / 126, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: line, width: 4096, height: 1))
        }
        guard let fixture = context.makeImage() else { throw ImageProcessing.Failure.encoding }
        let png = try ImageProcessing.png(fixture)
        var fullSize: [Int] = []
        var thumbnailSize: [Int] = []
        let full = try measure("image_full_decode_and_bitmap_draw_4096x3072", iterations: 10) {
            try autoreleasepool {
                let source = try ImageProcessing.source(png)
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw ImageProcessing.Failure.invalidImage
                }
                try forceBitmapDecode(image)
                fullSize = [image.width, image.height]
            }
        }
        let downsample = try measure("image_thumbnail384_generate_png_decode_and_bitmap_draw", iterations: 10) {
            try autoreleasepool {
                let thumbnail = try ImageProcessing.thumbnail(png, size: 384)
                let source = try ImageProcessing.source(thumbnail)
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw ImageProcessing.Failure.invalidImage
                }
                try forceBitmapDecode(image)
                thumbnailSize = [image.width, image.height]
            }
        }
        return ImageResults(measurements: [full.merging(["dimensions": fullSize, "theoretical_rgba_buffer_bytes": 4096 * 3072 * 4, "source_png_bytes": png.count]) { _, new in new },
            downsample.merging(["dimensions": thumbnailSize, "theoretical_rgba_buffer_bytes": 384 * 288 * 4, "source_png_bytes": png.count]) { _, new in new }], fullSize: fullSize, thumbnailSize: thumbnailSize)
    }
}
#endif
