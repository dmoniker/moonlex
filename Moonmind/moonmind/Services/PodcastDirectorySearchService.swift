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

        if !apiKey.isEmpty, !apiSecret.isEmpty {
            return try await podcastIndexSearch(term: trimmed)
        }

        if let lastError { throw lastError }
        return []
    }

    // MARK: - Podcast Index fallback

    // Free keys — sign up at https://podcastindex.org/account (takes 30 seconds)
    private static let apiKey = "WMEBTXUUW73QUDALWQMZ"      // paste your API Key here
    private static let apiSecret = "b2qKjYkEChvX5a3BZTTAYY8Dj3L6r4jeDUHR7B#X"   // paste your API Secret here

    private nonisolated static func podcastIndexSearch(term: String) async throws -> [ITunesPodcastMatch] {
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
