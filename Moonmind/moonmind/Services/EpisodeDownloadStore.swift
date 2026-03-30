import Combine
import CryptoKit
import Foundation

@MainActor
final class EpisodeDownloadStore: ObservableObject {
    private struct IndexRecord: Codable, Equatable {
        var remoteURLString: String
        var relativeFileName: String
    }

    private static let indexDefaultsKey = "moonmind.episodeDownloadIndex.v1"
    /// Stored in UserDefaults as megabytes. `0` means no limit. Used when ``DownloadRetentionMode`` is ``totalStorageCap``.
    static let storageLimitMegabytesDefaultsKey = "moonmind.downloadStorageLimitMB.v1"
    /// How automatic retention chooses what to delete / how much to prefetch.
    static let downloadRetentionModeDefaultsKey = "moonmind.downloadRetentionMode.v1"
    /// Latest _N_ episodes per show to keep (and prefetch) when mode is ``episodesPerShow``.
    static let downloadEpisodesPerShowDefaultsKey = "moonmind.downloadEpisodesPerShow.v1"

    enum DownloadRetentionMode: String, CaseIterable {
        case episodesPerShow
        case totalStorageCap
    }

    private static func retentionModeFromUserDefaults() -> DownloadRetentionMode {
        let raw = UserDefaults.standard.string(forKey: downloadRetentionModeDefaultsKey)
            ?? DownloadRetentionMode.episodesPerShow.rawValue
        return DownloadRetentionMode(rawValue: raw) ?? .episodesPerShow
    }

    private static func episodesPerShowLimitFromUserDefaults() -> Int {
        let n = UserDefaults.standard.integer(forKey: downloadEpisodesPerShowDefaultsKey)
        return n > 0 ? n : 3
    }

    /// Called on the main actor after a new file is written: stable episode key, remote URL, local file URL.
    var onDownloadReady: ((String, URL, URL) -> Void)?

    /// Bumped when downloads or removals complete so views can refresh playback URL.
    @Published private(set) var changeToken: UInt64 = 0

    @Published private(set) var activeDownloadKeys: Set<String> = []

    /// Episode keys purged because a feed was removed; in-flight downloads discard output instead of indexing.
    private var discardedDownloadKeys: Set<String> = []

    /// Latest feed snapshots from the last home refresh; used for per-show retention when settings change or a download finishes.
    private var lastEpisodeCacheByFeedID: [String: [Episode]] = [:]

    private var index: [String: IndexRecord] = [:]
    private let fm = FileManager.default

    init() {
        loadIndex()
        pruneMissingFiles()
        applyRetentionPolicy(episodeCacheByFeedID: lastEpisodeCacheByFeedID)
    }

    /// Re-runs retention using the episode lists from the most recent ``enqueueRecentEpisodeDownloads`` (e.g. after changing settings).
    func reapplyRetentionUsingLastFeedCache() {
        applyRetentionPolicy(episodeCacheByFeedID: lastEpisodeCacheByFeedID)
    }

    // MARK: - Public API

    static func storageLimitBytesFromUserDefaults() -> Int64 {
        let mb = UserDefaults.standard.integer(forKey: storageLimitMegabytesDefaultsKey)
        guard mb > 0 else { return 0 }
        return Int64(mb) * 1_048_576
    }

