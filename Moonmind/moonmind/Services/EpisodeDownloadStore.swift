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
    /// Stored in UserDefaults as megabytes. `0` means no limit.
    static let storageLimitMegabytesDefaultsKey = "moonmind.downloadStorageLimitMB.v1"

    /// Called on the main actor after a new file is written: stable episode key, remote URL, local file URL.
    var onDownloadReady: ((String, URL, URL) -> Void)?

    /// Bumped when downloads or removals complete so views can refresh playback URL.
    @Published private(set) var changeToken: UInt64 = 0

    @Published private(set) var activeDownloadKeys: Set<String> = []

    /// Episode keys purged because a feed was removed; in-flight downloads discard output instead of indexing.
    private var discardedDownloadKeys: Set<String> = []

    private var index: [String: IndexRecord] = [:]
    private let fm = FileManager.default

    init() {
        loadIndex()
        pruneMissingFiles()
        enforceStorageLimit()
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

    /// Removes oldest downloads (by file modification date) until usage is at or below the user’s limit. No-op when limit is unlimited.
    func enforceStorageLimit() {
        let limitBytes = Self.storageLimitBytesFromUserDefaults()
        guard limitBytes > 0 else { return }

        while totalStoredByteCount() > limitBytes {
            guard let victimKey = oldestStoredEpisodeKey() else { return }
            removeDownload(forEpisodeKey: victimKey)
        }
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

    /// After feed refresh: download the newest episode with audio for each feed, if not already stored.
    func enqueueRecentEpisodeDownloads(episodes: [Episode]) {
        let byFeed = Dictionary(grouping: episodes, by: \.feedID)
        for (_, feedEpisodes) in byFeed {
            let sorted = feedEpisodes.sorted {
                ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
            }
            guard let newest = sorted.first, newest.audioURL != nil else { continue }
            guard !isDownloaded(episodeKey: newest.stableKey), !isDownloading(episodeKey: newest.stableKey) else { continue }
            Task { await downloadIfNeeded(episode: newest) }
        }
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
            enforceStorageLimit()
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
