import Foundation
import SwiftData

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
    /// Virtual feed: Elon-as-guest episodes merged from several RSS sources (`elonInterviewRSSSourceFeeds`).
    static let elonGuestInterviewsFeedID = "builtin.elon.guest"
    fileprivate static let elonGuestInterviewsFeedIDLegacy = "builtin.listennotes.elon"

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

    /// RSS shows merged into the Elon interviews chip only (not listed as separate podcasts).
    static let elonInterviewRSSSourceFeeds: [PodcastFeed] = [
        PodcastFeed(
            id: "builtin.elon.source.jre",
            title: "The Joe Rogan Experience",
            rssURLString: "https://feeds.megaphone.fm/GLT1412515089",
            isBuiltin: true
        ),
        PodcastFeed(
            id: "builtin.elon.source.dwarkesh",
            title: "Dwarkesh Podcast",
            rssURLString: "https://api.substack.com/feed/podcast/69345.rss",
            isBuiltin: true
        ),
        PodcastFeed(
            id: "builtin.elon.source.allin",
            title: "All-In with Chamath, Jason, Sacks & Friedberg",
            rssURLString: "https://allinchamathjason.libsyn.com/rss",
            isBuiltin: true
        ),
        PodcastFeed(
            id: "builtin.elon.source.wtf",
            title: "WTF with Marc Maron",
            rssURLString: "https://feeds.acast.com/public/shows/wtf-with-marc-maron-podcast",
            isBuiltin: true
        ),
    ]

    /// Built-in row for curated Elon interview episodes (JRE, Dwarkesh, All-In, WTF) loaded via RSS.
    static let elonGuestInterviewsFeed = PodcastFeed(
        id: elonGuestInterviewsFeedID,
        title: "Elon as guest — JRE, Dwarkesh, All-In, WTF",
        rssURLString: elonInterviewRSSSourceFeeds[0].rssURLString,
        isBuiltin: true,
        chipTitle: "Elon",
        contentKind: .podcast
    )

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
                chipTitle: "Lex",
                contentKind: .podcast
            ),
            elonGuestInterviewsFeed,
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
    private var modelContext: ModelContext?

    @Published private(set) var customFeeds: [PodcastFeed] = []
    /// Built-in feeds the user has removed; restoring defaults clears this set.
    @Published private(set) var hiddenBuiltinFeedIDs: Set<String> = []

    init() {
        Self.migrateLegacyElonGuestFeedIDIfNeeded()
        loadCustom()
        loadHiddenBuiltins()
    }

    /// Call from the root view once `modelContext` is available so feeds sync via iCloud.
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        let customCount = (try? modelContext.fetchCount(FetchDescriptor<UserCustomFeed>())) ?? 0
        let hiddenCount = (try? modelContext.fetchCount(FetchDescriptor<HiddenBuiltinFeedRecord>())) ?? 0

        if customCount > 0 || hiddenCount > 0 {
            reloadFromSwiftData(using: modelContext)
            dedupeCatalogRows(in: modelContext)
            Self.clearCatalogUserDefaults()
            return
        }

        for feed in customFeeds {
            modelContext.insert(
                UserCustomFeed(
                    id: feed.id,
                    title: feed.title,
                    rssURLString: feed.rssURLString,
                    chipTitle: feed.chipTitle,
                    contentKindRaw: feed.contentKind.rawValue
                )
            )
        }
        for id in hiddenBuiltinFeedIDs {
            modelContext.insert(HiddenBuiltinFeedRecord(feedID: id))
        }
        try? modelContext.save()
        dedupeCatalogRows(in: modelContext)
        Self.clearCatalogUserDefaults()
    }

    /// CloudKit cannot enforce uniqueness; remove duplicate rows after sync.
    private func dedupeCatalogRows(in context: ModelContext) {
        let customs = (try? context.fetch(FetchDescriptor<UserCustomFeed>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        var seenCustom = Set<String>()
        for row in customs {
            if seenCustom.insert(row.id).inserted == false {
                context.delete(row)
            }
        }
        let hidden = (try? context.fetch(FetchDescriptor<HiddenBuiltinFeedRecord>())) ?? []
        var seenHidden = Set<String>()
        for row in hidden {
            if seenHidden.insert(row.feedID).inserted == false {
                context.delete(row)
            }
        }
        try? context.save()
        reloadFromSwiftData(using: context)
    }

    /// Replaces the pre–RSS-merge virtual feed id so settings stay consistent.
    private static func migrateLegacyElonGuestFeedIDIfNeeded() {
        let legacy = PodcastFeed.elonGuestInterviewsFeedIDLegacy
        let id = PodcastFeed.elonGuestInterviewsFeedID
        let ud = UserDefaults.standard
        for key in ["moonmind.podcastFilterExclusiveFeedID", "moonmind.newsletterFilterExclusiveFeedID"] {
            if ud.string(forKey: key) == legacy { ud.set(id, forKey: key) }
        }
        let hiddenKey = FeedCatalogLegacyKeys.hiddenBuiltins
        guard let data = ud.data(forKey: hiddenKey),
              var ids = try? JSONDecoder().decode([String].self, from: data),
              let idx = ids.firstIndex(of: legacy)
        else { return }
        ids[idx] = id
        if let next = try? JSONEncoder().encode(ids) { ud.set(next, forKey: hiddenKey) }
    }

    var allFeeds: [PodcastFeed] {
        PodcastFeed.builtins.filter { !hiddenBuiltinFeedIDs.contains($0.id) } + customFeeds
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
        guard !allFeeds.contains(where: { $0.rssURLString == rssURL.absoluteString }) else {
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
        persistCatalog()
    }

    func removeFeed(_ feed: PodcastFeed) {
        if feed.isBuiltin {
            var next = hiddenBuiltinFeedIDs
            next.insert(feed.id)
            hiddenBuiltinFeedIDs = next
            persistCatalog()
        } else {
            customFeeds.removeAll { $0.id == feed.id }
            persistCatalog()
        }
    }

    /// Clears custom feeds, un-hides every built-in feed, matching a fresh install’s catalog.
    func resetFeedsToFactoryDefaults() {
        customFeeds = []
        hiddenBuiltinFeedIDs = []
        persistCatalog()
    }

    private func loadCustom() {
        guard let data = UserDefaults.standard.data(forKey: FeedCatalogLegacyKeys.customFeeds) else { return }
        if let decoded = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            customFeeds = decoded
        }
    }

    private func loadHiddenBuiltins() {
        guard let data = UserDefaults.standard.data(forKey: FeedCatalogLegacyKeys.hiddenBuiltins),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        hiddenBuiltinFeedIDs = Set(ids)
    }

    private func reloadFromSwiftData(using context: ModelContext) {
        let customFD = FetchDescriptor<UserCustomFeed>(sortBy: [SortDescriptor(\.addedAt)])
        let hiddenFD = FetchDescriptor<HiddenBuiltinFeedRecord>()
        let customs = (try? context.fetch(customFD)) ?? []
        let hiddenRows = (try? context.fetch(hiddenFD)) ?? []
        var seen = Set<String>()
        customFeeds = []
        for row in customs where seen.insert(row.id).inserted {
            customFeeds.append(row.asPodcastFeed())
        }
        hiddenBuiltinFeedIDs = Set(hiddenRows.map(\.feedID))
    }

    private func fetchCustomFeed(id: String, in context: ModelContext) throws -> UserCustomFeed? {
        var fd = FetchDescriptor<UserCustomFeed>(predicate: #Predicate { $0.id == id })
        fd.fetchLimit = 1
        return try context.fetch(fd).first
    }

    private func persistCatalog() {
        guard let context = modelContext else {
            Self.persistCatalogToUserDefaults(customFeeds: customFeeds, hiddenBuiltinFeedIDs: hiddenBuiltinFeedIDs)
            return
        }

        let targetCustomIDs = Set(customFeeds.map(\.id))
        let targetHidden = hiddenBuiltinFeedIDs

        let existingCustom = (try? context.fetch(FetchDescriptor<UserCustomFeed>())) ?? []
        for row in existingCustom where !targetCustomIDs.contains(row.id) {
            context.delete(row)
        }
        for feed in customFeeds {
            if let row = try? fetchCustomFeed(id: feed.id, in: context) {
                row.title = feed.title
                row.rssURLString = feed.rssURLString
                row.chipTitle = feed.chipTitle
                row.contentKindRaw = feed.contentKind.rawValue
            } else {
                context.insert(
                    UserCustomFeed(
                        id: feed.id,
                        title: feed.title,
                        rssURLString: feed.rssURLString,
                        chipTitle: feed.chipTitle,
                        contentKindRaw: feed.contentKind.rawValue
                    )
                )
            }
        }

        let existingHidden = (try? context.fetch(FetchDescriptor<HiddenBuiltinFeedRecord>())) ?? []
        for row in existingHidden {
            context.delete(row)
        }
        for id in targetHidden {
            context.insert(HiddenBuiltinFeedRecord(feedID: id))
        }

        try? context.save()
    }

    private static func persistCatalogToUserDefaults(customFeeds: [PodcastFeed], hiddenBuiltinFeedIDs: Set<String>) {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(customFeeds) {
            ud.set(data, forKey: FeedCatalogLegacyKeys.customFeeds)
        }
        let sortedIDs = hiddenBuiltinFeedIDs.sorted()
        if let data = try? JSONEncoder().encode(sortedIDs) {
            ud.set(data, forKey: FeedCatalogLegacyKeys.hiddenBuiltins)
        }
    }

    private static func clearCatalogUserDefaults() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: FeedCatalogLegacyKeys.customFeeds)
        ud.removeObject(forKey: FeedCatalogLegacyKeys.hiddenBuiltins)
    }
}

private enum FeedCatalogLegacyKeys {
    static let customFeeds = "moonmind.customFeedsJSON"
    static let hiddenBuiltins = "moonmind.hiddenBuiltinFeedIDsJSON"
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
