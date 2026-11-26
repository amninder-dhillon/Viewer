import Foundation
import ImageIO
import CoreGraphics
import ViewerCore

struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

private final class CachedImage: NSObject {
    let value: DecodedImage
    init(_ value: DecodedImage) { self.value = value }
}

/// Independent serial decoders keep thumbnail work from delaying the main photo.
actor ImagePipeline {
    static let thumbnails = ImagePipeline(memoryLimit: 96 * 1024 * 1024)
    static let previews = ImagePipeline(memoryLimit: 192 * 1024 * 1024)
    private let cache = NSCache<NSString, CachedImage>()

    init(memoryLimit: Int) { cache.totalCostLimit = memoryLimit }

    func load(_ photo: Photo, maxPixelSize: Int) -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(photo.id)|\(photo.modifiedAt.timeIntervalSince1970)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard !Task.isCancelled, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let decoded = DecodedImage(image: image, pixelWidth: orientation >= 5 ? height : width, pixelHeight: orientation >= 5 ? width : height)
        cache.setObject(CachedImage(decoded), forKey: key, cost: image.bytesPerRow * image.height)
        return decoded
    }
}
