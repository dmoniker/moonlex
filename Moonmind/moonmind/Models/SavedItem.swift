import Foundation
import SwiftData

@Model
final class SavedItem {
    /// CloudKit-backed SwiftData cannot use `@Attribute(.unique)`; treat `id` as unique in app logic.
    /// CloudKit requires non-optional attributes to have default values at the property declaration.
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

    /// Kept empty for episode favorites (legacy rows may still store non-empty values in the database).
    var excerpt: String = ""
    var note: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        episodeKey: String,
        episodeTitle: String,
        showTitle: String,
        feedID: String,
        feedURLString: String,
        audioURLString: String?,
        episodePubDate: Date?,
        linkURLString: String?,
        excerpt: String = "",
        note: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.episodeKey = episodeKey
        self.episodeTitle = episodeTitle
        self.showTitle = showTitle
        self.feedID = feedID
        self.feedURLString = feedURLString
        self.audioURLString = audioURLString
        self.episodePubDate = episodePubDate
        self.linkURLString = linkURLString
        self.excerpt = excerpt
        self.note = note
    }

    var isEpisodeFavorite: Bool { excerpt.isEmpty }

    var displayTitle: String {
        if excerpt.isEmpty { return episodeTitle }
        return excerpt.count > 120 ? String(excerpt.prefix(120)) + "…" : excerpt
    }
}
