import Foundation

enum FeedContentKind: String, Codable, Hashable, Sendable {
    /// Audio-first RSS (podcasts).
    case podcast
    /// Text-first publications (e.g. Substack); listen links usually open the publisher’s site.
    case newsletter
}

struct PodcastFeed: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var rssURLString: String
    var isBuiltin: Bool
    /// Shorter label for the filter chip only; full `title` is still used in the feed and episode UI.
    var chipTitle: String? = nil
    var contentKind: FeedContentKind = .podcast

    var rssURL: URL? { URL(string: rssURLString) }

    var filterChipLabel: String { chipTitle ?? title }

    static let moonshotsID = "builtin.moonshots"
    static let lexID = "builtin.lexfridman"
    static let innermostLoopID = "builtin.innermostloop"
    /// Audio RSS from Substack (`/podcast` page `rel="alternate"`); distinct from the text `/feed`.
    static let innermostLoopPodcastID = "builtin.innermostloop.podcast"

    enum CodingKeys: String, CodingKey {
        case id, title, rssURLString, isBuiltin, chipTitle, contentKind
    }

    init(
        id: String,
        title: String,
        rssURLString: String,
        isBuiltin: Bool,
        chipTitle: String? = nil,
        contentKind: FeedContentKind = .podcast
    ) {
        self.id = id
        self.title = title
        self.rssURLString = rssURLString
        self.isBuiltin = isBuiltin
        self.chipTitle = chipTitle
        self.contentKind = contentKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        rssURLString = try c.decode(String.self, forKey: .rssURLString)
        isBuiltin = try c.decode(Bool.self, forKey: .isBuiltin)
        chipTitle = try c.decodeIfPresent(String.self, forKey: .chipTitle)
        contentKind = try c.decodeIfPresent(FeedContentKind.self, forKey: .contentKind) ?? .podcast
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(rssURLString, forKey: .rssURLString)
        try c.encode(isBuiltin, forKey: .isBuiltin)
        try c.encodeIfPresent(chipTitle, forKey: .chipTitle)
        try c.encode(contentKind, forKey: .contentKind)
    }

    static var builtins: [PodcastFeed] {
        [
            PodcastFeed(
                id: moonshotsID,
                title: "Moonshots (Peter Diamandis)",
                rssURLString: "https://feeds.megaphone.fm/DVVTS2890392624",
                isBuiltin: true,
                chipTitle: "Moonshots",
                contentKind: .podcast
            ),
            PodcastFeed(
                id: lexID,
                title: "Lex Fridman Podcast",
                rssURLString: "https://lexfridman.com/feed/podcast/",
                isBuiltin: true,
                chipTitle: "Lex Fridman",
                contentKind: .podcast
            ),
            PodcastFeed(
                id: innermostLoopPodcastID,
                title: "The Innermost Loop (Podcast)",
                rssURLString: "https://api.substack.com/feed/podcast/7227615.rss",
                isBuiltin: true,
                chipTitle: "Innermost Loop",
                contentKind: .podcast
            ),
            PodcastFeed(
                id: innermostLoopID,
                title: "The Innermost Loop",
                rssURLString: "https://theinnermostloop.substack.com/feed",
                isBuiltin: true,
                chipTitle: "Innermost Loop",
                contentKind: .newsletter
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

    var podcastFeeds: [PodcastFeed] {
        allFeeds.filter { $0.contentKind == .podcast }
    }

    var newsletterFeeds: [PodcastFeed] {
        allFeeds.filter { $0.contentKind == .newsletter }
    }

    func addCustom(title: String, rssURL: URL) throws {
        guard rssURL.scheme?.hasPrefix("http") == true else {
            throw FeedCatalogError.invalidURL
        }
        let id = "custom.\(UUID().uuidString)"
        guard !customFeeds.contains(where: { $0.rssURLString == rssURL.absoluteString }) else {
            throw FeedCatalogError.duplicateFeed
        }
        let kind: FeedContentKind =
            rssURL.host?.lowercased().contains("substack.com") == true ? .newsletter : .podcast
        let feed = PodcastFeed(
            id: id,
            title: title,
            rssURLString: rssURL.absoluteString,
            isBuiltin: false,
            contentKind: kind
        )
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