    /// Total on-disk size of indexed episode files.
    func totalStoredByteCount() -> Int64 {
        var sum: Int64 = 0
        for (_, rec) in index {
            let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
            guard fm.fileExists(atPath: url.path) else { continue }
            if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                sum += Int64(sz)
            }
        }
        return sum
    }

    /// Deletes every stored episode file and clears the download index.
    func clearAllDownloads() {
        for (_, rec) in index {
            let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
            try? fm.removeItem(at: url)
        }
        index = [:]
        saveIndex()
        bumpToken()
    }

    /// Applies storage-cap or per-show rules per the current retention mode. An empty map skips per-show purges (and leaves downloads for feeds missing from the cache unchanged).
    private func applyRetentionPolicy(episodeCacheByFeedID: [String: [Episode]]) {
        switch Self.retentionModeFromUserDefaults() {
        case .episodesPerShow:
            enforceEpisodesPerShowLimit(episodeCacheByFeedID: episodeCacheByFeedID)
        case .totalStorageCap:
            enforceStorageLimit()
        }
    }

    /// Removes oldest downloads (by file modification date) until usage is at or below the user’s limit. No-op when limit is unlimited.
    func enforceStorageLimit() {
        let limitBytes = Self.storageLimitBytesFromUserDefaults()
        guard limitBytes > 0 else { return }

        while totalStoredByteCount() > limitBytes {
            guard let victimKey = oldestStoredEpisodeKey() else { return }
            removeDownload(forEpisodeKey: victimKey)
        }
    }

    private func enforceEpisodesPerShowLimit(episodeCacheByFeedID: [String: [Episode]]) {
        guard !episodeCacheByFeedID.isEmpty else { return }
        let n = Self.episodesPerShowLimitFromUserDefaults()
        var allowedKeys = Set<String>()
        for (_, eps) in episodeCacheByFeedID {
            let withAudio = eps.filter { $0.audioURL != nil }.sorted {
                ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
            }
            for ep in withAudio.prefix(n) {
                allowedKeys.insert(ep.stableKey)
            }
        }
        let toRemove = index.keys.filter { key in
            guard !allowedKeys.contains(key) else { return false }
            guard let feedID = feedIDParsed(fromEpisodeKey: key) else { return false }
            return episodeCacheByFeedID[feedID] != nil
        }
        for key in toRemove {
            removeDownload(forEpisodeKey: key)
        }
    }

    private func feedIDParsed(fromEpisodeKey stableKey: String) -> String? {
        guard let i = stableKey.firstIndex(of: "|") else { return nil }
        let id = String(stableKey[..<i])
        return id.isEmpty ? nil : id
    }

    func localFileURL(forEpisodeKey stableKey: String) -> URL? {
        guard let rec = index[stableKey] else { return nil }
        let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func playbackURL(for episode: Episode) -> URL? {
        localFileURL(forEpisodeKey: episode.stableKey) ?? episode.audioURL
    }

    func isDownloaded(episodeKey stableKey: String) -> Bool {
        localFileURL(forEpisodeKey: stableKey) != nil
    }

    func isDownloading(episodeKey stableKey: String) -> Bool {
        activeDownloadKeys.contains(stableKey)
    }

    /// After feed refresh: auto-download recent episodes per feed (how many depends on retention mode), then apply retention.
    func enqueueRecentEpisodeDownloads(episodeCacheByFeedID: [String: [Episode]]) {
        lastEpisodeCacheByFeedID = episodeCacheByFeedID
        let prefetchCount: Int
        switch Self.retentionModeFromUserDefaults() {
        case .episodesPerShow:
            prefetchCount = Self.episodesPerShowLimitFromUserDefaults()
        case .totalStorageCap:
            prefetchCount = 1
        }

        for (_, feedEpisodes) in episodeCacheByFeedID {
            let sorted = feedEpisodes.filter { $0.audioURL != nil }.sorted {
                ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
            }
            for ep in sorted.prefix(prefetchCount) where !isDownloaded(episodeKey: ep.stableKey) && !isDownloading(episodeKey: ep.stableKey) {
                Task { await downloadIfNeeded(episode: ep) }
            }
        }

        applyRetentionPolicy(episodeCacheByFeedID: episodeCacheByFeedID)
    }

    func downloadIfNeeded(episode: Episode) async {
        guard let remote = episode.audioURL else { return }
        let key = episode.stableKey
        if isDownloaded(episodeKey: key) { return }
        if activeDownloadKeys.contains(key) { return }

        activeDownloadKeys.insert(key)
        defer {
            activeDownloadKeys.remove(key)
            bumpToken()
        }

        do {
            try ensureEpisodesDirectory()
            let fileName = makeFileName(stableKey: key, remoteURL: remote)
            let dest = episodesDirectory.appendingPathComponent(fileName, isDirectory: false)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }

            let (tmp, response) = try await URLSession.shared.download(from: remote)
            try ensureHTTPOK(response)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tmp, to: dest)

            if discardedDownloadKeys.remove(key) != nil {
                try? fm.removeItem(at: dest)
                return
            }

            index[key] = IndexRecord(remoteURLString: remote.absoluteString, relativeFileName: fileName)
            saveIndex()
            onDownloadReady?(key, remote, dest)
            applyRetentionPolicy(episodeCacheByFeedID: lastEpisodeCacheByFeedID)
        } catch {
            try? fm.removeItem(at: episodesDirectory.appendingPathComponent(makeFileName(stableKey: key, remoteURL: remote), isDirectory: false))
        }
    }

    func removeDownload(forEpisodeKey stableKey: String) {
        guard let rec = index.removeValue(forKey: stableKey) else { return }
        let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
        try? fm.removeItem(at: url)
        saveIndex()
        bumpToken()
    }

    /// Deletes stored audio for every episode whose ``Episode/stableKey`` belongs to this feed (`feedID|…`).
    func removeAllDownloads(forFeedID feedID: String) {
        let prefix = "\(feedID)|"
        let indexMatches = index.keys.filter { $0.hasPrefix(prefix) }
        let activeMatches = activeDownloadKeys.filter { $0.hasPrefix(prefix) }
        for key in activeMatches {
            discardedDownloadKeys.insert(key)
        }
        for key in indexMatches {
            if let rec = index.removeValue(forKey: key) {
                let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
                try? fm.removeItem(at: url)
            }
        }
        for key in activeMatches {
            activeDownloadKeys.remove(key)
        }
        saveIndex()
        bumpToken()
    }

    // MARK: - Internals

    private var episodesDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("moonmind/Episodes", isDirectory: true)
    }

    private func bumpToken() {
        changeToken &+= 1
    }

    private func ensureEpisodesDirectory() throws {
        try fm.createDirectory(at: episodesDirectory, withIntermediateDirectories: true)
    }

    private func loadIndex() {
        guard let data = UserDefaults.standard.data(forKey: Self.indexDefaultsKey) else {
            index = [:]
            return
        }
        if let decoded = try? JSONDecoder().decode([String: IndexRecord].self, from: data) {
            index = decoded
        } else {
            index = [:]
        }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        UserDefaults.standard.set(data, forKey: Self.indexDefaultsKey)
    }

    private func pruneMissingFiles() {
        var removedAny = false
        for (key, rec) in index {
            let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
            if !fm.fileExists(atPath: url.path) {
                index.removeValue(forKey: key)
                removedAny = true
            }
        }
        if removedAny { saveIndex() }
        bumpToken()
    }

    private func oldestStoredEpisodeKey() -> String? {
        var best: (key: String, date: Date)?
        for (key, rec) in index {
            let url = episodesDirectory.appendingPathComponent(rec.relativeFileName, isDirectory: false)
            guard fm.fileExists(atPath: url.path) else { continue }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if let existing = best {
                if date < existing.date || (date == existing.date && key < existing.key) {
                    best = (key, date)
                }
            } else {
                best = (key, date)
            }
        }
        return best?.key
    }

    private func makeFileName(stableKey: String, remoteURL: URL) -> String {
        let basis = Data("\(stableKey)|\(remoteURL.absoluteString)".utf8)
        let hash = SHA256.hash(data: basis).map { String(format: "%02x", $0) }.joined()
        let ext = remoteURL.pathExtension.isEmpty ? "bin" : remoteURL.pathExtension
        return "\(String(hash.prefix(24))).\(ext)"
    }

    private func ensureHTTPOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
