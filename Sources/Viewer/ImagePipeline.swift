import Foundation
import ImageIO
import CoreGraphics
import ViewerCore

struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

protocol ImageLoading: Sendable {
    func cachedImage(for photo: Photo, maxPixelSize: Int) -> DecodedImage?
    func load(_ photo: Photo, maxPixelSize: Int) async -> DecodedImage?
}

private final class CachedImage: NSObject {
    let value: DecodedImage
    init(_ value: DecodedImage) { self.value = value }
}

/// NSCache supports concurrent lookup and insertion. Keep that access independent of the decoder actor.
private final class ImageCache: @unchecked Sendable {
    private let storage = NSCache<NSString, CachedImage>()

    init(memoryLimit: Int) { storage.totalCostLimit = memoryLimit }
    func value(for key: String) -> DecodedImage? { storage.object(forKey: key as NSString)?.value }
    func insert(_ image: DecodedImage, for key: String) {
        storage.setObject(CachedImage(image), forKey: key as NSString, cost: image.image.bytesPerRow * image.image.height)
    }
}

/// Independent serial decoders keep thumbnail work from delaying the main photo.
actor ImagePipeline: ImageLoading {
    static let thumbnailPixelSize = 480
    static let previewPixelSize = 4000
    static let thumbnails = ImagePipeline(memoryLimit: 96 * 1024 * 1024)
    static let previews = ImagePipeline(memoryLimit: 192 * 1024 * 1024)
    private nonisolated let cache: ImageCache

    init(memoryLimit: Int) { cache = ImageCache(memoryLimit: memoryLimit) }

    private nonisolated func cacheKey(_ photo: Photo, maxPixelSize: Int) -> String {
        "\(photo.id)|\(photo.modifiedAt.timeIntervalSince1970)|\(maxPixelSize)"
    }

    nonisolated func cachedImage(for photo: Photo, maxPixelSize: Int) -> DecodedImage? {
        cache.value(for: cacheKey(photo, maxPixelSize: maxPixelSize))
    }

    func load(_ photo: Photo, maxPixelSize: Int) -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        let key = cacheKey(photo, maxPixelSize: maxPixelSize)
        if let cached = cache.value(for: key) { return cached }
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
        cache.insert(decoded, for: key)
        return decoded
    }
}
