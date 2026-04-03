import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var detailBottomChrome: DetailBottomChromeState
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var feedFilters: FeedFilters
    @ObservedObject var model: HomeViewModel
    @Binding var selectedTab: Int
    @Binding var showAddFeeds: Bool
    @ObservedObject var episodePlayback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var episodeDownloads: EpisodeDownloadStore
    @Binding var showAppSettings: Bool

    @State private var navigationPath = NavigationPath()
    @State private var feedListScrollY: CGFloat = 0

    @ViewBuilder
    private var podcastEpisodesSortButton: some View {
        Button {
            feedFilters.togglePodcastFeedSortOrder()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            feedFilters.podcastFeedSortNewestFirst
                ? "Sorted by date, newest first"
                : "Sorted by date, oldest first"
        )
    }

    private var displayedEpisodes: [Episode] {
        let filtered: [Episode] = {
            guard feedFilters.feedShowUnplayedOnly else { return model.episodes }
            return model.episodes.filter { episode in
                if episode.audioURL == nil { return true }
                return !episodePlayback.progressStore.isMarkedPlayed(forEpisodeKey: episode.stableKey)
            }
        }()
        return filtered.sorted { a, b in
            let da = a.pubDate ?? .distantPast
            let db = b.pubDate ?? .distantPast
            if feedFilters.podcastFeedSortNewestFirst {
                return da > db
            } else {
                return da < db
            }
        }
    }

    private func applyMiniPlayerPodcastNavigation(_ request: AutoplayDetailNavigation?) {
        guard let request, request.feed == .podcast else { return }
        var path = NavigationPath()
        path.append(request.episode)
        navigationPath = path
        episodePlayback.consumeMiniPlayerDetailNavigation()
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            feedContents
                .navigationDestination(for: Episode.self) { ep in
                    EpisodeDetailView(
                        episode: ep,
                        podcastHome: model,
                        playback: episodePlayback,
                        progressStore: episodePlayback.progressStore,
                        sleepTimer: sleepTimer,
                        downloads: episodeDownloads
                    )
                }
        }
        .onChange(of: episodePlayback.autoplayDetailNavigation) { _, _ in
            guard let request = episodePlayback.autoplayDetailNavigation,
                  request.feed == .podcast
            else { return }
            var path = NavigationPath()
            path.append(request.episode)
            navigationPath = path
            episodePlayback.consumeAutoplayDetailNavigation()
        }
        .onChange(of: episodePlayback.miniPlayerDetailNavigation) { _, _ in
            guard selectedTab == 0 else { return }
            applyMiniPlayerPodcastNavigation(episodePlayback.miniPlayerDetailNavigation)
        }
        .onAppear {
            guard selectedTab == 0 else { return }
            applyMiniPlayerPodcastNavigation(episodePlayback.miniPlayerDetailNavigation)
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == 0 else { return }
            applyMiniPlayerPodcastNavigation(episodePlayback.miniPlayerDetailNavigation)
        }
        .onChange(of: navigationPath.count) { _, _ in
            if navigationPath.isEmpty {
                MiniPlayerChromeScrollCoordinator.applyContentOffsetY(
                    feedListScrollY,
                    detailChrome: detailBottomChrome,
                    playback: episodePlayback
                )
            }
        }
        .toolbar(detailBottomChrome.isCompact ? .hidden : .automatic, for: .tabBar)
    }

    @ViewBuilder
    private var feedContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("LunarCast")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                podcastEpisodesSortButton
                    .imageScale(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            FeedFilterBar(feeds: catalog.podcastFeeds, scope: .podcast, filters: feedFilters) {
                model.applyFilterInstantly(feeds: catalog.podcastFeeds, feedFilters: feedFilters)
                Task {
                    await model.refresh(
                        feeds: catalog.podcastFeeds,
                        feedFilters: feedFilters,
                        downloads: episodeDownloads
                    )
                }
            }
            .padding(.horizontal)

            if model.isLoading && model.episodes.isEmpty {
                ProgressView("Loading episodes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.lastError, model.episodes.isEmpty {
                ContentUnavailableView(
                    "Could not load feeds",
                    systemImage: "wifi.exclamationmark",
                    description: Text(err)
                )
            } else if model.episodes.isEmpty {
                ContentUnavailableView(
                    "No shows selected",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Choose All or a show with the filters above.")
                )
            } else if displayedEpisodes.isEmpty {
                ContentUnavailableView(
                    feedFilters.feedShowUnplayedOnly ? "All caught up" : "No episodes",
                    systemImage: "checkmark.circle",
                    description: Text(
                        feedFilters.feedShowUnplayedOnly
                            ? "Every episode from your shows is played, or turn off unplayed-only to see the full feed again."
                            : ""
                    )
                )
            } else {
                List {
                    if let banner = model.lastError {
                        Section {
                            Text(banner)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(displayedEpisodes) { ep in
                            NavigationLink(value: ep) {
                                EpisodeRow(
                                    episode: ep,
                                    downloads: episodeDownloads,
                                    progressStore: episodePlayback.progressStore,
                                    playback: episodePlayback
                                )
                            }
                            .contextMenu {
                                if ep.audioURL != nil {
                                    if episodePlayback.progressStore.isMarkedPlayed(forEpisodeKey: ep.stableKey) {
                                        Button {
                                            episodePlayback.markEpisodeUnplayed(episodeKey: ep.stableKey)
                                        } label: {
                                            Label("Mark as Unplayed", systemImage: "arrow.uturn.backward.circle")
                                        }
                                    } else {
                                        Button {
                                            episodePlayback.markEpisodePlayed(episodeKey: ep.stableKey)
                                        } label: {
                                            Label("Mark as Played", systemImage: "checkmark.circle")
                                        }
                                    }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if ep.audioURL != nil {
                                    if episodePlayback.progressStore.isMarkedPlayed(forEpisodeKey: ep.stableKey) {
                                        Button {
                                            episodePlayback.markEpisodeUnplayed(episodeKey: ep.stableKey)
                                        } label: {
                                            Label("Mark as Unplayed", systemImage: "arrow.uturn.backward.circle")
                                        }
                                    } else {
                                        Button {
                                            episodePlayback.markEpisodePlayed(episodeKey: ep.stableKey)
                                        } label: {
                                            Label("Mark as Played", systemImage: "checkmark.circle")
                                        }
                                        .tint(.green)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if episodeDownloads.isDownloaded(episodeKey: ep.stableKey) {
                                    Button(role: .destructive) {
                                        episodeDownloads.removeDownload(forEpisodeKey: ep.stableKey)
                                    } label: {
                                        Label("Remove download", systemImage: "trash")
                                    }
                                } else if ep.audioURL != nil {
                                    Button {
                                        Task { await episodeDownloads.downloadIfNeeded(episode: ep) }
                                    } label: {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                    .tint(.accentColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerChromeScrollTracking(playback: episodePlayback, scrollOffset: $feedListScrollY)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    feedFilters.toggleFeedShowUnplayedOnly()
                } label: {
                    Image(systemName: feedFilters.feedShowUnplayedOnly ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(
                    feedFilters.feedShowUnplayedOnly ? "Show all episodes" : "Show unplayed only"
                )

                Button {
                    showAddFeeds = true
                } label: {
                    Label("Podcasts", systemImage: "plus.square.on.square")
                }

                SettingsToolbarButton(showSettings: $showAppSettings)
            }
        }
        .task {
            await model.refresh(feeds: catalog.podcastFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
        }
        .refreshable {
            await model.refresh(feeds: catalog.podcastFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
        }
    }
}

// MARK: - Episode row

private enum EpisodePlayIndicatorState: Equatable {
    case hidden
    case unplayed
    case partial(fraction: CGFloat?)
    case played
}

private func playIndicatorState(episode: Episode, progress: EpisodePlaybackProgressStore, playback: EpisodePlaybackController)
    -> EpisodePlayIndicatorState {
    guard episode.audioURL != nil else { return .hidden }
    if progress.isMarkedPlayed(forEpisodeKey: episode.stableKey) { return .played }

    let minResume: TimeInterval = 3
    if playback.loadedEpisodeKey == episode.stableKey,
       playback.duration > 0, playback.duration.isFinite,
       playback.currentTime >= minResume {
        let frac = CGFloat(playback.currentTime / playback.duration)
        return .partial(fraction: min(1, max(0, frac)))
    }

    if progress.position(forEpisodeKey: episode.stableKey) != nil {
        return .partial(fraction: nil)
    }

    return .unplayed
}

private struct EpisodePlayStatusIndicator: View {
    let state: EpisodePlayIndicatorState

    var body: some View {
        Group {
            switch state {
            case .hidden:
                Color.clear.frame(width: 14, height: 14)
            case .unplayed:
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            case .partial(let fraction):
                if let f = fraction {
                    ZStack {
                        Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: f)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            case .played:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .hidden:
            return ""
        case .unplayed:
            return "Unplayed"
        case .partial:
            return "In progress"
        case .played:
            return "Played"
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    @ObservedObject var downloads: EpisodeDownloadStore
    @ObservedObject var progressStore: EpisodePlaybackProgressStore
    @ObservedObject var playback: EpisodePlaybackController

    private var indicatorState: EpisodePlayIndicatorState {
        playIndicatorState(episode: episode, progress: progressStore, playback: playback)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EpisodePlayStatusIndicator(state: indicatorState)
            PodcastArtworkView(url: episode.artworkURL, size: 64, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.showTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(episode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = episode.pubDate {
                    Text(d.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EpisodeDownloadAccessory(episode: episode, downloads: downloads, interactive: false)
        }
        .padding(.vertical, 4)
    }
}
