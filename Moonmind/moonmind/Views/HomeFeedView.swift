import SwiftUI

struct HomeFeedView: View {
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var feedFilters: FeedFilters
    @ObservedObject var model: HomeViewModel
    @Binding var showAddFeeds: Bool
    @ObservedObject var episodePlayback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var episodeDownloads: EpisodeDownloadStore
    @Binding var showAppSettings: Bool

    @AppStorage("moonmind.feedShowUnplayedOnly") private var showUnplayedOnly = true

    private var displayedEpisodes: [Episode] {
        guard showUnplayedOnly else { return model.episodes }
        return model.episodes.filter { episode in
            if episode.audioURL == nil { return true }
            return !episodePlayback.progressStore.isMarkedPlayed(forEpisodeKey: episode.stableKey)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedFilterBar(feeds: catalog.podcastFeeds, filters: feedFilters) {
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
                    description: Text("Turn on at least one podcast with the filters above.")
                )
            } else if displayedEpisodes.isEmpty {
                ContentUnavailableView(
                    showUnplayedOnly ? "All caught up" : "No episodes",
                    systemImage: "checkmark.circle",
                    description: Text(showUnplayedOnly ? "Every episode from your shows is played, or turn off unplayed-only to see the full feed again." : "")
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
            }
        }
        .navigationTitle("Moonmind")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showUnplayedOnly.toggle()
                } label: {
                    Image(systemName: showUnplayedOnly ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(showUnplayedOnly ? "Show all episodes" : "Show unplayed only")

                Button {
                    showAddFeeds = true
                } label: {
                    Label("Podcasts", systemImage: "plus.square.on.square")
                }

                ProfileSettingsToolbarButton(showSettings: $showAppSettings)
            }
        }
        .navigationDestination(for: Episode.self) { ep in
            EpisodeDetailView(episode: ep, playback: episodePlayback, sleepTimer: sleepTimer, downloads: episodeDownloads)
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
