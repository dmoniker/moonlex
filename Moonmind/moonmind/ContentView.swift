import CoreData
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// Animation for expanding / collapsing the mini player dock (keep in sync with scroll-triggered chrome in `EpisodeDetailView`).
enum PlayerChromeAnimation {
    static let morph: Animation = .smooth(duration: 0.55, extraBounce: 0.06)
}

// MARK: - Scroll offset ↔ compact chrome (feeds, episode detail)

enum MiniPlayerChromeScrollCoordinator {
    /// Slight hysteresis so small jiggle at the top doesn’t flash chrome.
    private static let expandWhenOffsetBelow: CGFloat = 10
    private static let compactWhenOffsetAbove: CGFloat = 36

    @MainActor
    static func applyContentOffsetY(
        _ y: CGFloat,
        detailChrome: DetailBottomChromeState,
        playback: EpisodePlaybackController
    ) {
        guard playback.loadedMediaURL != nil else {
            detailChrome.shortEpisodeDetailLocksCompactChrome = false
            if detailChrome.isCompact {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = false }
            }
            return
        }
        // Short episode pages: scroll offset jumps during rubber-band; don’t let it fight the locked compact layout.
        if detailChrome.shortEpisodeDetailLocksCompactChrome {
            return
        }
        if y <= expandWhenOffsetBelow {
            if detailChrome.isCompact && !detailChrome.shortEpisodeDetailLocksCompactChrome {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = false }
            }
        } else if y >= compactWhenOffsetAbove {
            if !detailChrome.isCompact {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = true }
            }
        }
    }

    @MainActor
    static func applyGlobalTopAnchorDelta(
        anchor: Binding<CGFloat?>,
        topGlobalY: CGFloat,
        detailChrome: DetailBottomChromeState,
        playback: EpisodePlaybackController
    ) {
        guard playback.loadedMediaURL != nil else {
            anchor.wrappedValue = nil
            detailChrome.shortEpisodeDetailLocksCompactChrome = false
            if detailChrome.isCompact {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = false }
            }
            return
        }
        if anchor.wrappedValue == nil {
            anchor.wrappedValue = topGlobalY
            return
        }
        if detailChrome.shortEpisodeDetailLocksCompactChrome {
            return
        }
        let delta = (anchor.wrappedValue ?? topGlobalY) - topGlobalY
        if delta <= expandWhenOffsetBelow {
            if detailChrome.isCompact && !detailChrome.shortEpisodeDetailLocksCompactChrome {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = false }
            }
        } else if delta >= compactWhenOffsetAbove {
            if !detailChrome.isCompact {
                withAnimation(PlayerChromeAnimation.morph) { detailChrome.isCompact = true }
            }
        }
    }
}

extension View {
    /// For `ScrollView` / `List`: compact bottom chrome after scrolling down; expand again at top. Expects ``DetailBottomChromeState`` via the environment (see `ContentView`).
    /// Pass `scrollOffset` to re-apply rules after navigation (e.g. pop back to root with the list still at offset 0).
    func miniPlayerChromeScrollTracking(
        playback: EpisodePlaybackController,
        scrollOffset: Binding<CGFloat>? = nil
    ) -> some View {
        modifier(MiniPlayerChromeScrollTrackingModifier(playback: playback, scrollOffset: scrollOffset))
    }
}

private struct MiniPlayerChromeScrollTrackingModifier: ViewModifier {
    @EnvironmentObject private var detailChrome: DetailBottomChromeState
    var playback: EpisodePlaybackController
    var scrollOffset: Binding<CGFloat>?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                scrollOffset?.wrappedValue = y
                MiniPlayerChromeScrollCoordinator.applyContentOffsetY(y, detailChrome: detailChrome, playback: playback)
            }
        } else {
            content.overlay(alignment: .topLeading) {
                ListScrollContentOffsetBridge { y in
                    scrollOffset?.wrappedValue = y
                    MiniPlayerChromeScrollCoordinator.applyContentOffsetY(y, detailChrome: detailChrome, playback: playback)
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
    }
}

private final class ScrollOffsetAttachmentView: UIView {
    var onOffset: ((CGFloat) -> Void)?
    private var token: NSKeyValueObservation?

    override func layoutSubviews() {
        super.layoutSubviews()
        bindScrollViewIfNeeded()
    }

    private func bindScrollViewIfNeeded() {
        token?.invalidate()
        token = nil
        var node: UIView? = self
        while let v = node {
            if let s = v as? UIScrollView {
                token = s.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                    self?.onOffset?(scroll.contentOffset.y)
                }
                return
            }
            node = v.superview
        }
    }
}

