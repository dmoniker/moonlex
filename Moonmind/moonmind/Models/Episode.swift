import Foundation

struct Episode: Identifiable, Hashable, Sendable {
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
            descriptionRaw: descriptionRaw,
            artworkURL: url,
            feedContentKind: feedContentKind
        )
    }
}
