import SwiftUI

struct HomeFeedView: View {
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var feedFilters: FeedFilters
    @ObservedObject var model: HomeViewModel
    @Binding var showPodcasts: Bool
    @ObservedObject var episodePlayback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var episodeDownloads: EpisodeDownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedFilterBar(feeds: catalog.allFeeds, filters: feedFilters) {
                Task { await model.refresh(feeds: catalog.allFeeds, feedFilters: feedFilters, downloads: episodeDownloads) }
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
                        ForEach(model.episodes) { ep in
                            NavigationLink(value: ep) {
                                EpisodeRow(episode: ep, downloads: episodeDownloads)
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
        .navigationTitle("Moonlex")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPodcasts = true
                } label: {
                    Label("Podcasts", systemImage: "plus.square.on.square")
                }
            }
        }
        .navigationDestination(for: Episode.self) { ep in
            EpisodeDetailView(episode: ep, playback: episodePlayback, sleepTimer: sleepTimer, downloads: episodeDownloads)
        }
        .task {
            await model.refresh(feeds: catalog.allFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
        }
        .refreshable {
            await model.refresh(feeds: catalog.allFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    @ObservedObject var downloads: EpisodeDownloadStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
