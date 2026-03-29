import Foundation

enum RSSFeedService {
    static func loadEpisodes(for feed: PodcastFeed, limit: Int = 80) async throws -> [Episode] {
        guard let url = feed.rssURL else { throw RSSError.badURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw RSSError.badResponse
        }
        let parser = RSSParser(data: data, feed: feed, limit: limit)
        return try parser.parse()
    }
}

enum RSSError: LocalizedError {
    case badURL
    case badResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid feed URL."
        case .badResponse: return "Could not download the feed."
        case .parseFailed: return "Could not read this RSS feed."
        }
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let feed: PodcastFeed
    private let limit: Int

    private var episodes: [Episode] = []
    private var currentPath: [String] = []
    private var inItem = false

    private var titleBuf = ""
    private var linkBuf = ""
    private var guidBuf = ""
    private var pubDateBuf = ""
    private var enclosureURL: String?
    private var descriptionBuf = ""

    /// Show-level artwork (persists for all items in this feed document).
    private var channelArtworkURL: String?
    private var itemArtworkURL: String?
    private var inChannelImageBlock = false
    private var channelImageURLAccum = ""

    private var failure: Error?

    init(data: Data, feed: PodcastFeed, limit: Int) {
        self.parser = XMLParser(data: data)
        self.feed = feed
        self.limit = limit
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [Episode] {
        guard parser.parse() else {
            throw failure ?? RSSError.parseFailed
        }
        return episodes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // `XMLParser` uses local name "image" + itunes namespace for `<itunes:image href="…"/>`, not the string "itunes:image".
        if let href = attributeDict["href"] ?? attributeDict["HREF"], !href.isEmpty,
           Self.isPodcastCoverImage(elementName: elementName, namespaceURI: namespaceURI, qualifiedName: qName) {
            if inItem {
                itemArtworkURL = href
            } else if channelArtworkURL == nil {
                channelArtworkURL = href
            }
        }

        currentPath.append(elementName.lowercased())
        let leaf = currentPath.last ?? ""

        if leaf == "item" {
            inItem = true
            resetItemBuffers()
        }
        if inItem, leaf == "enclosure" {
            if let u = attributeDict["url"] ?? attributeDict["URL"] {
                enclosureURL = u
            }
        }
        if inItem, leaf == "link" {
            if let href = attributeDict["href"] ?? attributeDict["HREF"], linkBuf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                linkBuf = href
            }
        }
        if inItem, leaf == "media:thumbnail" || leaf.hasSuffix(":thumbnail"),
           itemArtworkURL == nil,
           let u = attributeDict["url"] ?? attributeDict["URL"] {
            itemArtworkURL = u
        }
        // RSS 2.0 `<image><url>…</url></image>` (not iTunes/Google cover tags)
        if !inItem, leaf == "image", !Self.isPodcastCoverImage(elementName: elementName, namespaceURI: namespaceURI, qualifiedName: qName) {
            inChannelImageBlock = true
            channelImageURLAccum = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let leaf = currentPath.last ?? ""
        if inChannelImageBlock, !inItem, leaf == "url" {
            channelImageURLAccum += string
            return
        }
        guard inItem else { return }
        switch leaf {
        case "title": titleBuf += string
        case "link": linkBuf += string
        case "guid": guidBuf += string
        case "pubdate": pubDateBuf += string
        case "description", "content:encoded", "itunes:summary":
            descriptionBuf += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let leaf = currentPath.last ?? ""
        defer {
            if !currentPath.isEmpty { currentPath.removeLast() }
        }

        if leaf == "item" {
            inItem = false
            if episodes.count < limit, let episode = makeEpisode() {
                episodes.append(episode)
            }
            resetItemBuffers()
        }
        if leaf == "image", inChannelImageBlock {
            inChannelImageBlock = false
            let trimmed = channelImageURLAccum.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, channelArtworkURL == nil {
                channelArtworkURL = trimmed
            }
            channelImageURLAccum = ""
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }

    /// iTunes (`http://www.itunes.com/dtds/podcast-1.0.dtd`) or Google Play podcast `<image href>` cover.
    private static func isPodcastCoverImage(elementName: String, namespaceURI: String?, qualifiedName qName: String?) -> Bool {
        let el = elementName.lowercased()
        if qName?.lowercased() == "itunes:image" { return true }
        if el != "image" { return false }
        guard let uri = namespaceURI, !uri.isEmpty else { return false }
        if uri == "http://www.itunes.com/dtds/podcast-1.0.dtd" { return true }
        if uri.contains("itunes.com/dtds/podcast") { return true }
        if uri.contains("google.com/schemas/play-podcasts") { return true }
        return false
    }

    private func resetItemBuffers() {
        titleBuf = ""
        linkBuf = ""
        guidBuf = ""
        pubDateBuf = ""
        enclosureURL = nil
        descriptionBuf = ""
        itemArtworkURL = nil
    }

    private func makeEpisode() -> Episode? {
        let title = titleBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let guid = guidBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = linkBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let keySource = [guid, link, title].first { !$0.isEmpty } ?? title
        let stableKey = "\(feed.id)|\(keySource)"

        let date = RSSDateParser.date(from: pubDateBuf)
        let audio = enclosureURL.flatMap { URL(string: $0) }
        let page = URL(string: link)
        let rawArt = itemArtworkURL ?? channelArtworkURL
        let trimmedArt = rawArt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = trimmedArt.isEmpty ? nil : URL(string: trimmedArt)

        return Episode(
            stableKey: stableKey,
            title: title,
            pubDate: date,
            audioURL: audio,
            showTitle: feed.title,
            feedID: feed.id,
            feedURLString: feed.rssURLString,
            linkURL: page,
            descriptionRaw: descriptionBuf.trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURL: artwork
        )
    }
}

private enum RSSDateParser {
    private static let rfc822Z: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return df
    }()

    private static let rfc822ZAlt: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return df
    }()

    static func date(from raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        if let d = rfc822Z.date(from: s) { return d }
        if let d = rfc822ZAlt.date(from: s) { return d }
        return nil
    }
}
