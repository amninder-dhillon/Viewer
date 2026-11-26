import Foundation

public struct FolderNode: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let count: Int
    public let children: [FolderNode]?

    public static func tree(root: URL, photos: [Photo]) -> [FolderNode] {
        let rootPath = root.standardizedFileURL.path
        var counts: [String: Int] = [:]
        var childPaths: [String: Set<String>] = [:]
        for photo in photos {
            var folder = photo.folder
            while folder.path != rootPath, folder.path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
                counts[folder.path, default: 0] += 1
                let parent = folder.deletingLastPathComponent()
                childPaths[parent.path, default: []].insert(folder.path)
                guard parent != folder else { break }
                folder = parent
            }
        }
        func nodes(in parent: String) -> [FolderNode] {
            (childPaths[parent] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
                let children = nodes(in: path)
                return FolderNode(url: URL(fileURLWithPath: path), count: counts[path, default: 0], children: children.isEmpty ? nil : children)
            }
        }
        return nodes(in: rootPath)
    }
}
