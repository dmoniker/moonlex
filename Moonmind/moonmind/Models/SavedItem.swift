import Foundation
import SwiftData

@Model
final class SavedItem {
    /// Stable client id as `String` (same pattern as `UserCustomFeed.id`) — avoids CloudKit mirroring issues seen with `UUID` on this entity.
    @Attribute(originalName: "id")
    var favoriteId: String = ""
    var createdAt: Date = Date.now

    var episodeKey: String = ""
    var episodeTitle: String = ""
    var showTitle: String = ""
    var feedID: String = ""
    var feedURLString: String = ""

    var audioURLString: String?
    var episodePubDate: Date?
    var linkURLString: String?
    /// Artwork as shown when the favorite was saved (episode list may not still contain this item).
    var artworkURLString: String?

    /// Kept empty for episode favorites (legacy rows may still store non-empty values in the database).
    var excerpt: String = ""
    var note: String?

    init(
        favoriteId: String = UUID().uuidString,
        createdAt: Date = .now,
        episodeKey: String,
        episodeTitle: String,
        showTitle: String,
        feedID: String,
        feedURLString: String,
        audioURLString: String?,
        episodePubDate: Date?,
        linkURLString: String?,
        artworkURLString: String? = nil,
        excerpt: String = "",
        note: String? = nil
    ) {
        self.favoriteId = favoriteId
        self.createdAt = createdAt
        self.episodeKey = episodeKey
        self.episodeTitle = episodeTitle
        self.showTitle = showTitle
        self.feedID = feedID
        self.feedURLString = feedURLString
        self.audioURLString = audioURLString
        self.episodePubDate = episodePubDate
        self.linkURLString = linkURLString
        self.artworkURLString = artworkURLString
        self.excerpt = excerpt
        self.note = note
    }

    var isEpisodeFavorite: Bool { excerpt.isEmpty }

    var displayTitle: String {
        if excerpt.isEmpty { return episodeTitle }
        return excerpt.count > 120 ? String(excerpt.prefix(120)) + "…" : excerpt
    }
}

/// Schema for `default.store` from builds before `favoriteId` (`String`) replaced `id` (`UUID`).
/// Not included in the app `ModelContainer` schema — only used for one-time legacy migration.
@Model
final class LegacySavedItem {
    var id: UUID = UUID()
    var createdAt: Date = Date.now

    var episodeKey: String = ""
    var episodeTitle: String = ""
    var showTitle: String = ""
    var feedID: String = ""
    var feedURLString: String = ""

    var audioURLString: String?
    var episodePubDate: Date?
    var linkURLString: String?

    var excerpt: String = ""
    var note: String?

    init() {}
}
