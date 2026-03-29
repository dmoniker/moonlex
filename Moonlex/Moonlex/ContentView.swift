import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var catalog = FeedCatalog()
    @StateObject private var feedFilters = FeedFilters()
    @StateObject private var home = HomeViewModel()
    @StateObject private var episodePlayback = EpisodePlaybackController()
    @StateObject private var sleepTimer = SleepTimerStore()
    @StateObject private var episodeDownloads = EpisodeDownloadStore()
    @State private var showPodcasts = false

    var body: some View {
        TabView {
            NavigationStack {
                HomeFeedView(
                    catalog: catalog,
                    feedFilters: feedFilters,
                    model: home,
                    showPodcasts: $showPodcasts,
                    episodePlayback: episodePlayback,
                    sleepTimer: sleepTimer,
                    episodeDownloads: episodeDownloads
                )
            }
            .tabItem {
                Label("Feed", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                FavoritesView()
            }
            .tabItem {
                Label("Saved", systemImage: "star.fill")
            }
        }
        .sheet(isPresented: $showPodcasts) {
            NavigationStack {
                AddPodcastView(catalog: catalog, onFeedsChanged: feedsChanged)
            }
        }
        .onAppear {
            episodePlayback.sleepTimerStore = sleepTimer
        }
    }

    private func feedsChanged() {
        Task {
            await home.refresh(feeds: catalog.allFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedItem.self, inMemory: true)
}
