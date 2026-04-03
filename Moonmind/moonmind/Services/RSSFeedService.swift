import Foundation

enum RSSFeedService {
    /// Default cap for routine refreshes (newest episodes only).
    static let defaultEpisodeFetchLimit = 80
    /// Upper bound when scanning years of history (host may return fewer items than this).
    static let deepHistoryMaxItems = 2_000

    struct FetchOptions: Sendable {
        var maxItems: Int
        /// When set, assumes the feed lists **newest first**; stops once an episode publishes before this instant.
        var notBefore: Date?

        static let standard = FetchOptions(maxItems: RSSFeedService.defaultEpisodeFetchLimit, notBefore: nil)

        /// ~5 years of episodes, capped at `deepHistoryMaxItems` (feeds often truncate earlier).
        static func rollingFiveYears(now: Date = Date(), calendar: Calendar = .current) -> FetchOptions {
            let start = calendar.date(byAdding: .year, value: -5, to: now) ?? .distantPast
            return FetchOptions(maxItems: RSSFeedService.deepHistoryMaxItems, notBefore: start)
        }
    }

    static func loadEpisodes(for feed: PodcastFeed, options: FetchOptions = .standard) async throws -> [Episode] {
        guard let url = feed.rssURL else { throw RSSError.badURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw RSSError.badResponse
        }
        let parser = RSSParser(data: data, feed: feed, options: options)
        return try parser.parse()
    }

