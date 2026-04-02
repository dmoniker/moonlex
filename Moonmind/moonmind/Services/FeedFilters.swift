import Foundation
import SwiftData

enum FeedFilterBarScope: String, Sendable {
    case podcast
    case newsletter

    fileprivate var storageKey: String {
        switch self {
        case .podcast: return "moonmind.podcastFilterExclusiveFeedID"
        case .newsletter: return "moonmind.newsletterFilterExclusiveFeedID"
        }
    }
}

/// `nil` exclusive ID means **All** feeds in that scope are included (combined feed).
@MainActor
final class FeedFilters: ObservableObject {
    @Published private(set) var podcastExclusiveFeedID: String?
    @Published private(set) var newsletterExclusiveFeedID: String?

    /// Podcast home: hide played episodes when true.
    @Published private(set) var feedShowUnplayedOnly: Bool = true
    /// Podcast home episode sort direction.
    @Published private(set) var podcastFeedSortNewestFirst: Bool = true

    private var modelContext: ModelContext?
    private var prefs: SyncedAppPreferences?

    init() {
        podcastExclusiveFeedID = Self.loadExclusiveIDFromUserDefaults(key: FeedFilterBarScope.podcast.storageKey)
        newsletterExclusiveFeedID = Self.loadExclusiveIDFromUserDefaults(key: FeedFilterBarScope.newsletter.storageKey)
        let ud = UserDefaults.standard
        feedShowUnplayedOnly = ud.object(forKey: "moonmind.feedShowUnplayedOnly") as? Bool ?? true
        podcastFeedSortNewestFirst = ud.object(forKey: "moonmind.podcastFeedSortNewestFirst") as? Bool ?? true
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        let p = SyncedAppPreferences.loadOrInsert(in: modelContext)
        prefs = p
        podcastExclusiveFeedID = p.podcastExclusiveFeedID
        newsletterExclusiveFeedID = p.newsletterExclusiveFeedID
        feedShowUnplayedOnly = p.feedShowUnplayedOnly
        podcastFeedSortNewestFirst = p.podcastFeedSortNewestFirst
        Self.clearMigratedUserDefaultsKeys()
    }

    func exclusiveFeedID(for scope: FeedFilterBarScope) -> String? {
        switch scope {
        case .podcast: return podcastExclusiveFeedID
        case .newsletter: return newsletterExclusiveFeedID
        }
    }

    /// `nil` = All; otherwise only that feed is active in the given scope.
    func selectExclusive(_ feedID: String?, scope: FeedFilterBarScope) {
        switch scope {
        case .podcast:
            podcastExclusiveFeedID = feedID
            prefs?.podcastExclusiveFeedID = feedID
        case .newsletter:
            newsletterExclusiveFeedID = feedID
            prefs?.newsletterExclusiveFeedID = feedID
        }
        try? modelContext?.save()
    }

    func isOn(_ feedID: String, scope: FeedFilterBarScope) -> Bool {
        guard let only = exclusiveFeedID(for: scope) else { return true }
        return feedID == only
    }

    func setFeedShowUnplayedOnly(_ value: Bool) {
        feedShowUnplayedOnly = value
        prefs?.feedShowUnplayedOnly = value
        try? modelContext?.save()
    }

    func toggleFeedShowUnplayedOnly() {
        setFeedShowUnplayedOnly(!feedShowUnplayedOnly)
    }

    func setPodcastFeedSortNewestFirst(_ value: Bool) {
        podcastFeedSortNewestFirst = value
        prefs?.podcastFeedSortNewestFirst = value
        try? modelContext?.save()
    }

    func togglePodcastFeedSortOrder() {
        setPodcastFeedSortNewestFirst(!podcastFeedSortNewestFirst)
    }

    private static func loadExclusiveIDFromUserDefaults(key: String) -> String? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    private static func clearMigratedUserDefaultsKeys() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "moonmind.podcastFilterExclusiveFeedID")
        ud.removeObject(forKey: "moonmind.newsletterFilterExclusiveFeedID")
        ud.removeObject(forKey: "moonmind.feedShowUnplayedOnly")
        ud.removeObject(forKey: "moonmind.podcastFeedSortNewestFirst")
    }
}
