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
    /// Channel or show website from RSS (`<channel><link>`), used when an item has no page URL.
    let showLinkURL: URL?
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
            showLinkURL: showLinkURL,
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
            showLinkURL: showLinkURL,
            descriptionRaw: descriptionRaw,
            artworkURL: artworkURL,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            feedContentKind: feedContentKind
        )
    }
}

extension Episode {
    /// Human-friendly page to share (episode show notes or the podcast website — never a raw audio file).
    var shareURL: URL? {
        if let link = linkURL, Self.isShareableWebPage(link) { return link }
        if let show = showLinkURL, Self.isShareableWebPage(show) { return show }
        if let builtin = Self.builtinShowLinkURL(forFeedID: feedID), Self.isShareableWebPage(builtin) {
            return builtin
        }
        return nil
    }

    var canShare: Bool { true }

    /// Title line paired with a shared link (no URL — Messages already receives the link separately).
    var shareCaption: String {
        "\(title) — \(showTitle)"
    }

    /// Plain-text payload when there is no page URL to share.
    var shareMessage: String {
        shareCaption
    }

    private static func isShareableWebPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !isDirectAudioAsset(url)
    }

    private static func builtinShowLinkURL(forFeedID feedID: String) -> URL? {
        switch feedID {
        case PodcastFeed.moonshotsID:
            return URL(string: "https://www.diamandis.com/podcast")
        case PodcastFeed.lexID:
            return URL(string: "https://lexfridman.com/podcast")
        default:
            return nil
        }
    }

    private static func isDirectAudioAsset(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "ogg", "opus", "flac", "mp4"].contains(ext) { return true }
        let host = url.host?.lowercased() ?? ""
        return host.contains("megaphone.fm") || host.contains("blubrry.com")
    }

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
        showLinkURL = nil
        descriptionRaw = ""
        artworkURL = savedItem.artworkURLString.flatMap { URL(string: $0) }
        authorName = nil
        authorAvatarURL = nil
        feedContentKind = contentKind
    }
}
