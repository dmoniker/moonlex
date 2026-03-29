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

    var descriptionPlain: String {
        descriptionRaw.strippingHTML
    }

    static func < (lhs: Episode, rhs: Episode) -> Bool {
        let ld = lhs.pubDate ?? .distantPast
        let rd = rhs.pubDate ?? .distantPast
        if ld != rd { return ld < rd }
        return lhs.stableKey < rhs.stableKey
    }
}
