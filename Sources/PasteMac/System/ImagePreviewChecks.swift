#if DEBUG
import AppKit
import PasteCore
import ImageIO

@MainActor
enum ImagePreviewChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; count += 1
        }
        try check(LinkPreviewService.allowedURL("https://example.com/a")?.scheme == "https", "HTTPS link rejected")
        for value in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,a", "https://user:secret@example.com", "https://"] {
            try check(LinkPreviewService.allowedURL(value) == nil, "unsafe link accepted")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-image-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("Quick Look test".utf8).write(to: file)
        try check(QuickLookController.existingFiles([file, file, root.appendingPathComponent("missing"), URL(string: "https://example.com")!]) == [file], "Quick Look file validation failed")
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "test context failed") }
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { throw Failure(message: "test image failed") }
        let png = try ImageProcessing.png(image)
        let thumbnail = try await Task.detached { try ImageProcessing.thumbnail(png, size: 16) }.value
        let source = try ImageProcessing.source(thumbnail)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try check((properties?[kCGImagePropertyPixelWidth] as? Int) == 16, "thumbnail exceeded bound")
        do { _ = try ImageProcessing.source(Data("not an image".utf8)); throw Failure(message: "malformed image accepted") }
        catch is ImageProcessing.Failure { count += 1 }
        do { _ = try ImageProcessing.source(Data(count: ImageProcessing.maximumBytes + 1)); throw Failure(message: "oversized image accepted") }
        catch is ImageProcessing.Failure { count += 1 }
        let model = AppModel(isDemo: true, storageDirectory: root)
        let original = ClipItem(text: "", kind: .image, representations: [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: png)])
        var edited = original
        edited.originalRepresentations = original.representations
        edited.representations = [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: thumbnail)]
        model.snapshot.items = [edited]
        model.snapshot.pinboards = [.init(name: "test", itemIDs: [edited.id])]
        model.restoreImageBackground(edited)
        try check(model.snapshot.items.first?.representations == original.representations && model.snapshot.items.first?.originalRepresentations == nil, "restore lost original image")
        try check(model.snapshot.pinboards.first?.itemIDs == [original.id], "restore lost pinboard membership")
        model.undo()
        try check(model.snapshot.items.first == edited, "restore undo lost processed image")
        let roundTrip = try JSONDecoder().decode(ClipItem.self, from: JSONEncoder().encode(edited))
        try check(roundTrip.originalRepresentations == original.representations, "original image not persisted")
        count += try await runtimeEvidence()
        return count
    }

    /// Exercises Apple's real providers using generated pixels and an optional loopback fixture.
    private static func runtimeEvidence() async throws -> Int {
        var count = 0
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "Vision fixture context failed")
        }
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        guard let image = context.makeImage() else { throw Failure(message: "Vision fixture image failed") }
        let data = try ImageProcessing.png(image)
        let started = Date()
        do {
            let result = try await Task.detached(priority: .utility) { try ImageProcessing.removeBackground(data) }.value
            let source = try ImageProcessing.source(result)
            guard CGImageSourceGetCount(source) == 1 else { throw Failure(message: "Vision output was not a valid image") }
            print("Vision runtime: valid PNG result for generated fixture, \(result.count) bytes, \(Date().timeIntervalSince(started)) s")
            count += 1
        } catch ImageProcessing.Failure.noSubject {
            print("Vision runtime: correctly found no subject in a uniform 512 × 512 image, \(Date().timeIntervalSince(started)) s")
            count += 1
        } catch let error as Failure { throw error }
        catch {
            // A missing platform model/service is evidence of a limitation, never a passing segmentation test.
            print("Vision runtime unavailable (not counted as passed): \(String(reflecting: error))")
        }
        if let address = ProcessInfo.processInfo.environment["PASTE_PREVIEW_TEST_URL"] {
            guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1" else {
                throw Failure(message: "Link runtime fixture must be HTTP loopback")
            }
            let service = LinkPreviewService()
            service.load(address)
            let deadline = Date().addingTimeInterval(12)
            while service.loading && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let preview = service.preview, preview.title == "Pasteboard Local Preview Fixture" else {
                service.cancel()
                throw Failure(message: "Actual LPMetadataProvider fixture failed: \(service.errorMessage ?? "timeout or unexpected title")")
            }
            print("LPMetadataProvider runtime: fetched correct title from loopback HTML fixture")
            count += 1
            service.load(address)
            guard service.preview?.title == preview.title && !service.loading else { throw Failure(message: "Link provider cache failed") }
            count += 1
            service.reset()
            guard service.preview == nil && !service.loading else { throw Failure(message: "Link provider reset failed") }
            count += 1
        } else { print("LPMetadataProvider runtime: skipped; set PASTE_PREVIEW_TEST_URL to the loopback fixture") }
        return count
    }

}
#endif
