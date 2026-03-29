import Foundation

private struct PersistedElonGuestInterviewFeed: Codable {
    let savedAt: Date
    let episodes: [Episode]
}

enum ElonGuestInterviewEpisodeCache {
    private static let fileName = "elonGuestInterviewsFeed.v1.json"

    static func load() -> [Episode] {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let url = base?.appendingPathComponent(fileName, isDirectory: false),
              let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(PersistedElonGuestInterviewFeed.self, from: data)
        else { return [] }
        return box.episodes
    }

    static func save(_ episodes: [Episode]) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName, isDirectory: false)
        guard let url else { return }
        let box = PersistedElonGuestInterviewFeed(savedAt: Date(), episodes: episodes)
        if let data = try? JSONEncoder().encode(box) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
