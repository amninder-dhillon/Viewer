import Foundation
import UniformTypeIdentifiers

public struct ScanResult: Sendable {
    public let photos: [Photo]
    public let unreadableLocations: [String]
}

public enum LibraryScanner {
    // Keep common formats discoverable even before Launch Services has populated its type database.
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "dib",
        "webp", "avif", "ico", "icns", "jp2", "j2k", "jxl", "psd", "exr", "hdr", "pic", "pict",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "pef", "srw"
    ]
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
    ]

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    public static func photo(at url: URL, root: URL? = nil) -> Photo? {
        guard isImage(url), let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let prefix = root.map { $0.standardizedFileURL.path == "/" ? "/" : $0.standardizedFileURL.path + "/" }
        let path = url.standardizedFileURL.path
        let relative = prefix.flatMap { path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil }
        return Photo(url: url, relativePath: relative, fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    public static func scan(folder: URL, progress: @Sendable (Int) -> Void = { _ in }) throws -> ScanResult {
        let manager = FileManager.default
        // Reading the root explicitly distinguishes an inaccessible root from an empty folder.
        _ = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var failures: [String] = []
        guard let enumerator = manager.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                if failures.count < 20 { failures.append(url.path) }
                return true
            }
        ) else { throw CocoaError(.fileReadNoPermission) }
        var photos: [Photo] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if let photo = photo(at: url, root: folder) {
                photos.append(photo)
                if photos.count.isMultiple(of: 100) { progress(photos.count) }
            }
        }
        progress(photos.count)
        return ScanResult(photos: PhotoSort.filename.ordered(photos), unreadableLocations: failures)
    }
}
