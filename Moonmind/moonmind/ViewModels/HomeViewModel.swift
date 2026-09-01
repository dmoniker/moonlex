import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var episodes: [Episode] = []
    /// Full-screen spinner only when there is nothing to show yet (first launch / empty cache).
    @Published var isLoading = false
    @Published var lastError: String?

    /// Raw RSS/API episodes per feed (Moonshots & Lex unfiltered). Enables instant chip switches without waiting on the network.
    private var episodeCacheByFeedID: [String: [Episode]] = [:]
    /// Drops stale RSS results when the user changes filters mid-refresh.
    private var refreshGeneration: UInt64 = 0

    init() {
        episodeCacheByFeedID = FeedEpisodeCache.load()
    }

    /// Loads disk cache and hydrates ``episodes`` before the first SwiftUI frame (see ``ContentView`` init).
    static func warmStarted(feeds: [PodcastFeed], feedFilters: FeedFilters) -> HomeViewModel {
        let vm = HomeViewModel()
        if !vm.episodeCacheByFeedID.isEmpty {
            vm.applyFilterInstantly(feeds: feeds, feedFilters: feedFilters)
        }
        return vm
    }

    private static func filterScope(for feeds: [PodcastFeed]) -> FeedFilterBarScope {
        if let first = feeds.first { first.contentKind == .newsletter ? .newsletter : .podcast } else { .podcast }
    }

    /// Recomputes the list from the in-memory cache only (synchronous).
    func applyFilterInstantly(feeds: [PodcastFeed], feedFilters: FeedFilters) {
        lastError = nil
        var merged = Self.mergedEpisodesBeforeHero(from: episodeCacheByFeedID, feeds: feeds, feedFilters: feedFilters)
        let heroFromNewsletter = episodeCacheByFeedID[PodcastFeed.innermostLoopID] ?? []
        let heroByLink = Self.innermostNewsletterHeroByNormalizedLink(from: heroFromNewsletter)
        merged = Self.applyInnermostHeroMap(heroByLink, to: merged)
        episodes = merged.sorted {
            ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
        }
    }

    func refresh(feeds: [PodcastFeed], feedFilters: FeedFilters, downloads: EpisodeDownloadStore? = nil) async {
        lastError = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let showingCachedList = !episodes.isEmpty
        if !showingCachedList {
            isLoading = true
        }

        let filterScope = Self.filterScope(for: feeds)
        let enabledIDs = Set(feeds.filter { feedFilters.isOn($0.id, scope: filterScope) }.map(\.id))
        let feedsCopy = feeds
        let cacheSnapshot = episodeCacheByFeedID

        let outcome = await Task.detached(priority: .utility) {
            await Self.fetchRefreshOutcome(feeds: feedsCopy, enabledIDs: enabledIDs, existingCache: cacheSnapshot)
        }.value

        guard generation == refreshGeneration else { return }

        for (id, eps) in outcome.updates {
            episodeCacheByFeedID[id] = eps
        }

        applyFilterInstantly(feeds: feedsCopy, feedFilters: feedFilters)
        isLoading = false

        if !outcome.errors.isEmpty {
            if episodes.isEmpty {
                lastError = outcome.errors.joined(separator: "\n")
            } else {
                lastError = "Some feeds failed to load: \(outcome.errors.joined(separator: ", "))"
            }
        }

        let persistSnapshot = episodeCacheByFeedID
        Task.detached(priority: .utility) {
            FeedEpisodeCache.save(persistSnapshot)
        }

        if let downloads {
            let downloadSnapshot = persistSnapshot
            Task { @MainActor in
                await Task.yield()
                downloads.enqueueRecentEpisodeDownloads(episodeCacheByFeedID: downloadSnapshot)
            }
        }
    }

    private struct FeedRefreshOutcome: Sendable {
        var updates: [String: [Episode]]
        var errors: [String]
    }

    /// Network + XML parse. Must not hop to the main actor; callers publish UI afterwards.
    nonisolated private static func fetchRefreshOutcome(
        feeds: [PodcastFeed],
        enabledIDs: Set<String>,
        existingCache: [String: [Episode]]
    ) async -> FeedRefreshOutcome {
        let moonshotsChip = enabledIDs.contains(PodcastFeed.moonshotsID)
        let lexChip = enabledIDs.contains(PodcastFeed.lexID)
        let elonChip = enabledIDs.contains(PodcastFeed.elonGuestInterviewsFeedID)
        let podcastCatalogRefresh = feeds.contains { $0.contentKind == .podcast }
        let activeNonSpecial = feeds.filter { feed in
            feed.id != PodcastFeed.moonshotsID
                && feed.id != PodcastFeed.lexID
                && feed.id != PodcastFeed.elonGuestInterviewsFeedID
                && enabledIDs.contains(feed.id)
        }

        var updates: [String: [Episode]] = [:]
        var errors: [String] = []

        guard elonChip || moonshotsChip || lexChip || !activeNonSpecial.isEmpty else {
            return FeedRefreshOutcome(updates: [:], errors: [])
        }

        await withTaskGroup(of: Result<(String, [Episode]), Error>.self) { group in
            if podcastCatalogRefresh, let moon = feeds.first(where: { $0.id == PodcastFeed.moonshotsID }) {
                let elonOnlyMoon = elonChip && !moonshotsChip
                if moonshotsChip || elonOnlyMoon {
                    let moonOpts = elonOnlyMoon ? RSSFeedService.FetchOptions.rollingFiveYears() : .standard
                    group.addTask {
                        do {
                            let eps = try await RSSFeedService.loadEpisodes(for: moon, options: moonOpts)
                            return .success((moon.id, eps))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }

            if podcastCatalogRefresh, let lex = feeds.first(where: { $0.id == PodcastFeed.lexID }) {
                let elonOnlyLex = elonChip && !lexChip
                if lexChip || elonOnlyLex {
                    let lexOpts = elonOnlyLex ? RSSFeedService.FetchOptions.rollingFiveYears() : .standard
                    group.addTask {
                        do {
                            let eps = try await RSSFeedService.loadEpisodes(for: lex, options: lexOpts)
                            return .success((lex.id, eps))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }

            for feed in activeNonSpecial {
                group.addTask {
                    do {
                        let eps = try await RSSFeedService.loadEpisodes(for: feed)
                        return .success((feed.id, eps))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            if podcastCatalogRefresh,
               elonChip,
               feeds.contains(where: { $0.id == PodcastFeed.elonGuestInterviewsFeedID }) {
                group.addTask {
                    let result = await Self.fetchElonGuestInterviewEpisodesFromRSS()
                    switch result {
                    case .success(let eps):
                        return .success((PodcastFeed.elonGuestInterviewsFeedID, eps))
                    case .failure(let err):
                        return .failure(err)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let pair):
                    updates[pair.0] = pair.1
                case .failure(let err):
                    errors.append(err.localizedDescription)
                }
            }
        }

        var mergedCache = existingCache
        for (id, eps) in updates {
            mergedCache[id] = eps
        }

        var heroByLink = Self.innermostNewsletterHeroByNormalizedLink(from: mergedCache[PodcastFeed.innermostLoopID] ?? [])
        if heroByLink.isEmpty,
           podcastCatalogRefresh,
           enabledIDs.contains(PodcastFeed.innermostLoopPodcastID),
           !enabledIDs.contains(PodcastFeed.innermostLoopID),
           let newsFeed = PodcastFeed.builtins.first(where: { $0.id == PodcastFeed.innermostLoopID }),
           let newsEps = try? await RSSFeedService.loadEpisodes(for: newsFeed) {
            updates[PodcastFeed.innermostLoopID] = newsEps
        }

        return FeedRefreshOutcome(updates: updates, errors: errors)
    }

    private static func mergedEpisodesBeforeHero(
        from cache: [String: [Episode]],
        feeds: [PodcastFeed],
        feedFilters: FeedFilters
    ) -> [Episode] {
        let filterScope = Self.filterScope(for: feeds)
        let moonshotsChip = feedFilters.isOn(PodcastFeed.moonshotsID, scope: filterScope)
        let lexChip = feedFilters.isOn(PodcastFeed.lexID, scope: filterScope)
        let elonChip = feedFilters.isOn(PodcastFeed.elonGuestInterviewsFeedID, scope: filterScope)
        let podcastCatalogRefresh = feeds.contains { $0.contentKind == .podcast }
        let activeNonSpecial = feeds.filter { feed in
            feed.id != PodcastFeed.moonshotsID
                && feed.id != PodcastFeed.lexID
                && feed.id != PodcastFeed.elonGuestInterviewsFeedID
                && feedFilters.isOn(feed.id, scope: filterScope)
        }
        guard elonChip || moonshotsChip || lexChip || !activeNonSpecial.isEmpty else {
            return []
        }

        var combined: [Episode] = []

        if podcastCatalogRefresh, let moon = feeds.first(where: { $0.id == PodcastFeed.moonshotsID }) {
            let elonOnly = elonChip && !moonshotsChip
            if moonshotsChip || elonOnly, let eps = cache[moon.id] {
                var slice = eps
                if elonOnly {
                    slice = slice.filter { ElonGuestEpisodeFilter.passes($0) }
                }
                combined.append(contentsOf: slice)
            }
        }

        if podcastCatalogRefresh, let lex = feeds.first(where: { $0.id == PodcastFeed.lexID }) {
            let elonOnly = elonChip && !lexChip
            if lexChip || elonOnly, let eps = cache[lex.id] {
                var slice = eps
                if elonOnly {
                    slice = slice.filter { ElonGuestEpisodeFilter.passes($0) }
                }
                combined.append(contentsOf: slice)
            }
        }

        for feed in activeNonSpecial {
            if let eps = cache[feed.id] {
                combined.append(contentsOf: eps)
            }
        }

        if podcastCatalogRefresh,
           elonChip,
           feeds.contains(where: { $0.id == PodcastFeed.elonGuestInterviewsFeedID }),
           let eps = cache[PodcastFeed.elonGuestInterviewsFeedID] {
            combined.append(contentsOf: eps)
        }

        return combined
    }

    /// Parallel RSS fetch: each source is filtered to Elon-as-guest only.
    nonisolated private static func fetchElonGuestInterviewEpisodesFromRSS() async -> Result<[Episode], Error> {
        await withTaskGroup(of: Result<[Episode], Error>.self) { group in
            let elonSourceOpts = RSSFeedService.FetchOptions.rollingFiveYears()
            for source in PodcastFeed.elonInterviewRSSSourceFeeds {
                group.addTask {
                    do {
                        let eps = try await RSSFeedService.loadEpisodes(for: source, options: elonSourceOpts)
                        return .success(eps.filter { ElonGuestEpisodeFilter.passes($0) })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var merged: [Episode] = []
            var failures: [Error] = []
            for await result in group {
                switch result {
                case .success(let eps):
                    merged.append(contentsOf: eps)
                case .failure(let err):
                    failures.append(err)
                }
            }
            merged.append(contentsOf: await ElonSupplementalInterviews.cachedOrResolveEpisodes())
            var byKey: [String: Episode] = [:]
            for ep in merged { byKey[ep.stableKey] = ep }
            let deduped = Array(byKey.values)
            if deduped.isEmpty, let first = failures.first {
                return .failure(first)
            }
            return .success(deduped)
        }
    }

    nonisolated private static func innermostNewsletterHeroByNormalizedLink(from episodes: [Episode]) -> [String: URL] {
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

    nonisolated private static func normalizedPostLinkKey(_ url: URL?) -> String? {
        guard let url else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        c?.query = nil
        guard let normalized = c?.url else { return nil }
        return normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
