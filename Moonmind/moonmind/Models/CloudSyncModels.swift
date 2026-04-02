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

    /// Mirrors `EpisodePlaybackController` autoplay toggles so they survive reinstall via CloudKit.
    var autoplayNextInFeed: Bool = false
    /// Raw value of `EpisodePlaybackController.AutoplayScope`.
    var autoplayScopeRaw: String = "feed"

    /// Mirrors `EpisodeDownloadStore` retention UI (UserDefaults `moonmind.download*` keys).
    var downloadStorageLimitMB: Int = 0
    var downloadRetentionModeRaw: String = "episodesPerShow"
    var downloadEpisodesPerShow: Int = 3

    init(
        id: String,
        podcastExclusiveFeedID: String?,
        newsletterExclusiveFeedID: String?,
        feedShowUnplayedOnly: Bool,
        podcastFeedSortNewestFirst: Bool,
        autoplayNextInFeed: Bool = false,
        autoplayScopeRaw: String = "feed",
        downloadStorageLimitMB: Int = 0,
        downloadRetentionModeRaw: String = "episodesPerShow",
        downloadEpisodesPerShow: Int = 3
    ) {
        self.id = id
        self.podcastExclusiveFeedID = podcastExclusiveFeedID
        self.newsletterExclusiveFeedID = newsletterExclusiveFeedID
        self.feedShowUnplayedOnly = feedShowUnplayedOnly
        self.podcastFeedSortNewestFirst = podcastFeedSortNewestFirst
        self.autoplayNextInFeed = autoplayNextInFeed
        self.autoplayScopeRaw = autoplayScopeRaw
        self.downloadStorageLimitMB = downloadStorageLimitMB
        self.downloadRetentionModeRaw = downloadRetentionModeRaw
        self.downloadEpisodesPerShow = downloadEpisodesPerShow
    }

    /// Push download retention fields into `UserDefaults` so `EpisodeDownloadStore` reads current values.
    static func applyDownloadRetentionFromSyncedPreferences(_ p: SyncedAppPreferences) {
        let ud = UserDefaults.standard
        ud.set(p.downloadStorageLimitMB, forKey: "moonmind.downloadStorageLimitMB.v1")
        ud.set(p.downloadRetentionModeRaw, forKey: "moonmind.downloadRetentionMode.v1")
        ud.set(p.downloadEpisodesPerShow, forKey: "moonmind.downloadEpisodesPerShow.v1")
    }

    /// Merges every `SyncedAppPreferences` row into one canonical object and sets `id == singletonID`.
    /// Rely on this when CloudKit imports several preference records (e.g. `id` never matched `"default"` locally).
    static func mergeDuplicatesIfNeeded(in context: ModelContext) {
        let sid = singletonID
        let all = (try? context.fetch(FetchDescriptor<SyncedAppPreferences>())) ?? []
        guard !all.isEmpty else { return }

        if all.count == 1 {
            if all[0].id != sid {
                all[0].id = sid
                try? context.save()
            }
            return
        }

        func score(_ p: SyncedAppPreferences) -> Int {
            var s = 0
            if p.id == sid { s += 32 }
            if !p.id.isEmpty { s += 4 }
            if p.podcastExclusiveFeedID != nil { s += 8 }
            if p.newsletterExclusiveFeedID != nil { s += 8 }
            if p.autoplayNextInFeed { s += 4 }
            if p.autoplayScopeRaw != "feed" { s += 2 }
            if p.feedShowUnplayedOnly == false { s += 1 }
            if p.podcastFeedSortNewestFirst == false { s += 1 }
            return s
        }

        let sorted = all.sorted { score($0) > score($1) }
        guard let canonical = sorted.first else { return }

        func merge(into winner: SyncedAppPreferences, from loser: SyncedAppPreferences) {
            if winner.podcastExclusiveFeedID == nil { winner.podcastExclusiveFeedID = loser.podcastExclusiveFeedID }
            if winner.newsletterExclusiveFeedID == nil {
                winner.newsletterExclusiveFeedID = loser.newsletterExclusiveFeedID
            }
            if loser.autoplayNextInFeed { winner.autoplayNextInFeed = true }
            if winner.autoplayScopeRaw == "feed", loser.autoplayScopeRaw != "feed" {
                winner.autoplayScopeRaw = loser.autoplayScopeRaw
            }
            if loser.feedShowUnplayedOnly == false { winner.feedShowUnplayedOnly = false }
            if loser.podcastFeedSortNewestFirst == false { winner.podcastFeedSortNewestFirst = false }
            winner.downloadStorageLimitMB = max(winner.downloadStorageLimitMB, loser.downloadStorageLimitMB)
            if winner.downloadRetentionModeRaw == "episodesPerShow", loser.downloadRetentionModeRaw == "totalStorageCap" {
                winner.downloadRetentionModeRaw = loser.downloadRetentionModeRaw
            }
            winner.downloadEpisodesPerShow = max(winner.downloadEpisodesPerShow, loser.downloadEpisodesPerShow)
        }

        for loser in sorted.dropFirst() {
            merge(into: canonical, from: loser)
            context.delete(loser)
        }
        canonical.id = sid
        try? context.save()
    }

    static func loadOrInsert(in context: ModelContext) -> SyncedAppPreferences {
        mergeDuplicatesIfNeeded(in: context)
        let sid = SyncedAppPreferences.singletonID
        let fetch = FetchDescriptor<SyncedAppPreferences>(predicate: #Predicate { $0.id == sid })
        if let row = (try? context.fetch(fetch))?.first {
            return row
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
        let autoplayNext = ud.object(forKey: "moonmind.autoplayNextInFeed") as? Bool ?? false
        let autoplayScope =
            ud.string(forKey: "moonmind.autoplayScope") ?? "feed"
        let dlMB = ud.integer(forKey: "moonmind.downloadStorageLimitMB.v1")
        let dlMode =
            ud.string(forKey: "moonmind.downloadRetentionMode.v1") ?? "episodesPerShow"
        var dlEps = ud.integer(forKey: "moonmind.downloadEpisodesPerShow.v1")
        if dlEps <= 0 { dlEps = 3 }
        return SyncedAppPreferences(
            id: singletonID,
            podcastExclusiveFeedID: podcastEx,
            newsletterExclusiveFeedID: newsletterEx,
            feedShowUnplayedOnly: showUnplayed,
            podcastFeedSortNewestFirst: sortNewest,
            autoplayNextInFeed: autoplayNext,
            autoplayScopeRaw: autoplayScope,
            downloadStorageLimitMB: dlMB,
            downloadRetentionModeRaw: dlMode,
            downloadEpisodesPerShow: dlEps
        )
    }
}
