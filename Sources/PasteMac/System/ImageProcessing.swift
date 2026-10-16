import Foundation
import Vision
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// All image decoding and Vision work runs on a utility task, never the UI executor.
enum ImageProcessing {
    private static let thumbnailSlots = DispatchSemaphore(value: 2)
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumPixels = 16_000_000
    enum Failure: LocalizedError {
        case invalidImage, oversized, noSubject, encoding
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取此图片。"
            case .oversized: return "图片超过 32 MB 或 1600 万像素，请缩小后重试。"
            case .noSubject: return "未识别到可抠取的主体。"
            case .encoding: return "无法生成透明 PNG 图片。"
            }
        }
    }
    static func source(_ data: Data) throws -> CGImageSource {
        guard data.count <= maximumBytes else { throw Failure.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.invalidImage }
        guard width <= maximumPixels, height <= maximumPixels, width <= maximumPixels / height else { throw Failure.oversized }
        return source
    }
    static func thumbnail(_ data: Data, size: Int = 1200) throws -> Data {
        try Task.checkCancellation()
        while thumbnailSlots.wait(timeout: .now() + 0.05) != .success { try Task.checkCancellation() }
        defer { thumbnailSlots.signal() }
        try Task.checkCancellation()
        let source = try source(data)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(size, 1600))
        ] as CFDictionary) else { throw Failure.invalidImage }
        return try png(image)
    }
    static func removeBackground(_ data: Data) throws -> Data {
        _ = try source(data)
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(data: data, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let image = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent) else { throw Failure.encoding }
        return try png(result)
    }
    static func rotate(_ data: Data, clockwise: Bool) throws -> Data {
        let source = try source(data)
        try Task.checkCancellation()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let edge = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 1, properties?[kCGImagePropertyPixelHeight] as? Int ?? 1)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ] as CFDictionary),
              let context = CGContext(data: nil, width: image.height, height: image.width,
                                      bitsPerComponent: 8, bytesPerRow: image.height * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalidImage }
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw Failure.encoding }
        return try png(output)
    }
    static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        guard output.length <= maximumBytes else { throw Failure.oversized }
        return output as Data
    }
}
