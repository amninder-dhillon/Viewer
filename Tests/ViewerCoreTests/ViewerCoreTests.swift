import Foundation
import Testing
@testable import ViewerCore

private func samplePhotos() -> [Photo] {
    ["01.jpg", "02.jpg", "03.jpg", "04.jpg", "05.jpg"].map { Photo(url: URL(fileURLWithPath: "/Photos/\($0)")) }
}

@Test func arrowsSkipExcludedPhotosWithoutRemovingThumbnails() {
    let photos = samplePhotos()
    let ratings = [photos[0].id: 5, photos[1].id: 1, photos[2].id: 3, photos[3].id: 2, photos[4].id: 4]
    let next = PhotoNavigation.destination(photos: photos, selectedID: photos[0].id, direction: .next, filter: .threePlus, ratings: ratings)
    #expect(next?.id == photos[2].id)
    let previous = PhotoNavigation.destination(photos: photos, selectedID: photos[4].id, direction: .previous, filter: .threePlus, ratings: ratings)
    #expect(previous?.id == photos[2].id)
    #expect(photos.count == 5)
    #expect(PhotoNavigation.destination(photos: photos, selectedID: photos[4].id, direction: .next, filter: .threePlus, ratings: ratings) == nil)
    #expect(PhotoNavigation.destination(photos: photos, selectedID: photos[0].id, direction: .previous, filter: .threePlus, ratings: ratings) == nil)
}

@Test func excludedPhotoCanBeInspectedAndArrowsResumeAtNearestMatch() {
    let photos = samplePhotos()
    let ratings = [photos[0].id: 5, photos[4].id: 4]
    #expect(PhotoNavigation.destination(photos: photos, selectedID: photos[2].id, direction: .next, filter: .fourPlus, ratings: ratings)?.id == photos[4].id)
    #expect(PhotoNavigation.destination(photos: photos, selectedID: photos[2].id, direction: .previous, filter: .fourPlus, ratings: ratings)?.id == photos[0].id)
}

@Test func ratingChangeMovesForwardThenFallsBackBackward() {
    let photos = samplePhotos()
    let ratings = [photos[0].id: 5, photos[4].id: 4]
    #expect(PhotoNavigation.reconciledSelection(photos: photos, selectedID: photos[2].id, filter: .fourPlus, ratings: ratings) == photos[4].id)
    #expect(PhotoNavigation.reconciledSelection(photos: photos, selectedID: photos[4].id, filter: .five, ratings: ratings) == photos[0].id)
    #expect(PhotoNavigation.reconciledSelection(photos: photos, selectedID: photos[0].id, filter: .five, ratings: ratings) == photos[0].id)
}

@Test func emptyMatchesAndUnratedAreHandled() {
    let photos = samplePhotos()
    #expect(PhotoNavigation.reconciledSelection(photos: photos, selectedID: photos[0].id, filter: .five, ratings: [:]) == nil)
    #expect(PhotoNavigation.destination(photos: photos, selectedID: nil, direction: .next, filter: .unrated, ratings: [:])?.id == photos[0].id)
    #expect(PhotoNavigation.destination(photos: [], selectedID: nil, direction: .next, filter: .all, ratings: [:]) == nil)
    #expect(RatingFilter.exactlyThree.includes(3))
    #expect(!RatingFilter.exactlyThree.includes(4))
    #expect(RatingFilter.threePlus.includes(4))
    #expect(RatingFilter.unrated.includes(0))
}

@Test func ratingsSurviveReloadAndClearing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var store = try RatingStore(directory: directory)
    try store.set(5, for: "/Photos/one.jpg")
    try store.set(2, for: "/Photos/two.jpg")
    #expect(try RatingStore(directory: directory).values == ["/Photos/one.jpg": 5, "/Photos/two.jpg": 2])
    try store.set(0, for: "/Photos/one.jpg")
    #expect(try RatingStore(directory: directory).values == ["/Photos/two.jpg": 2])
    try store.set(6, for: "/Photos/two.jpg")
    #expect(store.values["/Photos/two.jpg"] == 2)
}

@Test func failedRatingWriteDoesNotChangeValues() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not a directory".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var store = try RatingStore(directory: file)
    #expect(throws: (any Error).self) { try store.set(4, for: "/Photos/one.jpg") }
    #expect(store.values.isEmpty)
}

@Test func corruptRatingsAreNeverSilentlyOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ratings.json")
    let original = Data("broken data".utf8)
    try original.write(to: url)
    #expect(throws: (any Error).self) { _ = try RatingStore(directory: directory) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func recursiveScanFindsNestedImagesAndSkipsHiddenFilesAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("Trips/Alps")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["photo10.jpg", "photo2.jpg", "Trips/Alps/summit.png", ".hidden.jpg", "notes.txt"] {
        try Data().write(to: root.appendingPathComponent(path))
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jpg"), withDestinationURL: root.appendingPathComponent("photo2.jpg"))
    let result = try LibraryScanner.scan(folder: root)
    #expect(result.photos.count == 3)
    #expect(result.photos.map(\.name) == ["photo2.jpg", "photo10.jpg", "summit.png"])
    #expect(result.photos.last?.relativePath == "Trips/Alps/summit.png")
    let tree = FolderNode.tree(root: root, photos: result.photos)
    #expect(tree.count == 1)
    #expect(tree.first?.url.lastPathComponent == "Trips")
    #expect(tree.first?.count == 1)
    #expect(tree.first?.children?.first?.url.lastPathComponent == "Alps")
}

@Test func scanReportsMissingRootInsteadOfPretendingItIsEmpty() {
    #expect(throws: (any Error).self) {
        _ = try LibraryScanner.scan(folder: URL(fileURLWithPath: "/a-missing-viewer-folder-\(UUID())"))
    }
}

@Test func sortingIsNaturalAndStableAcrossIdenticalFilenames() {
    let a = Photo(url: URL(fileURLWithPath: "/Photos/A/photo2.jpg"))
    let b = Photo(url: URL(fileURLWithPath: "/Photos/B/photo2.jpg"))
    let c = Photo(url: URL(fileURLWithPath: "/Photos/A/photo10.jpg"))
    #expect(PhotoSort.filename.ordered([c, b, a]).map(\.id) == [a.id, b.id, c.id])
    #expect(PhotoSort.folder.ordered([c, b, a]).map(\.id) == [a.id, c.id, b.id])
}
