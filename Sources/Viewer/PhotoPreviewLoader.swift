import Combine
import Foundation
import os
import ViewerCore

private enum ImageStage: Sendable {
    case thumbnail(DecodedImage?)
    case preview(DecodedImage?)
}

@MainActor
final class PhotoPreviewLoader: ObservableObject {
    @Published private(set) var photo: Photo?
    @Published private(set) var image: DecodedImage?
    @Published private(set) var failed = false
    @Published private(set) var isPreviewOnly = false

    private let thumbnails: any ImageLoading
    private let previews: any ImageLoading
    private let signposter = OSSignposter(subsystem: "dev.viewer.mac", category: "PhotoPreview")
    private var requestID = UUID()

    init(thumbnails: any ImageLoading = ImagePipeline.thumbnails, previews: any ImageLoading = ImagePipeline.previews) {
        self.thumbnails = thumbnails
        self.previews = previews
    }

    func load(_ photo: Photo?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        self.photo = photo
        image = nil
        failed = false
        isPreviewOnly = false
        guard let photo else { return }
        let timingID = signposter.makeSignpostID()
        var sharpeningInterval: OSSignpostIntervalState? = signposter.beginInterval("Photo sharpening", id: timingID)
        defer {
            if let interval = sharpeningInterval {
                signposter.endInterval("Photo sharpening", interval, "Ended without a sharp preview")
            }
        }

        // Cache hits never queue behind an unrelated synchronous ImageIO decode.
        if let cached = previews.cachedImage(for: photo, maxPixelSize: ImagePipeline.previewPixelSize) {
            image = cached
            signposter.emitEvent("First image published", id: timingID)
            if let interval = sharpeningInterval { signposter.endInterval("Photo sharpening", interval, "Cache hit") }
            sharpeningInterval = nil
            return
        }
        let cachedThumbnail = thumbnails.cachedImage(for: photo, maxPixelSize: ImagePipeline.thumbnailPixelSize)
        image = cachedThumbnail
        if cachedThumbnail != nil { signposter.emitEvent("First image published", id: timingID) }

        await withTaskGroup(of: ImageStage.self) { group in
            if cachedThumbnail == nil {
                group.addTask { [thumbnails] in
                    .thumbnail(await thumbnails.load(photo, maxPixelSize: ImagePipeline.thumbnailPixelSize, priority: .selectedPhoto))
                }
            }
            group.addTask { [previews] in
                .preview(await previews.load(photo, maxPixelSize: ImagePipeline.previewPixelSize, priority: .selectedPhoto))
            }

            var thumbnailFinished = cachedThumbnail != nil
            var previewFinished = false
            var hasSharpPreview = false
            for await stage in group {
                guard !Task.isCancelled, requestID == request else {
                    group.cancelAll()
                    continue
                }
                switch stage {
                case .thumbnail(let thumbnail):
                    thumbnailFinished = true
                    if !hasSharpPreview, let thumbnail {
                        if image == nil { signposter.emitEvent("First image published", id: timingID) }
                        image = thumbnail
                    }
                case .preview(let preview):
                    previewFinished = true
                    if let preview {
                        hasSharpPreview = true
                        if image == nil { signposter.emitEvent("First image published", id: timingID) }
                        image = preview
                        if let interval = sharpeningInterval {
                            signposter.endInterval("Photo sharpening", interval, "Sharp preview published")
                            sharpeningInterval = nil
                        }
                    }
                }
                // A usable thumbnail remains on screen even if the sharper decode fails.
                isPreviewOnly = previewFinished && !hasSharpPreview && image != nil
                failed = thumbnailFinished && previewFinished && image == nil
            }
        }
    }
}
