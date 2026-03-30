import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var catalog = FeedCatalog()
    @StateObject private var feedFilters = FeedFilters()
    @StateObject private var home = HomeViewModel()
    @StateObject private var episodePlayback = EpisodePlaybackController()
    @StateObject private var sleepTimer = SleepTimerStore()
    @StateObject private var episodeDownloads = EpisodeDownloadStore()
    @StateObject private var newsletterHome = HomeViewModel()
    @State private var showAddFeeds = false
    @State private var showAppSettings = false
    /// Matches `TabView` tag order: 0 Feed, 1 Newsletters, 2 Saved.
    @State private var selectedTab = 0
    /// Measured from the real `UITabBar` frame (floating pills report a smaller value than `49 + safeArea.bottom`).
    @State private var tabBarTopFromWindowBottom: CGFloat?

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeFeedView(
                catalog: catalog,
                feedFilters: feedFilters,
                model: home,
                showAddFeeds: $showAddFeeds,
                episodePlayback: episodePlayback,
                sleepTimer: sleepTimer,
                episodeDownloads: episodeDownloads,
                showAppSettings: $showAppSettings
            )
            .tabItem {
                Label("Feed", systemImage: "list.bullet.rectangle")
            }
            .tag(0)

            NewsletterFeedView(
                catalog: catalog,
                feedFilters: feedFilters,
                model: newsletterHome,
                showAddFeeds: $showAddFeeds,
                episodePlayback: episodePlayback,
                sleepTimer: sleepTimer,
                episodeDownloads: episodeDownloads,
                showAppSettings: $showAppSettings
            )
            .tabItem {
                Label("Newsletters", systemImage: "newspaper")
            }
            .tag(1)

            NavigationStack {
                FavoritesView(showAppSettings: $showAppSettings)
            }
            .tabItem {
                Label("Saved", systemImage: "star.fill")
            }
            .tag(2)
        }
        // Invisible reserve so lists don’t scroll under the overlay (see mini player in `.overlay`).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if episodePlayback.loadedMediaURL != nil {
                Color.clear.frame(height: Self.miniPlayerContentReservationHeight)
            }
        }
        .overlay(alignment: .bottom) {
            if episodePlayback.loadedMediaURL != nil {
                MiniPlayerBar(playback: episodePlayback) {
                    episodePlayback.openNowPlayingDetail { selectedTab = $0 }
                }
                    .padding(.horizontal, 20)
                    .padding(.bottom, miniPlayerOverlayBottomInset)
                    // TabView can inset the overlay; pin padding to the display bottom so we clear the tab bar.
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .onChange(of: episodePlayback.loadedMediaURL) { _, _ in
            scheduleTabBarGeometryRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            scheduleTabBarGeometryRefresh()
        }
        .sheet(isPresented: $showAddFeeds) {
            NavigationStack {
                AddPodcastView(catalog: catalog, downloads: episodeDownloads, onFeedsChanged: feedsChanged)
            }
        }
        .sheet(isPresented: $showAppSettings) {
            AppSettingsSheetView(
                playback: episodePlayback,
                downloads: episodeDownloads,
                catalog: catalog,
                onFeedsReset: feedsChanged
            )
        }
        .onAppear {
            scheduleTabBarGeometryRefresh()
            episodePlayback.sleepTimerStore = sleepTimer
            episodePlayback.downloadStore = episodeDownloads
            episodePlayback.feedHomeModel = home
            episodePlayback.feedNewsletterModel = newsletterHome
            episodeDownloads.onDownloadReady = { _, remote, local in
                episodePlayback.migrateStreamToLocalFileIfCurrentlyPlaying(remoteURL: remote, localURL: local)
            }
        }
    }

    private var miniPlayerOverlayBottomInset: CGFloat {
        let tabTop = tabBarTopFromWindowBottom ?? MiniPlayerTabBarLayout.estimatedFallbackTopFromBottom()
        // Sits just above the tab bar: small breathing room only.
        return tabTop + Self.miniPlayerGapAboveTabBar
    }

    private func scheduleTabBarGeometryRefresh() {
        let update = {
            tabBarTopFromWindowBottom = MiniPlayerTabBarLayout.measureTabBarTopFromWindowBottom()
        }
        update()
        DispatchQueue.main.async(execute: update)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: update)
    }

    /// Gap between the mini player’s bottom and the top edge of the tab bar.
    private static let miniPlayerGapAboveTabBar: CGFloat = 4

    /// Matches the capsule height plus a little slack so `safeAreaInset` matches the overlay.
    private static let miniPlayerContentReservationHeight: CGFloat = 56

    private func feedsChanged() {
        home.applyFilterInstantly(feeds: catalog.podcastFeeds, feedFilters: feedFilters)
        newsletterHome.applyFilterInstantly(feeds: catalog.newsletterFeeds, feedFilters: feedFilters)
        Task {
            await home.refresh(feeds: catalog.podcastFeeds, feedFilters: feedFilters, downloads: episodeDownloads)
            await newsletterHome.refresh(feeds: catalog.newsletterFeeds, feedFilters: feedFilters, downloads: nil)
        }
    }
}

