import Foundation

struct ITunesPodcastMatch: Identifiable, Sendable {
    var id: String { rssURL.absoluteString }
    let title: String
    let artistName: String?
    let rssURL: URL
    let artworkURL: URL?
}

enum ITunesPodcastSearchService {
    nonisolated static func search(term: String) async throws -> [ITunesPodcastMatch] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url else { throw ITunesSearchError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw ITunesSearchError.badResponse
        }

        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.compactMap { item in
            guard let feedUrlString = item.feedUrl,
                  let feedURL = URL(string: feedUrlString),
                  feedURL.scheme?.hasPrefix("http") == true
            else { return nil }
            let title = item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            let artist = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let art = (item.artworkUrl600 ?? item.artworkUrl100).flatMap { URL(string: $0) }
            return ITunesPodcastMatch(
                title: title,
                artistName: artist.flatMap { $0.isEmpty ? nil : $0 },
                rssURL: feedURL,
                artworkURL: art
            )
        }
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesPodcastResult]
}

private struct ITunesPodcastResult: Decodable {
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
}

enum ITunesSearchError: LocalizedError {
    case badURL
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid search request."
        case .badResponse: return "Could not reach Apple Podcasts search."
        }
    }
}
