import Foundation

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

    init() {
        podcastExclusiveFeedID = Self.loadExclusiveID(key: FeedFilterBarScope.podcast.storageKey)
        newsletterExclusiveFeedID = Self.loadExclusiveID(key: FeedFilterBarScope.newsletter.storageKey)
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
            Self.persistExclusiveID(feedID, key: scope.storageKey)
        case .newsletter:
            newsletterExclusiveFeedID = feedID
            Self.persistExclusiveID(feedID, key: scope.storageKey)
        }
    }

    func isOn(_ feedID: String, scope: FeedFilterBarScope) -> Bool {
        guard let only = exclusiveFeedID(for: scope) else { return true }
        return feedID == only
    }

    private static func loadExclusiveID(key: String) -> String? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    private static func persistExclusiveID(_ id: String?, key: String) {
        if let id {
            UserDefaults.standard.set(id, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