    /// Backward-compatible convenience.
    static func loadEpisodes(for feed: PodcastFeed, limit: Int) async throws -> [Episode] {
        try await loadEpisodes(for: feed, options: FetchOptions(maxItems: limit, notBefore: nil))
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
    private let options: RSSFeedService.FetchOptions

    private var episodes: [Episode] = []
    private var abortedForHistoryBoundary = false
    private var currentPath: [String] = []
    private var inItem = false

    private var titleBuf = ""
    private var linkBuf = ""
    private var guidBuf = ""
    private var pubDateBuf = ""
    private var enclosureURL: String?
    private var enclosureTypeLower: String?
    /// RSS `<description>` (HTML blurb). Kept separate so we don’t concatenate with `content:encoded` / `itunes:summary` (feeds often duplicate the same text in all three).
    private var itemDescriptionFieldBuf = ""
    private var itemContentEncodedBuf = ""
    private var itemItunesSummaryBuf = ""
    private var itemDcCreatorBuf = ""
    private var itemItunesAuthorBuf = ""

    /// Channel `<itunes:author>` (fallback when an item has no creator).
    private var channelItunesAuthorBuf = ""

    /// Show-level artwork (persists for all items in this feed document).
    private var channelArtworkURL: String?
    private var itemArtworkURL: String?
    private var inChannelImageBlock = false
    private var channelImageURLAccum = ""

    private var failure: Error?

    init(data: Data, feed: PodcastFeed, options: RSSFeedService.FetchOptions) {
        self.parser = XMLParser(data: data)
        self.feed = feed
        self.options = options
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [Episode] {
        _ = parser.parse()
        if abortedForHistoryBoundary || failure == nil {
            return episodes
        }
        throw failure ?? RSSError.parseFailed
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
            if let t = attributeDict["type"] ?? attributeDict["TYPE"] {
                enclosureTypeLower = t.lowercased()
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
        if !inItem {
            if leaf == "itunes:author" {
                channelItunesAuthorBuf += string
            }
            return
        }
        switch leaf {
        case "title": titleBuf += string
        case "link": linkBuf += string
        case "guid": guidBuf += string
        case "pubdate": pubDateBuf += string
        case "description":
            itemDescriptionFieldBuf += string
        case "content:encoded":
            itemContentEncodedBuf += string
        case "itunes:summary":
            itemItunesSummaryBuf += string
        case "dc:creator":
            itemDcCreatorBuf += string
        case "itunes:author":
            itemItunesAuthorBuf += string
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
            if episodes.count < options.maxItems, let episode = makeEpisode() {
                if let cutoff = options.notBefore, let pub = episode.pubDate, pub < cutoff {
                    abortedForHistoryBoundary = true
                    parser.abortParsing()
                } else {
                    episodes.append(episode)
                }
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
        if abortedForHistoryBoundary { return }
        failure = parseError
    }

    /// iTunes (`http://www.itunes.com/dtds/podcast-1.0.dtd`) or Google Play podcast `<image href>` cover.
    private static func isPodcastCoverImage(elementName: String, namespaceURI: String?, qualifiedName qName: String?) -> Bool {
        let el = elementName.lowercased()
        let q = qName?.lowercased()
        // Default XMLParser does not process namespaces; `elementName` is often the prefixed `"itunes:image"`.
        if q == "itunes:image" || el == "itunes:image" { return true }
        if q == "googleplay:image" || el == "googleplay:image" { return true }
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
        enclosureTypeLower = nil
        itemDescriptionFieldBuf = ""
        itemContentEncodedBuf = ""
        itemItunesSummaryBuf = ""
        itemDcCreatorBuf = ""
        itemItunesAuthorBuf = ""
        itemArtworkURL = nil
    }

    /// Prefer full show notes / article body, then short description, then iTunes summary — never merge (duplicate triplets are common).
    private var chosenItemDescriptionRaw: String {
        let encoded = itemContentEncodedBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = itemDescriptionFieldBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = itemItunesSummaryBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !encoded.isEmpty { return encoded }
        if !description.isEmpty { return description }
        return summary
    }

    private func makeEpisode() -> Episode? {
        let title = titleBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let guid = guidBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = linkBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let keySource = [guid, link, title].first { !$0.isEmpty } ?? title
        let stableKey = "\(feed.id)|\(keySource)"

        let date = RSSDateParser.date(from: pubDateBuf)
        let (audioString, artFromEnclosure) = Self.classifyEnclosure(url: enclosureURL, typeLower: enclosureTypeLower)
        let audio = audioString.flatMap { URL(string: $0) }
        let page = URL(string: link)
        let rawArt = itemArtworkURL ?? artFromEnclosure ?? channelArtworkURL
        let trimmedArt = rawArt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = trimmedArt.isEmpty ? nil : URL(string: trimmedArt)

        let fromCreator = itemDcCreatorBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromItemAuthor = itemItunesAuthorBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromChannelAuthor = channelItunesAuthorBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorName: String? = {
            if !fromCreator.isEmpty { return fromCreator }
            if !fromItemAuthor.isEmpty { return fromItemAuthor }
            if !fromChannelAuthor.isEmpty { return fromChannelAuthor }
            return nil
        }()

        let authorAvatarURL: URL? = {
            guard feed.contentKind == .newsletter else { return nil }
            let ch = channelArtworkURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ch.isEmpty ? nil : URL(string: ch)
        }()

        return Episode(
            stableKey: stableKey,
            title: title,
            pubDate: date,
            audioURL: audio,
            showTitle: feed.title,
            feedID: feed.id,
            feedURLString: feed.rssURLString,
            linkURL: page,
            descriptionRaw: chosenItemDescriptionRaw,
            artworkURL: artwork,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            feedContentKind: feed.contentKind
        )
    }

    /// Substack and similar feeds use `<enclosure type="image/jpeg" …>` for the hero image, not audio.
    private static func classifyEnclosure(url: String?, typeLower: String?) -> (audio: String?, imageFallback: String?) {
        guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else {
            return (nil, nil)
        }
        if let t = typeLower, !t.isEmpty {
            if t.hasPrefix("audio/") || t == "application/octet-stream" {
                return (u, nil)
            }
            if t.hasPrefix("image/") {
                return (nil, u)
            }
            return (urlLooksLikeAudioURL(u) ? u : nil, nil)
        }
        return (urlLooksLikeAudioURL(u) ? u : nil, nil)
    }

    private static func urlLooksLikeAudioURL(_ urlString: String) -> Bool {
        guard let path = URL(string: urlString)?.path.lowercased() else { return false }
        let audioSuffixes = [".mp3", ".m4a", ".mp4", ".aac", ".wav", ".ogg", ".opus", ".flac", ".mpeg"]
        return audioSuffixes.contains { path.hasSuffix($0) }
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
