import Combine
import Foundation
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

        // Cache hits never queue behind an unrelated synchronous ImageIO decode.
        if let cached = previews.cachedImage(for: photo, maxPixelSize: ImagePipeline.previewPixelSize) {
            image = cached
            return
        }
        let cachedThumbnail = thumbnails.cachedImage(for: photo, maxPixelSize: ImagePipeline.thumbnailPixelSize)
        image = cachedThumbnail

        await withTaskGroup(of: ImageStage.self) { group in
            if cachedThumbnail == nil {
                group.addTask { [thumbnails] in
                    .thumbnail(await thumbnails.load(photo, maxPixelSize: ImagePipeline.thumbnailPixelSize))
                }
            }
            group.addTask { [previews] in
                .preview(await previews.load(photo, maxPixelSize: ImagePipeline.previewPixelSize))
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
                    if !hasSharpPreview, let thumbnail { image = thumbnail }
                case .preview(let preview):
                    previewFinished = true
                    if let preview {
                        hasSharpPreview = true
                        image = preview
                    }
                }
                // A usable thumbnail remains on screen even if the sharper decode fails.
                isPreviewOnly = previewFinished && !hasSharpPreview && image != nil
                failed = thumbnailFinished && previewFinished && image == nil
            }
        }
    }
}
