import Foundation

struct Episode: Identifiable, Hashable, Sendable, Codable {
    var id: String { stableKey }

    let stableKey: String
    let title: String
    let pubDate: Date?
    let audioURL: URL?
    let showTitle: String
    let feedID: String
    let feedURLString: String
    let linkURL: URL?
    let descriptionRaw: String
    let artworkURL: URL?
    /// Post author when the feed provides it (e.g. RSS `dc:creator`); publication/feed avatar when `authorAvatarURL` is set.
    let authorName: String?
    let authorAvatarURL: URL?
    let feedContentKind: FeedContentKind

    var descriptionPlain: String {
        switch feedContentKind {
        case .podcast:
            return descriptionRaw.strippingHTML
        case .newsletter:
            return descriptionRaw.strippingHTMLNewsletter
        }
    }

    /// Normalized article URL for pairing items across feeds (e.g. Innermost Loop newsletter + podcast).
    var normalizedPostLinkKey: String? {
        guard let url = linkURL else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        c?.query = nil
        guard let normalized = c?.url else { return nil }
        return normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func < (lhs: Episode, rhs: Episode) -> Bool {
        let ld = lhs.pubDate ?? .distantPast
        let rd = rhs.pubDate ?? .distantPast
        if ld != rd { return ld < rd }
        return lhs.stableKey < rhs.stableKey
    }

    /// Same episode with a different artwork URL (e.g. after merging a companion feed).
    func replacingArtwork(with url: URL?) -> Episode {
        Episode(
            stableKey: stableKey,
            title: title,
            pubDate: pubDate,
            audioURL: audioURL,
            showTitle: showTitle,
            feedID: feedID,
            feedURLString: feedURLString,
            linkURL: linkURL,
            descriptionRaw: descriptionRaw,
            artworkURL: url,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            feedContentKind: feedContentKind
        )
    }

    /// Same episode with an updated audio URL (e.g. after resolving a redirect).
    func replacingAudioURL(with url: URL?) -> Episode {
        Episode(
            stableKey: stableKey,
            title: title,
            pubDate: pubDate,
            audioURL: url,
            showTitle: showTitle,
            feedID: feedID,
            feedURLString: feedURLString,
            linkURL: linkURL,
            descriptionRaw: descriptionRaw,
            artworkURL: artworkURL,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            feedContentKind: feedContentKind
        )
    }
}

extension Episode {
    /// Reconstructs a playable episode from a saved item when the episode isn’t currently loaded in a feed list.
    init(savedItem: SavedItem, contentKind: FeedContentKind) {
        stableKey = savedItem.episodeKey
        title = savedItem.episodeTitle
        pubDate = savedItem.episodePubDate
        audioURL = savedItem.audioURLString.flatMap { URL(string: $0) }
        showTitle = savedItem.showTitle
        feedID = savedItem.feedID
        feedURLString = savedItem.feedURLString
        linkURL = savedItem.linkURLString.flatMap { URL(string: $0) }
        descriptionRaw = ""
        artworkURL = nil
        authorName = nil
        authorAvatarURL = nil
        feedContentKind = contentKind
    }
}
