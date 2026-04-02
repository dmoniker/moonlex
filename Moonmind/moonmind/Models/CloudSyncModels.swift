import Foundation
import SwiftData

/// Matches the iCloud container in Signing & Capabilities (and `moonmind.entitlements`).
enum MoonmindCloudKit {
    static let containerIdentifier = "iCloud.com.darcymen.moonmind"
}

/// User defaults for SwiftData + iCloud; keys are shared between `MoonmindApp` and settings UI.
enum MoonmindSyncSettings {
    /// When false, the next launch opens the on-device store only (no CloudKit).
    static let preferICloudSyncKey = "moonmind.preferICloudSync"
    /// Written at launch: `true` when this session is **not** using CloudKit (user choice or failed open).
    static let cloudKitInactiveKey = "moonmind.swiftDataCloudKitDisabled"
}

// MARK: - Feed catalog (user-added feeds + hidden built-ins)

@Model
final class UserCustomFeed {
    var id: String = ""
    var title: String = ""
    var rssURLString: String = ""
    var chipTitle: String?
    var contentKindRaw: String = ""
    var addedAt: Date = Date.now

    init(
        id: String,
        title: String,
        rssURLString: String,
        chipTitle: String?,
        contentKindRaw: String,
        addedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.rssURLString = rssURLString
        self.chipTitle = chipTitle
        self.contentKindRaw = contentKindRaw
        self.addedAt = addedAt
    }

    func asPodcastFeed() -> PodcastFeed {
        let kind = FeedContentKind(rawValue: contentKindRaw) ?? .podcast
        return PodcastFeed(
            id: id,
            title: title,
            rssURLString: rssURLString,
            isBuiltin: false,
            chipTitle: chipTitle,
            contentKind: kind
        )
    }
}

@Model
final class HiddenBuiltinFeedRecord {
    var feedID: String = ""

    init(feedID: String) {
        self.feedID = feedID
    }
}

// MARK: - Playback progress

@Model
final class PlaybackProgressRecord {
    var episodeKey: String = ""
    /// Persisted listen position; meaningful when `isPlayed` is false.
    var positionSeconds: Double?
    var lastKnownDurationSeconds: Double?
    var isPlayed: Bool = false

    init(
        episodeKey: String,
        positionSeconds: Double? = nil,
        lastKnownDurationSeconds: Double? = nil,
        isPlayed: Bool = false
    ) {
        self.episodeKey = episodeKey
        self.positionSeconds = positionSeconds
        self.lastKnownDurationSeconds = lastKnownDurationSeconds
        self.isPlayed = isPlayed
    }
}

// MARK: - Cross-device preferences (filters, feed list UI)

@Model
final class SyncedAppPreferences {
    static let singletonID = "default"

    var id: String = ""
    var podcastExclusiveFeedID: String?
    var newsletterExclusiveFeedID: String?
    var feedShowUnplayedOnly: Bool = true
    var podcastFeedSortNewestFirst: Bool = true

    init(
        id: String,
        podcastExclusiveFeedID: String?,
        newsletterExclusiveFeedID: String?,
        feedShowUnplayedOnly: Bool,
        podcastFeedSortNewestFirst: Bool
    ) {
        self.id = id
        self.podcastExclusiveFeedID = podcastExclusiveFeedID
        self.newsletterExclusiveFeedID = newsletterExclusiveFeedID
        self.feedShowUnplayedOnly = feedShowUnplayedOnly
        self.podcastFeedSortNewestFirst = podcastFeedSortNewestFirst
    }

    static func loadOrInsert(in context: ModelContext) -> SyncedAppPreferences {
        let sid = SyncedAppPreferences.singletonID
        let fetch = FetchDescriptor<SyncedAppPreferences>(predicate: #Predicate { $0.id == sid })
        let rows = (try? context.fetch(fetch)) ?? []
        if let first = rows.first {
            if rows.count > 1 {
                for dup in rows.dropFirst() { context.delete(dup) }
                try? context.save()
            }
            return first
        }
        let migrated = migratedFromUserDefaults()
        context.insert(migrated)
        try? context.save()
        return migrated
    }

    private static func migratedFromUserDefaults() -> SyncedAppPreferences {
        let ud = UserDefaults.standard
        let podcastEx: String? = {
            guard ud.object(forKey: "moonmind.podcastFilterExclusiveFeedID") != nil else { return nil }
            return ud.string(forKey: "moonmind.podcastFilterExclusiveFeedID")
        }()
        let newsletterEx: String? = {
            guard ud.object(forKey: "moonmind.newsletterFilterExclusiveFeedID") != nil else { return nil }
            return ud.string(forKey: "moonmind.newsletterFilterExclusiveFeedID")
        }()
        let showUnplayed: Bool =
            ud.object(forKey: "moonmind.feedShowUnplayedOnly") as? Bool ?? true
        let sortNewest: Bool =
            ud.object(forKey: "moonmind.podcastFeedSortNewestFirst") as? Bool ?? true
        return SyncedAppPreferences(
            id: singletonID,
            podcastExclusiveFeedID: podcastEx,
            newsletterExclusiveFeedID: newsletterEx,
            feedShowUnplayedOnly: showUnplayed,
            podcastFeedSortNewestFirst: sortNewest
        )
    }
}
