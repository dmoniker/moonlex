import Foundation

private struct PersistedFeedEpisodes: Codable {
    let savedAt: Date
    /// feedID → episodes from the last successful RSS fetch.
    let episodesByFeedID: [String: [Episode]]
}

/// Disk cache so the home feed can render subscribed shows immediately on cold launch.
enum FeedEpisodeCache {
    private static let fileName = "feedEpisodesCache.v1.json"

    static func load() -> [String: [Episode]] {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(PersistedFeedEpisodes.self, from: data)
        else { return [:] }
        return box.episodesByFeedID
    }

    static func save(_ episodesByFeedID: [String: [Episode]]) {
        guard let url = cacheFileURL() else { return }
        let box = PersistedFeedEpisodes(savedAt: Date(), episodesByFeedID: episodesByFeedID)
        guard let data = try? JSONEncoder().encode(box) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func cacheFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
