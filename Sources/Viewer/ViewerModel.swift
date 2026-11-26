import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore

enum DisplayMode: String, CaseIterable { case photo, grid }

struct ViewerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct LoadedCollection: Sendable {
    let result: ScanResult
    let folders: [FolderNode]
}

@MainActor
final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()

    @Published private(set) var photos: [Photo] = []
    @Published private(set) var visiblePhotos: [Photo] = []
    @Published private(set) var folders: [FolderNode] = []
    @Published private(set) var ratings: [String: Int] = [:]
    @Published private(set) var matchingIDs: Set<String> = []
    @Published private(set) var rootFolder: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var discoveredCount = 0
    @Published var selectedID: String?
    @Published var selectedFolder: URL? { didSet { rebuildVisiblePhotos(resetSelection: true) } }
    @Published var filter: RatingFilter = .all { didSet { refreshMatches(); reconcileSelection() } }
    @Published var sort: PhotoSort = .filename { didSet { rebuildVisiblePhotos() } }
    @Published var mode: DisplayMode = .photo
    @Published var notice: String?
    @Published var alert: ViewerAlert?
    @Published var hasOpenedCollection = false

    private var ratingStore: RatingStore?
    private var scanTask: Task<LoadedCollection, Error>?
    private var generation = UUID()
    private var photosByID: [String: Photo] = [:]

    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let store = try RatingStore(directory: support.appendingPathComponent("Viewer", isDirectory: true))
            ratingStore = store
            ratings = store.values
        } catch {
            notice = "Saved ratings could not be loaded. The existing ratings file has been left unchanged. \(error.localizedDescription)"
        }
    }

    var selectedPhoto: Photo? { selectedID.flatMap { photosByID[$0] } }
    var collectionTitle: String { rootFolder?.lastPathComponent ?? (photos.count == 1 ? photos[0].name : "Images") }
    var selectedRating: Int { selectedID.map { ratings[$0, default: 0] } ?? 0 }
    var matchingPosition: Int? {
        guard let selectedID, matchingIDs.contains(selectedID) else { return nil }
        return visiblePhotos.filter { matchingIDs.contains($0.id) }.firstIndex { $0.id == selectedID }.map { $0 + 1 }
    }

    func rating(for photo: Photo) -> Int { ratings[photo.id, default: 0] }

    func openImagePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open images"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a folder"
        panel.message = "Viewer includes images in this folder and all of its subfolders."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFolder(url)
        }
    }

    func open(_ urls: [URL]) {
        let local = urls.filter(\.isFileURL)
        guard !local.isEmpty else { return }
        if let folder = local.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            openFolder(folder)
            return
        }
        generation = UUID()
        scanTask?.cancel()
        isLoading = false
        let unique = Array(Set(local.map(\.standardizedFileURL)))
        let images = unique.compactMap { LibraryScanner.photo(at: $0) }
        guard !images.isEmpty else {
            alert = ViewerAlert(title: "No supported images", message: "Choose a readable image file or a folder containing images.")
            return
        }
        apply(images, root: nil, folders: [])
        // Explicitly opened files remain immediately visible even if a previous collection had a filter.
        filter = .all
        selectedID = local.first.flatMap { url in images.first { $0.url == url.standardizedFileURL }?.id } ?? visiblePhotos.first?.id
        mode = .photo
    }

    func openFolder(_ url: URL) {
        scanTask?.cancel()
        let token = UUID()
        generation = token
        isLoading = true
        discoveredCount = 0
        notice = nil
        let model = self
        let task = Task.detached(priority: .userInitiated) {
            let result = try LibraryScanner.scan(folder: url) { count in
                Task { @MainActor in
                    guard model.generation == token else { return }
                    model.discoveredCount = count
                }
            }
            try Task.checkCancellation()
            return LoadedCollection(result: result, folders: FolderNode.tree(root: url, photos: result.photos))
        }
        scanTask = task
        Task {
            do {
                let loaded = try await task.value
                guard generation == token else { return }
                apply(loaded.result.photos, root: url, folders: loaded.folders)
                if !loaded.result.unreadableLocations.isEmpty {
                    notice = "Some locations could not be read: " + loaded.result.unreadableLocations.joined(separator: ", ")
                }
                isLoading = false
                scanTask = nil
            } catch is CancellationError {
                guard generation == token else { return }
                isLoading = false
            } catch {
                guard generation == token else { return }
                isLoading = false
                scanTask = nil
                alert = ViewerAlert(title: "Could not open folder", message: error.localizedDescription)
            }
        }
    }

    func cancelLoading() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        isLoading = false
    }

    private func apply(_ images: [Photo], root: URL?, folders: [FolderNode]) {
        photosByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        photos = images
        rootFolder = root
        self.folders = folders
        selectedFolder = nil
        hasOpenedCollection = true
        notice = nil
        rebuildVisiblePhotos(resetSelection: true)
    }

    private func rebuildVisiblePhotos(resetSelection: Bool = false) {
        var scoped = photos
        if let selectedFolder {
            let prefix = selectedFolder.standardizedFileURL.path + "/"
            scoped = scoped.filter { $0.id.hasPrefix(prefix) }
        }
        visiblePhotos = sort.ordered(scoped)
        refreshMatches()
        if resetSelection { selectedID = nil }
        reconcileSelection()
    }

    private func refreshMatches() {
        matchingIDs = Set(visiblePhotos.filter { filter.includes(ratings[$0.id, default: 0]) }.map(\.id))
    }

    private func reconcileSelection() {
        selectedID = PhotoNavigation.reconciledSelection(photos: visiblePhotos, selectedID: selectedID, filter: filter, ratings: ratings)
    }

    func destination(_ direction: NavigationDirection) -> Photo? {
        PhotoNavigation.destination(photos: visiblePhotos, selectedID: selectedID, direction: direction, filter: filter, ratings: ratings)
    }

    func navigate(_ direction: NavigationDirection) {
        if let photo = destination(direction) { selectedID = photo.id }
    }

    func select(_ photo: Photo, open: Bool = false) {
        selectedID = photo.id
        if open { mode = .photo }
    }

    func setRating(_ rating: Int) {
        guard let selectedID, (0...5).contains(rating) else { return }
        guard var store = ratingStore else {
            alert = ViewerAlert(title: "Ratings are unavailable", message: "Viewer could not load its ratings file. Your existing ratings have been preserved. Check ~/Library/Application Support/Viewer/ratings.json and reopen Viewer.")
            return
        }
        do {
            try store.set(rating, for: selectedID)
            ratingStore = store
            ratings = store.values
            refreshMatches()
            reconcileSelection()
        } catch {
            alert = ViewerAlert(title: "Could not save rating", message: "The rating was not changed. \(error.localizedDescription)")
        }
    }
}
