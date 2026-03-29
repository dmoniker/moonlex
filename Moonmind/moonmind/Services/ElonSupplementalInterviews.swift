import Foundation

/// Two hand-picked Elon interviews from feeds that are not part of the recurring RSS merge.
/// Each slot is resolved at most once per schema version, then stored under Application Support so routine refreshes do not re-fetch these feeds.
enum ElonSupplementalInterviews {
    private static let schemaVersion = 1
    private static let fileName = "elonSupplementalInterviews.v1.json"

    private struct Persisted: Codable {
        var schemaVersion: Int
        var episodesBySlot: [String: Episode]
    }

    private static let slotWEFDavosElon = "wef.davos2026.elon.fink"
    private static let slotPeopleByWTFEp16EN = "pbwtf.elon.ep16.en"

    private static let wefFeed = PodcastFeed(
        id: "builtin.elon.supplemental.wef",
        title: "Meet The Leader",
        rssURLString: "https://rss.libsyn.com/shows/494933/destinations/4231753.xml",
        isBuiltin: true
    )

    private static let peopleByWTFFeed = PodcastFeed(
        id: "builtin.elon.supplemental.peoplebywtf",
        title: "People by WTF",
        rssURLString: "https://feeds.hubhopper.com/db41907e6c28518ffe336b392c715ef1.rss",
        isBuiltin: true
    )

    /// Enough items to find recent featured episodes without scanning the full rolling history.
    private static let rssScanCap = RSSFeedService.FetchOptions(maxItems: 200, notBefore: nil)

    static func cachedOrResolveEpisodes() async -> [Episode] {
        var box = loadPersisted()
        if box.schemaVersion != schemaVersion {
            box = Persisted(schemaVersion: schemaVersion, episodesBySlot: [:])
        }

        var mutated = false
        if box.episodesBySlot[slotWEFDavosElon] == nil,
           let ep = await fetchFirstMatch(from: wefFeed, matches: matchesWEFElonDavosConversation) {
            box.episodesBySlot[slotWEFDavosElon] = ep
            mutated = true
        }
        if box.episodesBySlot[slotPeopleByWTFEp16EN] == nil,
           let ep = await fetchFirstMatch(from: peopleByWTFFeed, matches: matchesPeopleByWTFEp16EnglishFull) {
            box.episodesBySlot[slotPeopleByWTFEp16EN] = ep
            mutated = true
        }
        if mutated { save(box) }
        return Array(box.episodesBySlot.values)
    }

    private static func loadPersisted() -> Persisted {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Persisted.self, from: data)
        else {
            return Persisted(schemaVersion: schemaVersion, episodesBySlot: [:])
        }
        return box
    }

    private static func save(_ box: Persisted) {
        guard let url = fileURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(box) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("moonmind", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func fetchFirstMatch(from feed: PodcastFeed, matches: (Episode) -> Bool) async -> Episode? {
        guard let eps = try? await RSSFeedService.loadEpisodes(for: feed, options: rssScanCap) else { return nil }
        return eps.first(where: matches)
    }

    /// WEF Davos 2026 session with Larry Fink (distinct from the Jensen Huang conversation in the same feed).
    private static func matchesWEFElonDavosConversation(_ ep: Episode) -> Bool {
        ep.title.lowercased().contains("conversation with elon musk")
    }

    /// English full interview only (not trailer / Hindi dub).
    private static func matchesPeopleByWTFEp16EnglishFull(_ ep: Episode) -> Bool {
        let t = ep.title
        let l = t.lowercased()
        guard l.contains("elon musk") || (l.contains("elon") && l.contains("musk")) else { return false }
        guard l.contains("different conversation") else { return false }
        guard l.contains("full episode") else { return false }
        if l.contains("trailer") { return false }
        if t.unicodeScalars.contains(where: { (0x0900 ... 0x097F).contains($0.value) }) { return false }
        return true
    }
}