private struct ListScrollContentOffsetBridge: UIViewRepresentable {
    var onOffset: (CGFloat) -> Void

    func makeUIView(context: Context) -> ScrollOffsetAttachmentView {
        let v = ScrollOffsetAttachmentView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ScrollOffsetAttachmentView, context: Context) {
        uiView.onOffset = onOffset
        uiView.setNeedsLayout()
    }
}

/// Shared by `ContentView` (mini player placement) and scroll surfaces (feed, detail, …).
@MainActor
final class DetailBottomChromeState: ObservableObject {
    /// User scrolled away from the top while something is playing: tab bar hides, feed + mini player share one row in the tab strip.
    @Published var isCompact: Bool = false
    /// Episode detail fits without meaningful vertical scroll; keep compact so show notes aren’t trapped under the stacked mini player + tab bar.
    @Published var shortEpisodeDetailLocksCompactChrome: Bool = false
}

struct ContentView: View {
    private let syncLogger = Logger(subsystem: "com.moonmind.moonmind", category: "CloudSync")
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var catalog = FeedCatalog()
    @StateObject private var feedFilters = FeedFilters()
    @StateObject private var home = HomeViewModel()
    @StateObject private var episodePlayback = EpisodePlaybackController()
    @StateObject private var sleepTimer = SleepTimerStore()
    @StateObject private var episodeDownloads = EpisodeDownloadStore()
    @StateObject private var newsletterHome = HomeViewModel()
    @StateObject private var detailBottomChrome = DetailBottomChromeState()
    @State private var showAddFeeds = false
    @State private var showAppSettings = false
    /// Matches `TabView` tag order: 0 Feed, 1 Newsletters, 2 Saved.
    @State private var selectedTab = 0
    /// Measured from the real `UITabBar` frame (floating pills report a smaller value than `49 + safeArea.bottom`).
    @State private var tabBarTopFromWindowBottom: CGFloat?

