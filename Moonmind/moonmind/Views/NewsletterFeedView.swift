import SwiftUI

struct NewsletterFeedView: View {
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var feedFilters: FeedFilters
    @ObservedObject var model: HomeViewModel
    @Binding var showAddFeeds: Bool
    @ObservedObject var episodePlayback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var episodeDownloads: EpisodeDownloadStore
    @Binding var showAppSettings: Bool

    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            newsletterFeedContents
                .navigationDestination(for: Episode.self) { ep in
                    EpisodeDetailView(
                        episode: ep,
                        playback: episodePlayback,
                        progressStore: episodePlayback.progressStore,
                        sleepTimer: sleepTimer,
                        downloads: episodeDownloads
                    )
                }
        }
        .onChange(of: episodePlayback.autoplayDetailNavigation) { _, request in
            guard let request, request.feed == .newsletter else { return }
            if !navigationPath.isEmpty {
                navigationPath.removeLast()
            }
            navigationPath.append(request.episode)
            episodePlayback.consumeAutoplayDetailNavigation()
        }
    }

    @ViewBuilder
    private var newsletterFeedContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedFilterBar(feeds: catalog.newsletterFeeds, scope: .newsletter, filters: feedFilters) {
                model.applyFilterInstantly(feeds: catalog.newsletterFeeds, feedFilters: feedFilters)
                Task {
                    await model.refresh(
                        feeds: catalog.newsletterFeeds,
                        feedFilters: feedFilters,
                        downloads: nil
                    )
                }
            }
            .padding(.horizontal)

            if model.isLoading && model.episodes.isEmpty {
                ProgressView("Loading posts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.lastError, model.episodes.isEmpty {
                ContentUnavailableView(
                    "Could not load newsletters",
                    systemImage: "wifi.exclamationmark",
                    description: Text(err)
                )
            } else if model.episodes.isEmpty {
                ContentUnavailableView(
                    "No newsletters selected",
                    systemImage: "newspaper",
                    description: Text("Choose All or a feed above, or add a Substack RSS URL.")
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
                                NewsletterPostRow(episode: ep)
                            }
                            .contextMenu {
                                if ep.audioURL != nil,
                                   episodePlayback.progressStore.isMarkedPlayed(forEpisodeKey: ep.stableKey) {
                                    Button {
                                        episodePlayback.markEpisodeUnplayed(episodeKey: ep.stableKey)
                                    } label: {
                                        Label("Mark as Unplayed", systemImage: "arrow.uturn.backward.circle")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Newsletters")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showAddFeeds = true
                } label: {
                    Label("Feeds", systemImage: "plus.square.on.square")
                }
                SettingsToolbarButton(showSettings: $showAppSettings)
            }
        }
        .task {
            await model.refresh(feeds: catalog.newsletterFeeds, feedFilters: feedFilters, downloads: nil)
        }
        .refreshable {
            await model.refresh(feeds: catalog.newsletterFeeds, feedFilters: feedFilters, downloads: nil)
        }
    }
}

private struct NewsletterPostRow: View {
    let episode: Episode

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
        }
        .padding(.vertical, 4)
    }
}
