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

        var innermostHeroByLink = Self.innermostNewsletterHeroByNormalizedLink(from: combined)
        if innermostHeroByLink.isEmpty,
           combined.contains(where: { $0.feedID == PodcastFeed.innermostLoopPodcastID }),
           !active.contains(where: { $0.id == PodcastFeed.innermostLoopID }),
           let newsFeed = PodcastFeed.builtins.first(where: { $0.id == PodcastFeed.innermostLoopID }),
           let newsEps = try? await RSSFeedService.loadEpisodes(for: newsFeed) {
            innermostHeroByLink = Self.innermostNewsletterHeroByNormalizedLink(from: newsEps)
        }
        combined = Self.applyInnermostHeroMap(innermostHeroByLink, to: combined)

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

    /// Builds `link` → hero image from Innermost Loop newsletter RSS (`image/jpeg` enclosures).
    private static func innermostNewsletterHeroByNormalizedLink(from episodes: [Episode]) -> [String: URL] {
        var heroByLink: [String: URL] = [:]
        for ep in episodes where ep.feedID == PodcastFeed.innermostLoopID {
            guard let key = normalizedPostLinkKey(ep.linkURL), let art = ep.artworkURL else { continue }
            heroByLink[key] = art
        }
        return heroByLink
    }

    private static func applyInnermostHeroMap(_ heroByLink: [String: URL], to episodes: [Episode]) -> [Episode] {
        guard !heroByLink.isEmpty else { return episodes }
        return episodes.map { ep in
            guard ep.feedID == PodcastFeed.innermostLoopPodcastID,
                  let key = normalizedPostLinkKey(ep.linkURL),
                  let hero = heroByLink[key]
            else { return ep }
            return ep.replacingArtwork(with: hero)
        }
    }

    private static func normalizedPostLinkKey(_ url: URL?) -> String? {
        guard let url else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        c?.query = nil
        guard let normalized = c?.url else { return nil }
        return normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