    var body: some View {
        ZStack(alignment: .bottom) {
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

                FavoritesView(
                    catalog: catalog,
                    podcastHome: home,
                    newsletterHome: newsletterHome,
                    episodePlayback: episodePlayback,
                    sleepTimer: sleepTimer,
                    episodeDownloads: episodeDownloads,
                    showAppSettings: $showAppSettings
                )
                .tabItem {
                    Label("Saved", systemImage: "star.fill")
                }
                .tag(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Reserve scroll space for the mini player. Do not put the dock in `.overlay` on this view:
            // SwiftUI pins overlays to the bottom of the inset *content* band, leaving a gap the size of this inset.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if episodePlayback.loadedMediaURL != nil {
                    Color.clear.frame(
                        height: detailBottomChrome.isCompact ? compactChromeScrollReservationHeight : Self.miniPlayerContentReservationHeight
                    )
                }
            }

            if episodePlayback.loadedMediaURL != nil {
                MiniPlayerChromeDock(
                    detailChrome: detailBottomChrome,
                    playback: episodePlayback,
                    expandedBottomInset: miniPlayerOverlayBottomInset,
                    tabBarSlotBottomInset: compactDockBottomInset,
                    onOpenFullPlayer: {
                        episodePlayback.openNowPlayingDetail { selectedTab = $0 }
                    },
                    onExpandChrome: {
                        scheduleTabBarGeometryRefresh()
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        // ignoresSafeArea must live on the *outer* ZStack, not on the child dock view.
        // A child's ignoresSafeArea only removes the inset from its own layout; it cannot push
        // the child below the parent ZStack's alignment anchor (window.height − safeAreaInsets.bottom).
        // Placing it here makes the ZStack's bottom = physical screen edge, so the dock and scrim
        // anchor to the true bottom and the home-indicator gap is eliminated.
        .ignoresSafeArea(edges: .bottom)
        .environmentObject(detailBottomChrome)
        .animation(PlayerChromeAnimation.morph, value: detailBottomChrome.isCompact)
        .onChange(of: episodePlayback.loadedMediaURL) { _, newURL in
            if newURL == nil {
                detailBottomChrome.isCompact = false
                detailBottomChrome.shortEpisodeDetailLocksCompactChrome = false
            }
            scheduleTabBarGeometryRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            scheduleTabBarGeometryRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            syncLogger.notice("received NSPersistentStoreRemoteChange")
            applyRemoteStoreMergeAfterCloudKit()
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
            syncLogger.notice("content view appear: attaching sync-backed stores")
            catalog.attach(modelContext: modelContext)
            feedFilters.attach(modelContext: modelContext)
            episodePlayback.progressStore.attach(modelContext: modelContext)
            logCloudSnapshot(reason: "content onAppear attach")
            scheduleTabBarGeometryRefresh()
            episodePlayback.sleepTimerStore = sleepTimer
            episodePlayback.downloadStore = episodeDownloads
            episodePlayback.feedHomeModel = home
            episodePlayback.feedNewsletterModel = newsletterHome
            episodeDownloads.onDownloadReady = { _, remote, local in
                episodePlayback.migrateStreamToLocalFileIfCurrentlyPlaying(remoteURL: remote, localURL: local)
            }
            episodeDownloads.reapplyRetentionUsingLastFeedCache()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                syncLogger.notice("content view delayed cloud merge firing")
                applyRemoteStoreMergeAfterCloudKit()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                syncLogger.notice("scene phase -> background: flushing playback progress")
                episodePlayback.flushListeningProgressToStore()
                try? modelContext.save()
                logCloudSnapshot(reason: "scene background save")
            }
            if phase == .active {
                syncLogger.notice("scene phase -> active: applying cloud merge")
                applyRemoteStoreMergeAfterCloudKit()
            }
        }
    }

    /// Re-reads SwiftData after CloudKit merges (`NSPersistentStoreRemoteChange` or returning to the app).
    private func applyRemoteStoreMergeAfterCloudKit() {
        syncLogger.notice("applyRemoteStoreMergeAfterCloudKit begin")
        catalog.refreshFromCloudKitImport(modelContext: modelContext)
        feedFilters.refreshFromCloudKitImport(modelContext: modelContext)
        episodePlayback.progressStore.refreshFromCloudKitImport(modelContext: modelContext)
        episodeDownloads.reapplyRetentionUsingLastFeedCache()
        logCloudSnapshot(reason: "applyRemoteStoreMergeAfterCloudKit end")
    }

    private func logCloudSnapshot(reason: String) {
        let favoritesFD = FetchDescriptor<SavedItem>(predicate: #Predicate { $0.excerpt == "" })
        let favorites = (try? modelContext.fetchCount(favoritesFD)) ?? -1
        let progress = (try? modelContext.fetchCount(FetchDescriptor<PlaybackProgressRecord>())) ?? -1
        let prefs = (try? modelContext.fetchCount(FetchDescriptor<SyncedAppPreferences>())) ?? -1
        let customFeeds = (try? modelContext.fetchCount(FetchDescriptor<UserCustomFeed>())) ?? -1
        let hiddenFeeds = (try? modelContext.fetchCount(FetchDescriptor<HiddenBuiltinFeedRecord>())) ?? -1
        let prefRow = (try? modelContext.fetch(FetchDescriptor<SyncedAppPreferences>()))?.first
        syncLogger.notice(
            """
            content snapshot[\(reason, privacy: .public)] favorites=\(favorites) progress=\(progress) prefs=\(prefs) customFeeds=\(customFeeds) hiddenBuiltinFeeds=\(hiddenFeeds) prefID=\(prefRow?.id ?? "nil", privacy: .public) prefUpdatedAt=\(String(describing: prefRow?.updatedAt), privacy: .public)
            """
        )
    }

    private var miniPlayerOverlayBottomInset: CGFloat {
        let tabTop = tabBarTopFromWindowBottom ?? MiniPlayerTabBarLayout.estimatedFallbackTopFromBottom()
        // Sits just above the tab bar: small breathing room only.
        return tabTop + Self.miniPlayerGapAboveTabBar
    }

    /// Compact row fills the tab bar slot: bottom sits just inside the home-indicator zone, top at the pill top.
    /// Derived from the pill TOP (stable measurement) minus the target row height — avoids the iOS 18 floating-pill
    /// issue where `tabBarBottomFromWindowBottom` returns ~34 pt because the bar no longer fills the home-indicator zone.
    private var compactDockBottomInset: CGFloat {
        let tabTop = tabBarTopFromWindowBottom ?? MiniPlayerTabBarLayout.estimatedFallbackTopFromBottom()
        // Pull the combined row toward the home indicator; stacked (expanded) chrome uses `miniPlayerOverlayBottomInset` only.
        return max(0, tabTop - Self.miniPlayerCompactRowHeight - Self.compactDockLowerByPoints)
    }

    /// Clears scrollable content for the compact mini-player row.
    ///
    /// The outer ZStack anchors to the physical screen edge, so the row's bottom is
    /// `compactDockBottomInset` pts from that edge and its top is `compactDockBottomInset +
    /// miniPlayerCompactRowHeight` pts from that edge.  The system safe-area (home indicator)
    /// already reserves `safeAreaInsets.bottom` pts at the very bottom, so the `safeAreaInset`
    /// on the TabView only needs to cover the row's portion that sits *above* that boundary,
    /// plus a small gap.
    private var compactChromeScrollReservationHeight: CGFloat {
        let home = MiniPlayerTabBarLayout.keyWindowSafeAreaBottomInset
        let rowTopFromPhysical = compactDockBottomInset + Self.miniPlayerCompactRowHeight
        // Only the part above the safe-area boundary needs an explicit reservation.
        return max(4, rowTopFromPhysical - home + 4)
    }

    private func scheduleTabBarGeometryRefresh() {
        let update = {
            if let top = MiniPlayerTabBarLayout.measureTabBarTopFromWindowBottom() {
                tabBarTopFromWindowBottom = top
            }
        }
        update()
        DispatchQueue.main.async(execute: update)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: update)
    }

    /// Gap between the mini player’s bottom and the top edge of the tab bar.
    private static let miniPlayerGapAboveTabBar: CGFloat = 4

    /// Matches the capsule height plus a little slack so `safeAreaInset` matches the overlay.
    private static let miniPlayerContentReservationHeight: CGFloat = 56

    /// Height of the compact HStack: the feed-chip circle (50 pt) is the tallest element; add a 2-pt safety margin.
    private static let miniPlayerCompactRowHeight: CGFloat = 52
    /// Nudge the compact feed + mini-player row closer to the physical bottom (does not affect stacked layout).
    private static let compactDockLowerByPoints: CGFloat = 20


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
        // Use the measured top directly. Replacing values near “classic” height with a synthetic
        // `home + …` estimate was wrong both ways (too low → overlap; too high → large gaps).
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

    /// Bias was used when the outer ZStack anchored to the safe-area bottom (818); with the ZStack
    /// now anchored to the physical edge (852) the measurement is already exact, so no nudge needed.
    private static let miniPlayerMeasureLowerBias: CGFloat = 0

    /// When UIKit hasn’t published a tab bar yet (or hierarchy differs).
    static func estimatedFallbackTopFromBottom() -> CGFloat {
        guard let window = keyWindow else { return 83 }
        return classicTabStackHeight(window: window)
    }

    /// Distance from the window’s bottom edge to the tab chrome’s **bottom** (floating pill or bar), matching the stock tab strip.
    static func measureTabBarBottomFromWindowBottom() -> CGFloat? {
        guard let window = keyWindow else { return nil }
        let tabBar = tabBarController(from: window.rootViewController)?.tabBar
            ?? findTabBarRecursively(in: window)
        guard let tabBar, !tabBar.isHidden, tabBar.alpha > 0.01, tabBar.superview != nil else {
            return nil
        }
        let chromeBottomMaxY = visualTabChromeBottomMaxY(tabBar: tabBar, in: window)
        let gapBelowChrome = window.bounds.height - chromeBottomMaxY
        guard gapBelowChrome.isFinite, gapBelowChrome > -8, gapBelowChrome < 160 else { return nil }
        return max(0, gapBelowChrome)
    }

    /// Lowest screen Y (window coords) belonging to prominent tab chrome (pill or full bar).
    private static func visualTabChromeBottomMaxY(tabBar: UITabBar, in window: UIWindow) -> CGFloat {
        let barFrame = tabBar.convert(tabBar.bounds, to: window)
        var chromeBottomMaxY = barFrame.maxY
        for sub in tabBar.subviews {
            guard !sub.isHidden, sub.alpha > 0.02 else { continue }
            let f = sub.convert(sub.bounds, to: window)
            guard f.height >= 26, f.width >= 72 else { continue }
            chromeBottomMaxY = max(chromeBottomMaxY, f.maxY)
        }
        return chromeBottomMaxY
    }

    /// Fallback when the bar is hidden or not yet in the hierarchy; mirrors the pill-on-home‑indicator layout.
    static func estimatedTabBarBottomFromWindowBottom() -> CGFloat {
        guard let window = keyWindow else { return 0 }
        let topFromBottom = classicTabStackHeight(window: window)
        let home = window.safeAreaInsets.bottom
        let barHeightGuess: CGFloat = (home > 0 && home < 40) ? max(48, topFromBottom * 0.55) : 50
        return max(0, topFromBottom - barHeightGuess)
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
    }

    static var keyWindowSafeAreaBottomInset: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
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

// MARK: - Mini player dock (one surface; morphs between tab-bar “floating” and bottom-edge single line)

/// Dark fade behind the floating chrome — closer to Apple Podcasts than a bare overlay on the list.
private struct MiniPlayerBottomScrim: View {
    @Environment(\.colorScheme) private var colorScheme
    var bottomInset: CGFloat
    var isCompact: Bool

    private var rowHeight: CGFloat { isCompact ? 56 : 60 }

    /// Vertical extent of the gradient above the controls (fades into scroll content).
    private var fadeExtentAboveRow: CGFloat { isCompact ? 108 : 128 }

    var body: some View {
        let h = bottomInset + rowHeight + fadeExtentAboveRow
        let deep = colorScheme == .dark ? 0.72 : 0.42
        let mid = colorScheme == .dark ? 0.38 : 0.22

        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.black.opacity(mid * 0.35), location: 0.28),
                .init(color: Color.black.opacity(mid), location: 0.62),
                .init(color: Color.black.opacity(deep), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: h)
        .frame(maxWidth: .infinity)
    }
}

private struct MiniPlayerChromeDock: View {
    @ObservedObject var detailChrome: DetailBottomChromeState
    @ObservedObject var playback: EpisodePlaybackController
    var expandedBottomInset: CGFloat
    /// Same inset the real `UITabBar` uses from the window bottom (cached while visible).
    var tabBarSlotBottomInset: CGFloat
    var onOpenFullPlayer: () -> Void
    var onExpandChrome: () -> Void

    private var isCompact: Bool { detailChrome.isCompact }

    private var dockBottomPadding: CGFloat {
        isCompact ? tabBarSlotBottomInset : expandedBottomInset
    }

    private let feedChromeSize: CGFloat = 50

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim only in compact mode; in expanded mode the capsule floats cleanly above the tab bar.
            if isCompact {
                MiniPlayerBottomScrim(bottomInset: dockBottomPadding, isCompact: isCompact)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            HStack(alignment: .center, spacing: isCompact ? 10 : 0) {
                expandTabBarButton
                    .frame(width: isCompact ? feedChromeSize : 0, alignment: .leading)
                    .opacity(isCompact ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(isCompact)

                MiniPlayerBar(compact: isCompact, playback: playback, onOpenFullPlayer: onOpenFullPlayer)
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, isCompact ? 14 : 20)
            .padding(.trailing, isCompact ? 12 : 20)
            .padding(.bottom, dockBottomPadding)
        }
    }

    private var expandTabBarButton: some View {
        Button {
            withAnimation(PlayerChromeAnimation.morph) {
                detailChrome.isCompact = false
            }
            onExpandChrome()
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: feedChromeSize, height: feedChromeSize)
                .background {
                    Circle()
                        .fill(.bar)
                        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show tab bar")
    }
}

// MARK: - Mini player (kept in this file so it always compiles with the app target)

/// Capsule above the tab bar (expanded) or tighter single-line strip (compact); same controls, animated sizes.
private struct MiniPlayerBar: View {
    var compact: Bool = false
    @ObservedObject var playback: EpisodePlaybackController
    var onOpenFullPlayer: () -> Void

    private var artworkSize: CGFloat { compact ? 28 : 36 }
    private var innerSpacing: CGFloat { compact ? 8 : 10 }
    private var playIconPointSize: CGFloat { compact ? 14 : 17 }
    private var playTapSize: CGFloat { compact ? 32 : 36 }

    var body: some View {
        let meta = playback.nowPlayingMetadata
        let artworkCorner = artworkSize * 0.22
        HStack(spacing: innerSpacing) {
            Button(action: onOpenFullPlayer) {
                HStack(spacing: innerSpacing) {
                    PodcastArtworkView(
                        url: meta?.artworkURL,
                        size: artworkSize,
                        cornerRadius: artworkCorner
                    )

                    VStack(alignment: .leading, spacing: compact ? 0 : 1) {
                        Text(meta?.title ?? "Episode")
                            .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .contentTransition(.interpolate)
                        Text(meta?.showTitle ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(compact ? 0 : 1)
                            .frame(height: compact ? 0 : nil, alignment: .top)
                            .clipped()
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
                    .font(.system(size: playIconPointSize, weight: .semibold))
                    .frame(width: playTapSize, height: playTapSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        }
        .padding(.leading, compact ? 8 : 10)
        .padding(.trailing, compact ? 6 : 8)
        .padding(.vertical, compact ? 5 : 7)
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
