import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a bounded upload without changing the image stored in its history card.
enum OCRImagePreparation {
    static func uploadData(_ original: Data) throws -> Data {
        let source = try ImageProcessing.source(original)
        try Task.checkCancellation()
        let supported = original.starts(with: [0x89, 0x50, 0x4e, 0x47]) || original.starts(with: [0xff, 0xd8, 0xff])
        if supported && original.count <= CloudToolsService.maximumImageBytes { return original }
        if !supported, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let png = try ImageProcessing.png(image)
            if png.count <= CloudToolsService.maximumImageBytes { return png }
        }
        for edge in [2800, 2200, 1600] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ] as CFDictionary) else { throw ImageProcessing.Failure.invalidImage }
            for quality in [0.85, 0.65, 0.45] {
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImageProcessing.Failure.encoding }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ImageProcessing.Failure.encoding }
                if output.length <= CloudToolsService.maximumImageBytes { return output as Data }
            }
        }
        throw CloudToolsError.inputTooLarge
    }
}
