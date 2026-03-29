import Combine
import CryptoKit
import Foundation

@MainActor
final class EpisodeDownloadStore: ObservableObject {
    private struct IndexRecord: Codable, Equatable {
        var remoteURLString: String
        var relativeFileName: String
    }

    private static let indexDefaultsKey = "moonlex.episodeDownloadIndex.v1"

    /// Bumped when downloads or removals complete so views can refresh playback URL.
    @Published private(set) var changeToken: UInt64 = 0

    @Published private(set) var activeDownloadKeys: Set<String> = []

    private var index: [String: IndexRecord] = [:]
    private let fm = FileManager.default

    init() {
        loadIndex()
        pruneMissingFiles()
    }

    // MARK: - Public API

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

            index[key] = IndexRecord(remoteURLString: remote.absoluteString, relativeFileName: fileName)
            saveIndex()
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

    // MARK: - Internals

    private var episodesDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Moonlex/Episodes", isDirectory: true)
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
