import Foundation

/// Ratings live outside the originals. A failed write leaves both the prior file and values intact.
public struct RatingStore {
    public private(set) var values: [String: Int]
    public let fileURL: URL

    public init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("ratings.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            values = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: fileURL))
                .filter { (1...5).contains($0.value) }
        } else { values = [:] }
    }

    public mutating func set(_ rating: Int, for photoID: String) throws {
        guard (0...5).contains(rating) else { return }
        var updated = values
        if rating == 0 { updated.removeValue(forKey: photoID) } else { updated[photoID] = rating }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        values = updated
    }
}
