import Foundation
import CoreGraphics
import ImageIO
import Vision

/// On-device image understanding for the preview popup's right column:
/// text (Vision OCR), QR codes and barcodes, simple tables rebuilt from text
/// positions, and the image's dominant colors. Nothing is uploaded.
struct ImageInsights: Equatable, Sendable {
    struct Code: Equatable, Sendable, Identifiable {
        var id: String { kind + ":" + payload }
        let payload: String
        /// “二维码” or “条形码”.
        let kind: String
        var isLink: Bool { payload.hasPrefix("http://") || payload.hasPrefix("https://") }
    }
    struct TextBox: Equatable, Sendable {
        let text: String
        /// Vision's normalized box (origin bottom-left).
        let rect: CGRect
    }
    var text: String
    var codes: [Code]
    /// Rows × columns, rectangular; nil when the text does not look like a table.
    var table: [[String]]?
    /// Up to five “#RRGGBB” values, most common first.
    var colors: [String]

    var isEmpty: Bool { text.isEmpty && codes.isEmpty && table == nil && colors.isEmpty }
    /// Tab-separated, which pastes into Numbers, Excel and Sheets as cells.
    var tableTSV: String? { table.map { $0.map { $0.joined(separator: "\t") }.joined(separator: "\n") } }
    var tableMarkdown: String? {
        guard let table, let header = table.first else { return nil }
        func line(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        return ([line(header), "|" + Array(repeating: " --- |", count: header.count).joined()] + table.dropFirst().map(line)).joined(separator: "\n")
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "无法读取这张图片。" }
    }

    static func analyze(_ data: Data) async throws -> ImageInsights {
        let work = Task.detached(priority: .userInitiated) { () throws -> ImageInsights in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw Failure.unreadable }
            try Task.checkCancellation()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let codeRequest = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([textRequest, codeRequest])
            try Task.checkCancellation()
            let boxes = (textRequest.results ?? []).compactMap { observation -> TextBox? in
                guard let string = observation.topCandidates(1).first?.string else { return nil }
                return TextBox(text: string, rect: observation.boundingBox)
            }
            var seen = Set<String>()
            let codes = (codeRequest.results ?? []).compactMap { observation -> Code? in
                guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty,
                      seen.insert(payload).inserted else { return nil }
                return Code(payload: String(payload.prefix(4096)), kind: observation.symbology == .qr || observation.symbology == .microQR ? "二维码" : "条形码")
            }
            let lines = Self.rows(from: boxes)
            return ImageInsights(text: lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n"),
                                 codes: codes, table: Self.table(from: lines), colors: Self.dominantColors(image))
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    /// Groups text boxes into reading-order lines: top to bottom, then left to right.
    /// Two boxes share a line when their vertical centers are within half a line height.
    static func rows(from boxes: [TextBox]) -> [[TextBox]] {
        let sorted = boxes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[TextBox]] = []
        for box in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.rect.midY - box.rect.midY) < max(anchor.rect.height, box.rect.height) * 0.5 {
                rows[rows.count - 1].append(box)
            } else { rows.append([box]) }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// A table is at least two lines that each split into the same number (≥ 2) of cells,
    /// with columns starting at roughly the same x. Other lines are left out of the table.
    static func table(from rows: [[TextBox]]) -> [[String]]? {
        let candidates = rows.filter { $0.count >= 2 }
        guard candidates.count >= 2 else { return nil }
        var counts: [Int: Int] = [:]
        for row in candidates { counts[row.count, default: 0] += 1 }
        guard let (columns, frequency) = counts.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }),
              frequency >= 2, Double(frequency) >= Double(candidates.count) * 0.6 else { return nil }
        let body = candidates.filter { $0.count == columns }
        // Columns must line up: each column's left edges stay within 8% of the width.
        for column in 0..<columns {
            let xs = body.map { $0[column].rect.minX }
            guard let low = xs.min(), let high = xs.max(), high - low < 0.08 else { return nil }
        }
        return body.map { $0.map(\.text) }
    }

    /// Most common colors of a small downsample, quantized so near shades merge.
    static func dominantColors(_ image: CGImage, limit: Int = 5) -> [String] {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        var rgb: [(UInt8, UInt8, UInt8)] = []
        rgb.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            rgb.append((pixels[index], pixels[index + 1], pixels[index + 2]))
        }
        return dominantColors(pixels: rgb, limit: limit)
    }

    /// Buckets pixels by 3 bits per channel, averages each bucket and keeps buckets above 3% coverage.
    static func dominantColors(pixels: [(UInt8, UInt8, UInt8)], limit: Int = 5) -> [String] {
        guard !pixels.isEmpty else { return [] }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for (r, g, b) in pixels {
            let key = (Int(r) >> 5) << 6 | (Int(g) >> 5) << 3 | Int(b) >> 5
            var value = buckets[key] ?? (0, 0, 0, 0)
            value.count += 1; value.r += Int(r); value.g += Int(g); value.b += Int(b)
            buckets[key] = value
        }
        let minimum = max(1, pixels.count * 3 / 100)
        return buckets.values.filter { $0.count >= minimum }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { String(format: "#%02X%02X%02X", $0.r / $0.count, $0.g / $0.count, $0.b / $0.count) }
    }
}

/// Results are reused while the same image stays in history, so ← → in the preview is instant.
@MainActor
enum ImageInsightsCache {
    private static var values: [String: ImageInsights] = [:]
    private static var order: [String] = []
    static func value(_ key: String) -> ImageInsights? { values[key] }
    static func store(_ value: ImageInsights, for key: String) {
        if values[key] == nil { order.append(key) }
        values[key] = value
        while order.count > 64 { values.removeValue(forKey: order.removeFirst()) }
    }
}