// MARK: - Tab bar frame (UIKit) for mini player vertical position

private enum MiniPlayerTabBarLayout {
    /// Distance from the window’s bottom edge to the top of the **visible** tab chrome (floating pill vs full `UITabBar` bounds).
    static func measureTabBarTopFromWindowBottom() -> CGFloat? {
        guard let window = keyWindow else { return nil }
        let tabBar = tabBarController(from: window.rootViewController)?.tabBar
            ?? findTabBarRecursively(in: window)
        guard let tabBar, !tabBar.isHidden, tabBar.alpha > 0.01, tabBar.superview != nil else {
            return nil
        }
        let visualTopMinY = visualTabTopMinY(tabBar: tabBar, in: window)
        let fromBottom = window.bounds.height - visualTopMinY
        guard fromBottom.isFinite, fromBottom > 20, fromBottom < window.bounds.height * 0.5 else {
            return nil
        }
        let classic = classicTabStackHeight(window: window)
        // Full-bar `UITabBar` bounds match the old 49+safe math; the real pill sits higher — prefer compact estimate.
        if abs(fromBottom - classic) < 6 {
            return compactFloatingTabTopFromBottom(window: window)
        }
        // Smaller value = mini player sits lower; stay above a small floor so we don’t cover the tab bar.
        let home = window.safeAreaInsets.bottom
        let lowered = fromBottom - miniPlayerMeasureLowerBias
        let floor = max(44, home + 18)
        return max(floor, lowered)
    }

    /// Topmost Y (window coords) of the tab UI: min of bar bounds and prominent subviews (the actual floating pill).
    private static func visualTabTopMinY(tabBar: UITabBar, in window: UIWindow) -> CGFloat {
        var minY = tabBar.convert(tabBar.bounds, to: window).minY
        for sub in tabBar.subviews {
            guard !sub.isHidden, sub.alpha > 0.02 else { continue }
            let f = sub.convert(sub.bounds, to: window)
            guard f.height >= 26, f.width >= 72 else { continue }
            minY = min(minY, f.minY)
        }
        return minY
    }

    private static func classicTabStackHeight(window: UIWindow) -> CGFloat {
        let home = window.safeAreaInsets.bottom
        if home > 48 { return home }
        return 49 + home
    }

    /// Nudge measured height down (smaller = mini player floats lower, closer to tab bar).
    private static let miniPlayerMeasureLowerBias: CGFloat = 10

    /// Matches common floating / pill tab bars that don’t fill the legacy 49+home strip.
    private static func compactFloatingTabTopFromBottom(window: UIWindow) -> CGFloat {
        let home = window.safeAreaInsets.bottom
        if home > 48 { return home }
        if home < 12 { return 49 + home }
        // `home + pillEstimate`: smaller estimate = tab “top” closer to screen bottom = mini player lower.
        let pillEstimate: CGFloat = 26
        return max(49, min(49 + home, home + pillEstimate))
    }

    /// When UIKit hasn’t published a tab bar yet (or hierarchy differs).
    static func estimatedFallbackTopFromBottom() -> CGFloat {
        guard let window = keyWindow else { return max(49, min(83, 34 + 26)) }
        return compactFloatingTabTopFromBottom(window: window)
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
    }

    private static func tabBarController(from root: UIViewController?) -> UITabBarController? {
        var queue: [UIViewController] = []
        if let root { queue.append(root) }
        var index = 0
        while index < queue.count {
            let vc = queue[index]
            index += 1
            if let tab = vc as? UITabBarController { return tab }
            queue.append(contentsOf: vc.children)
            if let nav = vc as? UINavigationController {
                queue.append(contentsOf: nav.viewControllers)
            }
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    private static func findTabBarRecursively(in window: UIWindow) -> UITabBar? {
        guard let view = window.rootViewController?.view else { return nil }
        return findTabBarRecursively(in: view)
    }

    private static func findTabBarRecursively(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for sub in view.subviews {
            if let bar = findTabBarRecursively(in: sub) { return bar }
        }
        return nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedItem.self, inMemory: true)
}

// MARK: - Mini player (kept in this file so it always compiles with the app target)

/// Compact capsule above the tab bar; visuals aligned with the tab bar’s rounded, material chrome.
private struct MiniPlayerBar: View {
    @ObservedObject var playback: EpisodePlaybackController
    var onOpenFullPlayer: () -> Void

    private let artworkSize: CGFloat = 36

    var body: some View {
        let meta = playback.nowPlayingMetadata
        HStack(spacing: 10) {
            Button(action: onOpenFullPlayer) {
                HStack(spacing: 10) {
                    PodcastArtworkView(
                        url: meta?.artworkURL,
                        size: artworkSize,
                        cornerRadius: artworkSize * 0.22
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(meta?.title ?? "Episode")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(meta?.showTitle ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing, show episode")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(.bar)
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}
