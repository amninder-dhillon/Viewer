import Foundation

public struct Photo: Identifiable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let relativePath: String
    public let fileSize: Int64
    public let modifiedAt: Date

    public init(url: URL, relativePath: String? = nil, fileSize: Int64 = 0, modifiedAt: Date = .distantPast) {
        self.url = url.standardizedFileURL
        self.relativePath = relativePath ?? url.lastPathComponent
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }

    public var name: String { url.lastPathComponent }
    public var folder: URL { url.deletingLastPathComponent() }
}

public enum RatingFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unrated, onePlus, twoPlus, threePlus, fourPlus, five
    case exactlyOne, exactlyTwo, exactlyThree, exactlyFour
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All ratings"
        case .unrated: "Unrated"
        case .onePlus: "1 star & up"
        case .twoPlus: "2 stars & up"
        case .threePlus: "3 stars & up"
        case .fourPlus: "4 stars & up"
        case .five: "5 stars"
        case .exactlyOne: "Exactly 1 star"
        case .exactlyTwo: "Exactly 2 stars"
        case .exactlyThree: "Exactly 3 stars"
        case .exactlyFour: "Exactly 4 stars"
        }
    }

    public func includes(_ rating: Int) -> Bool {
        switch self {
        case .all: true
        case .unrated: rating == 0
        case .onePlus: rating >= 1
        case .twoPlus: rating >= 2
        case .threePlus: rating >= 3
        case .fourPlus: rating >= 4
        case .five: rating == 5
        case .exactlyOne: rating == 1
        case .exactlyTwo: rating == 2
        case .exactlyThree: rating == 3
        case .exactlyFour: rating == 4
        }
    }
}

public enum PhotoSort: String, CaseIterable, Identifiable, Sendable {
    case filename, folder, newest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .filename: "Filename"
        case .folder: "Folder, then filename"
        case .newest: "Newest first"
        }
    }
    public func ordered(_ photos: [Photo]) -> [Photo] {
        photos.sorted { a, b in
            if self == .newest, a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            if self == .folder, a.folder.path != b.folder.path {
                return a.folder.path.localizedStandardCompare(b.folder.path) == .orderedAscending
            }
            let nameOrder = a.name.localizedStandardCompare(b.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return a.id < b.id
        }
    }
}

public enum NavigationDirection: Sendable { case previous, next }

public enum PhotoNavigation {
    /// The full ordered list remains intact. Only navigation candidates are filtered.
    public static func destination(
        photos: [Photo], selectedID: String?, direction: NavigationDirection,
        filter: RatingFilter, ratings: [String: Int]
    ) -> Photo? {
        let index = photos.firstIndex { $0.id == selectedID }
        let candidates: [Photo]
        switch direction {
        case .next: candidates = Array(photos.dropFirst(index.map { $0 + 1 } ?? 0))
        case .previous: candidates = Array(photos.prefix(index ?? photos.count).reversed())
        }
        return candidates.first { filter.includes(ratings[$0.id, default: 0]) }
    }

    public static func reconciledSelection(
        photos: [Photo], selectedID: String?, filter: RatingFilter, ratings: [String: Int]
    ) -> String? {
        if let photo = photos.first(where: { $0.id == selectedID }), filter.includes(ratings[photo.id, default: 0]) {
            return photo.id
        }
        return destination(photos: photos, selectedID: selectedID, direction: .next, filter: filter, ratings: ratings)?.id
            ?? destination(photos: photos, selectedID: selectedID, direction: .previous, filter: filter, ratings: ratings)?.id
    }
}
