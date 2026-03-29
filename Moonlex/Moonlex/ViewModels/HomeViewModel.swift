import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var episodes: [Episode] = []
    @Published var isLoading = false
    @Published var lastError: String?

    func refresh(feeds: [PodcastFeed], feedFilters: FeedFilters, downloads: EpisodeDownloadStore? = nil) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let active = feeds.filter { feedFilters.isOn($0.id) }
        guard !active.isEmpty else {
            episodes = []
            return
        }

        var combined: [Episode] = []
        var errors: [String] = []

        await withTaskGroup(of: Result<[Episode], Error>.self) { group in
            for feed in active {
                group.addTask {
                    do {
                        let eps = try await RSSFeedService.loadEpisodes(for: feed)
                        return .success(eps)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let eps):
                    combined.append(contentsOf: eps)
                case .failure(let err):
                    errors.append(err.localizedDescription)
                }
            }
        }

        episodes = combined.sorted {
            ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
        }

        downloads?.enqueueRecentEpisodeDownloads(episodes: episodes)

        if !errors.isEmpty, combined.isEmpty {
            lastError = errors.joined(separator: "\n")
        } else if !errors.isEmpty {
            lastError = "Some feeds failed to load: \(errors.joined(separator: ", "))"
        }
    }
}
