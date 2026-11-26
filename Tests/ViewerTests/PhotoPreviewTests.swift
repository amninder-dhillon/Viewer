import Combine
import CoreGraphics
import Foundation
import ImageIO
import Testing
import ViewerCore
@testable import Viewer

/// Deliberately ignores cancellation to model an ImageIO decode already in progress.
private actor ControlledPipeline: ImageLoading {
    nonisolated let cached: [String: DecodedImage]
    private var pending: [String: CheckedContinuation<DecodedImage?, Never>] = [:]
    private var requestWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var loadCount = 0

    init(cached: [String: DecodedImage] = [:]) { self.cached = cached }

    nonisolated func cachedImage(for photo: Photo, maxPixelSize: Int) -> DecodedImage? { cached[photo.id] }

    func load(_ photo: Photo, maxPixelSize: Int) async -> DecodedImage? {
        loadCount += 1
        return await withCheckedContinuation { continuation in
            pending[photo.id] = continuation
            requestWaiters.removeValue(forKey: photo.id)?.resume()
        }
    }

    func waitForRequest(_ photo: Photo) async {
        if pending[photo.id] != nil { return }
        await withCheckedContinuation { requestWaiters[photo.id] = $0 }
    }

    func finish(_ photo: Photo, with image: DecodedImage?) {
        pending.removeValue(forKey: photo.id)?.resume(returning: image)
    }
}

private func fixtureImage(width: Int) -> DecodedImage {
    let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: 1))
    return DecodedImage(image: context.makeImage()!, pixelWidth: 6000, pixelHeight: 4000)
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct PhotoPreviewTests {
    private let photo = Photo(url: URL(fileURLWithPath: "/Photos/large.jpg"))

    private func waitForImage(_ loader: PhotoPreviewLoader) async {
        let (stream, continuation) = AsyncStream<DecodedImage>.makeStream()
        let subscription = loader.$image.compactMap { $0 }.sink { continuation.yield($0) }
        for await _ in stream { break }
        subscription.cancel()
        continuation.finish()
    }

    @Test func cachedThumbnailAppearsWhileSharpPreviewIsStillPending() async {
        let thumbnail = fixtureImage(width: 8)
        let sharp = fixtureImage(width: 32)
        let thumbnails = ControlledPipeline(cached: [photo.id: thumbnail])
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await previews.waitForRequest(photo)
        #expect(loader.image?.image.width == 8)
        #expect(await thumbnails.loadCount == 0)
        await previews.finish(photo, with: sharp)
        await task.value
        #expect(loader.image?.image.width == 32)
        #expect(!loader.failed)
    }

    @Test func coldThumbnailAppearsBeforeTheSharpPreviewCompletes() async {
        let thumbnails = ControlledPipeline()
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await thumbnails.waitForRequest(photo)
        await previews.waitForRequest(photo)
        await thumbnails.finish(photo, with: fixtureImage(width: 8))
        await waitForImage(loader)
        #expect(loader.image?.image.width == 8)
        await previews.finish(photo, with: fixtureImage(width: 32))
        await task.value
        #expect(loader.image?.image.width == 32)
    }

    @Test func lateThumbnailCannotDowngradeAnAlreadySharpPreview() async {
        let thumbnails = ControlledPipeline()
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await thumbnails.waitForRequest(photo)
        await previews.waitForRequest(photo)
        await previews.finish(photo, with: fixtureImage(width: 32))
        await waitForImage(loader)
        #expect(loader.image?.image.width == 32)
        await thumbnails.finish(photo, with: fixtureImage(width: 8))
        await task.value
        #expect(loader.image?.image.width == 32)
    }

    @Test func cachedSharpPreviewSkipsBothDecoders() async {
        let thumbnails = ControlledPipeline(cached: [photo.id: fixtureImage(width: 8)])
        let previews = ControlledPipeline(cached: [photo.id: fixtureImage(width: 32)])
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        await loader.load(photo)
        #expect(loader.image?.image.width == 32)
        #expect(await previews.loadCount == 0)
        #expect(await thumbnails.loadCount == 0)
    }

    @Test func usableThumbnailSurvivesFailedSharpDecode() async {
        let thumbnails = ControlledPipeline(cached: [photo.id: fixtureImage(width: 8)])
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await previews.waitForRequest(photo)
        await previews.finish(photo, with: nil)
        await task.value
        #expect(loader.image?.image.width == 8)
        #expect(loader.isPreviewOnly)
        #expect(!loader.failed)
    }

    @Test func bothDecodeFailuresProduceAnErrorState() async {
        let thumbnails = ControlledPipeline()
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await thumbnails.waitForRequest(photo)
        await previews.waitForRequest(photo)
        await previews.finish(photo, with: nil)
        await thumbnails.finish(photo, with: nil)
        await task.value
        #expect(loader.image == nil)
        #expect(loader.failed)
        #expect(!loader.isPreviewOnly)
    }

    @Test func rapidNavigationRejectsResultsFromThePreviousPhoto() async {
        let next = Photo(url: URL(fileURLWithPath: "/Photos/next.jpg"))
        let thumbnails = ControlledPipeline()
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let oldTask = Task { await loader.load(photo) }
        await thumbnails.waitForRequest(photo)
        await previews.waitForRequest(photo)
        oldTask.cancel()
        let newTask = Task { await loader.load(next) }
        await thumbnails.waitForRequest(next)
        await previews.waitForRequest(next)
        await thumbnails.finish(next, with: fixtureImage(width: 9))
        await previews.finish(next, with: fixtureImage(width: 33))
        await newTask.value
        await thumbnails.finish(photo, with: fixtureImage(width: 8))
        await previews.finish(photo, with: fixtureImage(width: 32))
        await oldTask.value
        #expect(loader.photo == next)
        #expect(loader.image?.image.width == 33)
        #expect(!loader.failed)
    }

    @Test func clearingSelectionRejectsAnUnfinishedDecode() async {
        let thumbnails = ControlledPipeline(cached: [photo.id: fixtureImage(width: 8)])
        let previews = ControlledPipeline()
        let loader = PhotoPreviewLoader(thumbnails: thumbnails, previews: previews)
        let task = Task { await loader.load(photo) }
        await previews.waitForRequest(photo)
        await loader.load(nil)
        await previews.finish(photo, with: fixtureImage(width: 32))
        await task.value
        #expect(loader.photo == nil)
        #expect(loader.image == nil)
        #expect(!loader.failed)
    }

    @Test func decodedThumbnailIsReusableAndModifiedFilesMissTheCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, fixtureImage(width: 32).image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = Photo(url: url, modifiedAt: Date(timeIntervalSince1970: 100))
        let pipeline = ImagePipeline(memoryLimit: 1024 * 1024)
        let decoded = await pipeline.load(original, maxPixelSize: ImagePipeline.thumbnailPixelSize)
        #expect(decoded?.image.width == 32)
        #expect(pipeline.cachedImage(for: original, maxPixelSize: ImagePipeline.thumbnailPixelSize)?.image.width == 32)
        let changed = Photo(url: url, modifiedAt: Date(timeIntervalSince1970: 101))
        #expect(pipeline.cachedImage(for: changed, maxPixelSize: ImagePipeline.thumbnailPixelSize) == nil)
    }
}
