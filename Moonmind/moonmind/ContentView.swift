import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var catalog = FeedCatalog()
    @StateObject private var feedFilters = FeedFilters()
    @StateObject private var home = HomeViewModel()
    @StateObject private var episodePlayback = EpisodePlaybackController()
    @StateObject private var sleepTimer = SleepTimerStore()
    @StateObject private var episodeDownloads = EpisodeDownloadStore()
    @StateObject private var newsletterHome = HomeViewModel()
    @State private var showAddFeeds = false

    var body: some View {
        TabView {
            NavigationStack {
                HomeFeedView(
                    catalog: catalog,
                    feedFilters: feedFilters,
                    model: home,
                    showAddFeeds: $showAddFeeds,
                    episodePlayback: episodePlayback,
                    sleepTimer: sleepTimer,
                    episodeDownloads: episodeDownloads
                )
            }
            .tabItem {
                Label("Feed", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                NewsletterFeedView(
                    catalog: catalog,
                    feedFilters: feedFilters,
                    model: newsletterHome,
                    showAddFeeds: $showAddFeeds,
                    episodePlayback: episodePlayback,
                    sleepTimer: sleepTimer,
                    episodeDownloads: episodeDownloads
                )
            }
            .tabItem {
                Label("Newsletters", systemImage: "newspaper")
            }

            NavigationStack {
                FavoritesView()
            }
            .tabItem {
                Label("Saved", systemImage: "star.fill")
            }
        }
        .sheet(isPresented: $showAddFeeds) {
            NavigationStack {
                AddPodcastView(catalog: catalog, onFeedsChanged: feedsChanged)
            }
        }
        .onAppear {
            episodePlayback.sleepTimerStore = sleepTimer
            episodeDownloads.onDownloadReady = { _, remote, local in
                episodePlayback.migrateStreamToLocalFileIfCurrentlyPlaying(remoteURL: remote, localURL: local)
            }
        }
    }

    private func feedsChanged() {
        Task {
            await home.refresh(feeds: catalog.podcastFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
            await newsletterHome.refresh(feeds: catalog.newsletterFeeds, feedFilters: feedFilters, downloads: nil)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedItem.self, inMemory: true)
}
