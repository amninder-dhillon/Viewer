import Foundation
import ImageIO
import CoreGraphics
import os
import ViewerCore

struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImageLoadPriority: Int, Sendable {
    case visibleThumbnail
    case selectedPhoto
}

protocol ImageLoading: Sendable {
    func cachedImage(for photo: Photo, maxPixelSize: Int) -> DecodedImage?
    func load(_ photo: Photo, maxPixelSize: Int) async -> DecodedImage?
    func load(_ photo: Photo, maxPixelSize: Int, priority: ImageLoadPriority) async -> DecodedImage?
}

extension ImageLoading {
    func load(_ photo: Photo, maxPixelSize: Int, priority: ImageLoadPriority) async -> DecodedImage? {
        await load(photo, maxPixelSize: maxPixelSize)
    }
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

struct ImagePipelineActivity: Sendable {
    let running: Int
    let queued: Int
    let subscribers: Int
}

/// Scheduling stays responsive while a bounded number of workers run synchronous ImageIO decodes.
actor ImagePipeline: ImageLoading {
    static let thumbnailPixelSize = 480
    static let previewPixelSize = 4000
    static let thumbnails = ImagePipeline(memoryLimit: 96 * 1024 * 1024)
    static let previews = ImagePipeline(memoryLimit: 192 * 1024 * 1024)
    private nonisolated let cache: ImageCache
    private let concurrencyLimit: Int
    private let decoder: @Sendable (Photo, Int) async -> DecodedImage?
    private let signposter = OSSignposter(subsystem: "dev.viewer.mac", category: "ImageDecoding")
    private var jobs: [String: Job] = [:]
    private var runningCount = 0
    private var sequence: UInt64 = 0

    private struct Subscriber {
        let continuation: CheckedContinuation<DecodedImage?, Never>
        let priority: ImageLoadPriority
        let sequence: UInt64
    }

    private struct Job {
        let id = UUID()
        let photo: Photo
        let maxPixelSize: Int
        let queueInterval: OSSignpostIntervalState
        var decodeInterval: OSSignpostIntervalState?
        var subscribers: [UUID: Subscriber]
        var isRunning = false

        var priority: ImageLoadPriority {
            subscribers.values.contains { $0.priority == .selectedPhoto } ? .selectedPhoto : .visibleThumbnail
        }

        var order: UInt64 {
            let highestPriority = priority
            let orders = subscribers.values.lazy.filter { $0.priority == highestPriority }.map(\.sequence)
            return highestPriority == .selectedPhoto ? (orders.max() ?? 0) : (orders.min() ?? 0)
        }
    }

    init(memoryLimit: Int, concurrencyLimit: Int = 2,
         decoder: @escaping @Sendable (Photo, Int) async -> DecodedImage? = { photo, size in
             autoreleasepool { ImagePipeline.decode(photo, maxPixelSize: size) }
         }) {
        precondition(concurrencyLimit > 0)
        cache = ImageCache(memoryLimit: memoryLimit)
        self.concurrencyLimit = concurrencyLimit
        self.decoder = decoder
    }

    private nonisolated func cacheKey(_ photo: Photo, maxPixelSize: Int) -> String {
        "\(photo.id)|\(photo.modifiedAt.timeIntervalSince1970)|\(maxPixelSize)"
    }

    nonisolated func cachedImage(for photo: Photo, maxPixelSize: Int) -> DecodedImage? {
        cache.value(for: cacheKey(photo, maxPixelSize: maxPixelSize))
    }

    func load(_ photo: Photo, maxPixelSize: Int) async -> DecodedImage? {
        await load(photo, maxPixelSize: maxPixelSize, priority: .visibleThumbnail)
    }

    func load(_ photo: Photo, maxPixelSize: Int, priority: ImageLoadPriority) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        let key = cacheKey(photo, maxPixelSize: maxPixelSize)
        if let cached = cache.value(for: key) {
            signposter.emitEvent("Image cache hit")
            return cached
        }
        let subscriberID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                sequence &+= 1
                let subscriber = Subscriber(continuation: continuation, priority: priority, sequence: sequence)
                if var job = jobs[key] {
                    job.subscribers[subscriberID] = subscriber
                    jobs[key] = job
                    signposter.emitEvent("Shared image request")
                } else {
                    let interval = signposter.beginInterval("Image queue", id: signposter.makeSignpostID())
                    jobs[key] = Job(photo: photo, maxPixelSize: maxPixelSize, queueInterval: interval,
                                    subscribers: [subscriberID: subscriber])
                }
                startAvailableWork()
            }
        } onCancel: {
            Task { await self.cancelSubscriber(subscriberID, key: key) }
        }
    }

    func activity() -> ImagePipelineActivity {
        ImagePipelineActivity(running: runningCount, queued: jobs.values.filter { !$0.isRunning }.count,
                              subscribers: jobs.values.reduce(0) { $0 + $1.subscribers.count })
    }

    private func cancelSubscriber(_ id: UUID, key: String) {
        guard var job = jobs[key], let subscriber = job.subscribers.removeValue(forKey: id) else { return }
        if job.subscribers.isEmpty, !job.isRunning {
            jobs.removeValue(forKey: key)
            signposter.endInterval("Image queue", job.queueInterval)
            signposter.emitEvent("Queued decode discarded")
        } else {
            // Running ImageIO calls cannot be interrupted. Retain the job so another subscriber can reuse it.
            jobs[key] = job
        }
        subscriber.continuation.resume(returning: nil)
        startAvailableWork()
    }

    private func startAvailableWork() {
        while runningCount < concurrencyLimit {
            let next = jobs.lazy.filter { !$0.value.isRunning && !$0.value.subscribers.isEmpty }.min { a, b in
                if a.value.priority != b.value.priority { return a.value.priority.rawValue > b.value.priority.rawValue }
                return a.value.priority == .selectedPhoto ? a.value.order > b.value.order : a.value.order < b.value.order
            }
            guard let (key, queued) = next else { return }
            var job = queued
            job.isRunning = true
            signposter.endInterval("Image queue", job.queueInterval)
            job.decodeInterval = signposter.beginInterval("Image decode", id: signposter.makeSignpostID())
            jobs[key] = job
            runningCount += 1
            recordWorkerCount()
            let id = job.id, photo = job.photo, size = job.maxPixelSize, decode = decoder
            Task.detached(priority: .userInitiated) {
                let image = await decode(photo, size)
                await self.finished(key: key, id: id, image: image)
            }
        }
    }

    private func finished(key: String, id: UUID, image: DecodedImage?) {
        guard let job = jobs[key], job.id == id else { return }
        jobs.removeValue(forKey: key)
        runningCount -= 1
        if let interval = job.decodeInterval {
            let bytes = image.map { $0.image.bytesPerRow * $0.image.height } ?? 0
            signposter.endInterval("Image decode", interval, "Decoded bytes: \(bytes)")
        }
        recordWorkerCount()
        if let image { cache.insert(image, for: key) }
        for subscriber in job.subscribers.values { subscriber.continuation.resume(returning: image) }
        startAvailableWork()
    }

    private func recordWorkerCount() {
        let count = runningCount
        signposter.emitEvent("Decode worker count", "Active workers: \(count)")
    }

    private nonisolated static func decode(_ photo: Photo, maxPixelSize: Int) -> DecodedImage? {
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
        return decoded
    }
}
