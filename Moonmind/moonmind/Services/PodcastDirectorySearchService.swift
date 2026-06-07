import CryptoKit
import Foundation

/// Tries iTunes Search API first; falls back to Podcast Index if iTunes fails.
enum PodcastDirectorySearchService {
    nonisolated static func search(term: String) async throws -> [ITunesPodcastMatch] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var lastError: Error?

        do {
            let matches = try await ITunesPodcastSearchService.search(term: term)
            if !matches.isEmpty { return matches }
        } catch {
            lastError = error
        }

        if !LocalSecrets.podcastIndexAPIKey.isEmpty, !LocalSecrets.podcastIndexAPISecret.isEmpty {
            return try await podcastIndexSearch(term: trimmed)
        }

        if let lastError { throw lastError }
        return []
    }

    // MARK: - Podcast Index fallback (optional; keys in gitignored LocalSecrets.swift)

    private nonisolated static func podcastIndexSearch(term: String) async throws -> [ITunesPodcastMatch] {
        let apiKey = LocalSecrets.podcastIndexAPIKey
        let apiSecret = LocalSecrets.podcastIndexAPISecret
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm")!
        components.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "max", value: "25"),
        ]
        guard let url = components.url else { throw ITunesSearchError.badURL }

        let epoch = String(Int(Date().timeIntervalSince1970))
        let hash = Insecure.SHA1
            .hash(data: Data((apiKey + apiSecret + epoch).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(epoch, forHTTPHeaderField: "X-Auth-Date")
        request.setValue(hash, forHTTPHeaderField: "Authorization")
        request.setValue("LunarCast/iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ITunesSearchError.badResponse(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }

        let decoded = try JSONDecoder().decode(PIResponse.self, from: data)
        return decoded.feeds.compactMap { feed in
            guard let urlStr = feed.url, let rss = URL(string: urlStr), rss.scheme?.hasPrefix("http") == true,
                  let title = feed.title, !title.isEmpty
            else { return nil }
            return ITunesPodcastMatch(
                title: title,
                artistName: feed.author,
                rssURL: rss,
                artworkURL: (feed.artwork ?? feed.image).flatMap { URL(string: $0) }
            )
        }
    }
}

private struct PIResponse: Decodable { let feeds: [PIFeed] }
private struct PIFeed: Decodable {
    let title: String?
    let url: String?
    let author: String?
    let image: String?
    let artwork: String?
}
