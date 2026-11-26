import CoreGraphics
import Foundation
import Testing
import ViewerCore
@testable import Viewer

/// Holds decoder calls open without blocking a thread, including after subscriber cancellation.
private actor DecodeGate {
    private var pending: [String: [CheckedContinuation<DecodedImage?, Never>]] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var started: [String] = []
    private(set) var peakConcurrency = 0
    private var running = 0

    private func key(_ photo: Photo, _ size: Int) -> String {
        "\(photo.id)|\(photo.modifiedAt.timeIntervalSince1970)|\(size)"
    }

    func decode(_ photo: Photo, size: Int) async -> DecodedImage? {
        let key = key(photo, size)
        running += 1
        peakConcurrency = max(peakConcurrency, running)
        started.append(photo.name)
        return await withCheckedContinuation { continuation in
            pending[key, default: []].append(continuation)
            for waiter in startWaiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        }
    }

    func waitForStart(_ photo: Photo, size: Int = 4000) async {
        let key = key(photo, size)
        if pending[key] != nil { return }
        await withCheckedContinuation { startWaiters[key, default: []].append($0) }
    }

    func finish(_ photo: Photo, size: Int = 4000, image: DecodedImage? = nil) {
        let continuations = pending.removeValue(forKey: key(photo, size)) ?? []
        running -= continuations.count
        for continuation in continuations { continuation.resume(returning: image) }
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ImageSchedulingTests {
    private func photo(_ name: String) -> Photo { Photo(url: URL(fileURLWithPath: "/Photos/\(name).jpg")) }

    private func pipeline(_ gate: DecodeGate, limit: Int = 2) -> ImagePipeline {
        ImagePipeline(memoryLimit: 1024 * 1024, concurrencyLimit: limit) { photo, size in
            await gate.decode(photo, size: size)
        }
    }

    private func image(_ width: Int = 8) -> DecodedImage {
        let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, pixelWidth: width, pixelHeight: 1)
    }

    @discardableResult
    private func waitForActivity(_ pipeline: ImagePipeline, matching predicate: @Sendable (ImagePipelineActivity) -> Bool) async -> ImagePipelineActivity {
        for _ in 0..<10_000 {
            let activity = await pipeline.activity()
            if predicate(activity) { return activity }
            await Task.yield()
        }
        Issue.record("The expected scheduler activity did not occur")
        return await pipeline.activity()
    }

    @Test func selectedPhotoStartsBesideAnObsoleteDecodeWithoutExceedingTheLimit() async {
        let gate = DecodeGate(), pipeline = pipeline(gate)
        let a = photo("a"), b = photo("b"), c = photo("c")
        let old = Task { await pipeline.load(a, maxPixelSize: 4000, priority: .selectedPhoto) }
        await gate.waitForStart(a)
        let second = Task { await pipeline.load(b, maxPixelSize: 4000, priority: .selectedPhoto) }
        await gate.waitForStart(b) // a has not finished, yet b is already decoding.
        let current = Task { await pipeline.load(c, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.running == 2 && $0.queued == 1 }
        old.cancel()
        #expect(await old.value == nil)
        let activity = await pipeline.activity()
        #expect(activity.running == 2) // Cancellation must not pretend the uninterruptible worker has stopped.
        #expect(activity.queued == 1)
        await gate.finish(b)
        _ = await second.value
        await gate.waitForStart(c)
        #expect(await gate.peakConcurrency == 2)
        await gate.finish(c)
        _ = await current.value
        await gate.finish(a)
        await waitForActivity(pipeline) { $0.running == 0 }
    }

    @Test func cancellingAnObsoleteQueuedPhotoPreventsItsDecode() async {
        let gate = DecodeGate(), pipeline = pipeline(gate, limit: 1)
        let a = photo("a"), b = photo("b"), c = photo("c")
        let active = Task { await pipeline.load(a, maxPixelSize: 4000) }
        await gate.waitForStart(a)
        let obsolete = Task { await pipeline.load(b, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.queued == 1 }
        obsolete.cancel()
        #expect(await obsolete.value == nil)
        await waitForActivity(pipeline) { $0.queued == 0 }
        let current = Task { await pipeline.load(c, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.queued == 1 }
        await gate.finish(a)
        _ = await active.value
        await gate.waitForStart(c)
        #expect(await gate.started == ["a.jpg", "c.jpg"])
        await gate.finish(c)
        _ = await current.value
    }

    @Test func latestSelectedPhotoTakesPriorityOverQueuedThumbnailsAndEarlierSelections() async {
        let gate = DecodeGate(), pipeline = pipeline(gate, limit: 1)
        let a = photo("a"), thumbnail = photo("thumbnail"), earlier = photo("earlier"), latest = photo("latest")
        let active = Task { await pipeline.load(a, maxPixelSize: 4000) }
        await gate.waitForStart(a)
        let background = Task { await pipeline.load(thumbnail, maxPixelSize: 4000) }
        await waitForActivity(pipeline) { $0.queued == 1 }
        let olderSelection = Task { await pipeline.load(earlier, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.queued == 2 }
        let newestSelection = Task { await pipeline.load(latest, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.queued == 3 }
        await gate.finish(a)
        _ = await active.value
        await gate.waitForStart(latest)
        await gate.finish(latest)
        _ = await newestSelection.value
        await gate.waitForStart(earlier)
        await gate.finish(earlier)
        _ = await olderSelection.value
        await gate.waitForStart(thumbnail)
        await gate.finish(thumbnail)
        _ = await background.value
        #expect(await gate.started == ["a.jpg", "latest.jpg", "earlier.jpg", "thumbnail.jpg"])
        #expect(await gate.peakConcurrency == 1)
    }

    @Test func duplicateRequestsShareOneDecodeAndCancelIndependently() async {
        let gate = DecodeGate(), pipeline = pipeline(gate)
        let a = photo("a")
        let first = Task { await pipeline.load(a, maxPixelSize: 4000) }
        await gate.waitForStart(a)
        let second = Task { await pipeline.load(a, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.subscribers == 2 }
        #expect(await gate.started.count == 1)
        first.cancel()
        #expect(await first.value == nil)
        #expect(await pipeline.activity().subscribers == 1)
        await gate.finish(a, image: image())
        #expect(await second.value?.image.width == 8)
        #expect(pipeline.cachedImage(for: a, maxPixelSize: 4000)?.image.width == 8)
        #expect(await pipeline.activity().running == 0)
    }

    @Test func returningToAPhotoReusesItsStillRunningDecode() async {
        let gate = DecodeGate(), pipeline = pipeline(gate)
        let a = photo("a")
        let first = Task { await pipeline.load(a, maxPixelSize: 4000) }
        await gate.waitForStart(a)
        first.cancel()
        _ = await first.value
        let idle = await pipeline.activity()
        #expect(idle.running == 1 && idle.subscribers == 0)
        let returned = Task { await pipeline.load(a, maxPixelSize: 4000, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.subscribers == 1 }
        #expect(await gate.started.count == 1)
        await gate.finish(a, image: image())
        #expect(await returned.value?.image.width == 8)
    }

    @Test func selectingAQueuedThumbnailPromotesItsSharedJob() async {
        let gate = DecodeGate(), pipeline = pipeline(gate, limit: 1)
        let a = photo("a"), b = photo("b"), c = photo("c")
        let active = Task { await pipeline.load(a, maxPixelSize: 480) }
        await gate.waitForStart(a, size: 480)
        let thumbnail = Task { await pipeline.load(b, maxPixelSize: 480) }
        await waitForActivity(pipeline) { $0.queued == 1 }
        let earlierSelection = Task { await pipeline.load(c, maxPixelSize: 480, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.queued == 2 }
        let currentSelection = Task { await pipeline.load(b, maxPixelSize: 480, priority: .selectedPhoto) }
        await waitForActivity(pipeline) { $0.subscribers == 4 }
        thumbnail.cancel() // Removing the grid's subscriber must retain the selected photo's queued request.
        #expect(await thumbnail.value == nil)
        await gate.finish(a, size: 480)
        _ = await active.value
        await gate.waitForStart(b, size: 480)
        await gate.finish(b, size: 480, image: image())
        #expect(await currentSelection.value?.image.width == 8)
        await gate.waitForStart(c, size: 480)
        await gate.finish(c, size: 480)
        _ = await earlierSelection.value
        #expect(await gate.started == ["a.jpg", "b.jpg", "c.jpg"])
    }

    @Test func requestCancelledBeforeEnqueueDoesNotStartADecoder() async {
        let gate = DecodeGate(), pipeline = pipeline(gate)
        let a = photo("a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await pipeline.load(a, maxPixelSize: 4000)
        }
        #expect(await task.value == nil)
        #expect(await gate.started.isEmpty)
        #expect(await pipeline.activity().subscribers == 0)
    }

    @Test func differentResolutionsAreNotIncorrectlyCoalesced() async {
        let gate = DecodeGate(), pipeline = pipeline(gate)
        let a = photo("a")
        let small = Task { await pipeline.load(a, maxPixelSize: 480) }
        let large = Task { await pipeline.load(a, maxPixelSize: 4000) }
        await gate.waitForStart(a, size: 480)
        await gate.waitForStart(a)
        #expect(await gate.started.count == 2)
        await gate.finish(a, size: 480, image: image(8))
        await gate.finish(a, image: image(32))
        #expect(await small.value?.image.width == 8)
        #expect(await large.value?.image.width == 32)
    }
}
