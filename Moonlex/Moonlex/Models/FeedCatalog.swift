import Foundation

struct PodcastFeed: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var rssURLString: String
    var isBuiltin: Bool
    /// Shorter label for the filter chip only; full `title` is still used in the feed and episode UI.
    var chipTitle: String? = nil

    var rssURL: URL? { URL(string: rssURLString) }

    var filterChipLabel: String { chipTitle ?? title }

    static let moonshotsID = "builtin.moonshots"
    static let lexID = "builtin.lexfridman"

    static var builtins: [PodcastFeed] {
        [
            PodcastFeed(
                id: moonshotsID,
                title: "Moonshots (Peter Diamandis)",
                rssURLString: "https://feeds.megaphone.fm/DVVTS2890392624",
                isBuiltin: true,
                chipTitle: "Moonshots"
            ),
            PodcastFeed(
                id: lexID,
                title: "Lex Fridman Podcast",
                rssURLString: "https://lexfridman.com/feed/podcast/",
                isBuiltin: true
            ),
        ]
    }
}

@MainActor
final class FeedCatalog: ObservableObject {
    private let customFeedsKey = "moonlex.customFeedsJSON"

    @Published private(set) var customFeeds: [PodcastFeed] = []

    init() {
        loadCustom()
    }

    var allFeeds: [PodcastFeed] {
        PodcastFeed.builtins + customFeeds
    }

    func addCustom(title: String, rssURL: URL) throws {
        guard rssURL.scheme?.hasPrefix("http") == true else {
            throw FeedCatalogError.invalidURL
        }
        let id = "custom.\(UUID().uuidString)"
        guard !customFeeds.contains(where: { $0.rssURLString == rssURL.absoluteString }) else {
            throw FeedCatalogError.duplicateFeed
        }
        let feed = PodcastFeed(id: id, title: title, rssURLString: rssURL.absoluteString, isBuiltin: false)
        customFeeds.append(feed)
        persistCustom()
    }

    func removeCustom(_ feed: PodcastFeed) {
        guard !feed.isBuiltin else { return }
        customFeeds.removeAll { $0.id == feed.id }
        persistCustom()
    }

    private func loadCustom() {
        guard let data = UserDefaults.standard.data(forKey: customFeedsKey) else { return }
        if let decoded = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            customFeeds = decoded
        }
    }

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customFeeds) {
            UserDefaults.standard.set(data, forKey: customFeedsKey)
        }
    }
}

enum FeedCatalogError: LocalizedError {
    case invalidURL
    case duplicateFeed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid http(s) RSS URL."
        case .duplicateFeed: return "That feed is already in your list."
        }
    }
}
