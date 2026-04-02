import SwiftUI
import SwiftData

struct FavoritesView: View {
    @EnvironmentObject private var detailBottomChrome: DetailBottomChromeState
    @Query(
        filter: #Predicate<SavedItem> { $0.excerpt == "" },
        sort: \SavedItem.createdAt,
        order: .reverse
    )
    private var items: [SavedItem]

    @Environment(\.modelContext) private var modelContext
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var podcastHome: HomeViewModel
    @ObservedObject var newsletterHome: HomeViewModel
    @ObservedObject var episodePlayback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var episodeDownloads: EpisodeDownloadStore
    @Binding var showAppSettings: Bool

    @State private var navigationPath = NavigationPath()
    @State private var favoritesListScrollY: CGFloat = 0

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet",
                        systemImage: "star",
                        description: Text("Favorite an episode to see it here.")
                    )
                } else {
                    List {
                        Section("Favorites") {
                            ForEach(items) { item in
                                Button {
                                    openSavedItem(item)
                                } label: {
                                    savedRow(item)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: delete)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .miniPlayerChromeScrollTracking(playback: episodePlayback, scrollOffset: $favoritesListScrollY)
                }
            }
            .navigationTitle("Saved")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SettingsToolbarButton(showSettings: $showAppSettings)
                }
            }
            .navigationDestination(for: Episode.self) { episode in
                EpisodeDetailView(
                    episode: episode,
                    playback: episodePlayback,
                    progressStore: episodePlayback.progressStore,
                    sleepTimer: sleepTimer,
                    downloads: episodeDownloads
                )
            }
        }
        .onChange(of: navigationPath.count) { _, _ in
            if navigationPath.isEmpty {
                MiniPlayerChromeScrollCoordinator.applyContentOffsetY(
                    favoritesListScrollY,
                    detailChrome: detailBottomChrome,
                    playback: episodePlayback
                )
            }
        }
        .toolbar(detailBottomChrome.isCompact ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            episodePlayback.sleepTimerStore = sleepTimer
        }
    }

    @ViewBuilder
    private func savedRow(_ item: SavedItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.showTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Episode", systemImage: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Text(item.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
            if let d = item.episodePubDate {
                Text(d.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func contentKind(forFeedID id: String) -> FeedContentKind {
        if catalog.newsletterFeeds.contains(where: { $0.id == id }) {
            return .newsletter
        }
        return .podcast
    }

    private func episode(for item: SavedItem) -> Episode {
        if let ep = podcastHome.episodes.first(where: { $0.stableKey == item.episodeKey }) {
            return ep
        }
        if let ep = newsletterHome.episodes.first(where: { $0.stableKey == item.episodeKey }) {
            return ep
        }
        return Episode(savedItem: item, contentKind: contentKind(forFeedID: item.feedID))
    }

    private func openSavedItem(_ item: SavedItem) {
        let ep = episode(for: item)
        _ = episodePlayback.startPlayback(episode: ep, downloads: episodeDownloads)
        navigationPath.append(ep)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(items[i])
        }
        try? modelContext.save()
    }
}
