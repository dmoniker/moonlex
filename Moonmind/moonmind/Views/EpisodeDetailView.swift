import SwiftData
import SwiftUI

private struct EpisodeDetailScrollTopGlobalYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct EpisodeDetailScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = max(value, n) }
    }
}

private struct EpisodeDetailScrollViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var detailBottomChrome: DetailBottomChromeState
    @Query private var saved: [SavedItem]

    let episode: Episode
    let playback: EpisodePlaybackController
    /// Observed separately from `playback` so high‑frequency `currentTime` ticks do not rebuild the detail shell (e.g. sleep timer menu).
    @ObservedObject var progressStore: EpisodePlaybackProgressStore
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var downloads: EpisodeDownloadStore

    @State private var toast: String?
    @State private var newsletterAttributedBody: NSAttributedString?

    private var existingFavorite: SavedItem? {
        saved.first { $0.episodeKey == episode.stableKey && $0.isEpisodeFavorite }
    }

    private var episodePlaybackURL: URL? { downloads.playbackURL(for: episode) }

    private var episodeNowPlayingMeta: EpisodeNowPlayingMetadata {
        EpisodeNowPlayingMetadata(
            title: episode.title,
            showTitle: episode.showTitle,
            artworkURL: episode.artworkURL
        )
    }

    @State private var detailScrollAnchorGlobalY: CGFloat?
    @State private var episodeDetailScrollContentHeight: CGFloat = 0
    @State private var episodeDetailScrollViewportHeight: CGFloat = 0

    var body: some View {
        episodeDetailScrollView
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(detailBottomChrome.isCompact ? .hidden : .automatic, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if episode.audioURL != nil {
                        if progressStore.isMarkedPlayed(forEpisodeKey: episode.stableKey) {
                            Button {
                                playback.markEpisodeUnplayed(episodeKey: episode.stableKey)
                                flash("Marked as unplayed")
                            } label: {
                                Label("Mark as Unplayed", systemImage: "arrow.uturn.backward.circle")
                            }
                        } else {
                            Button {
                                playback.markEpisodePlayed(episodeKey: episode.stableKey)
                                flash("Marked as played")
                            } label: {
                                Label("Mark as Played", systemImage: "checkmark.circle")
                            }
                        }
                    }
                    if existingFavorite != nil {
                        Label("Favorited", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    } else {
                        Button {
                            saveFavorite()
                        } label: {
                            Label("Favorite episode", systemImage: "star")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.subheadline.weight(.semibold))
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: toast)
            .task(id: episode.stableKey) {
                detailScrollAnchorGlobalY = nil
                episodeDetailScrollContentHeight = 0
                episodeDetailScrollViewportHeight = 0
                detailBottomChrome.shortEpisodeDetailLocksCompactChrome = false
                // Episode detail always defaults to compact: tab bar hides immediately, giving
                // the full screen to content. The user can restore the tab bar via the feed-icon
                // button; short-page reconciliation below may also reinforce the lock.
                if playback.loadedMediaURL != nil {
                    withAnimation(PlayerChromeAnimation.morph) {
                        detailBottomChrome.isCompact = true
                    }
                }
                playback.sleepTimerStore = sleepTimer
                applyPlaybackSource()
                if episode.feedContentKind == .newsletter {
                    newsletterAttributedBody = episode.descriptionRaw.attributedArticleFromHTML()
                } else {
                    newsletterAttributedBody = nil
                }
            }
            .onChange(of: newsletterAttributedBody?.length) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    reconcileShortEpisodeDetailChrome()
                }
            }
            .onChange(of: downloads.changeToken) { _, _ in
                applyPlaybackSource()
            }
            .onChange(of: episodeDetailScrollContentHeight) { _, _ in
                reconcileShortEpisodeDetailChrome()
            }
            .onChange(of: episodeDetailScrollViewportHeight) { _, _ in
                reconcileShortEpisodeDetailChrome()
            }
            .onChange(of: detailBottomChrome.isCompact) { _, compact in
                guard !compact,
                      detailBottomChrome.shortEpisodeDetailLocksCompactChrome,
                      playback.loadedMediaURL != nil else { return }
                // Short pages can’t scroll enough to earn compact mode; expanding covers the bottom — snap back.
                DispatchQueue.main.async {
                    withAnimation(PlayerChromeAnimation.morph) {
                        detailBottomChrome.isCompact = true
                    }
                }
            }
            .onDisappear {
                detailBottomChrome.shortEpisodeDetailLocksCompactChrome = false
            }
    }

    @ViewBuilder
    private var episodeDetailScrollView: some View {
        // No scroll-offset tracking here: the detail defaults to compact on load (see task above).
        // Scroll position on the detail page does not flip chrome modes — the feed-list coordinator
        // re-applies the correct state when the user navigates back.
        scrollViewCore
    }

    /// ScrollView + height probes (short pages never scroll enough to trigger compact via offset alone).
    private var scrollViewCore: some View {
        ScrollView {
            episodeDetailScrollContent
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: EpisodeDetailScrollContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: EpisodeDetailScrollViewportHeightKey.self,
                    value: geo.size.height
                )
            }
        )
        .onPreferenceChange(EpisodeDetailScrollContentHeightKey.self) { episodeDetailScrollContentHeight = $0 }
        .onPreferenceChange(EpisodeDetailScrollViewportHeightKey.self) { episodeDetailScrollViewportHeight = $0 }
        .onAppear {
            // Fire as soon as the first layout pass is done; the guard inside bails if heights are still 0.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                reconcileShortEpisodeDetailChrome()
            }
        }
    }

    private var episodeDetailScrollContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.clear
                .frame(height: 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: EpisodeDetailScrollTopGlobalYKey.self,
                            value: geo.frame(in: .global).minY
                        )
                    }
                )
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.showTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(episode.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let d = episode.pubDate {
                        Text(d.formatted(date: .long, time: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if episode.audioURL != nil {
                    EpisodeDownloadAccessory(episode: episode, downloads: downloads, interactive: true)
                }
            }

            if episode.audioURL != nil {
                EpisodeDetailPlayerCard(
                    episode: episode,
                    playback: playback,
                    sleepTimer: sleepTimer,
                    downloads: downloads
                )
            } else if episode.feedContentKind == .newsletter, let url = episode.linkURL {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI voiceover and full layout are on Substack; this feed only includes the article text in RSS.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link(destination: url) {
                        Label("Open on Substack", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Label("No audio enclosure in this feed item", systemImage: "waveform.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !episode.descriptionPlain.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(episode.feedContentKind == .newsletter ? "Article" : "Show notes")
                        .font(.headline)
                    if let attr = newsletterAttributedBody, attr.length > 0 {
                        Text(AttributedString(attr))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(episode.descriptionPlain)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When show notes fit in one screen, scroll offset never crosses the compact threshold — force compact while playing.
    private func reconcileShortEpisodeDetailChrome() {
        guard playback.loadedMediaURL != nil else {
            detailBottomChrome.shortEpisodeDetailLocksCompactChrome = false
            return
        }
        guard episodeDetailScrollViewportHeight > 100,
              episodeDetailScrollViewportHeight < 8000,
              episodeDetailScrollContentHeight > 0 else { return }

        // Hysteresis: rubber-band / layout can briefly make “content taller than viewport”; don’t drop the lock in the fuzzy band.
        let enterShortSlack: CGFloat = 32
        let exitShortSlack: CGFloat = 76
        let ch = episodeDetailScrollContentHeight
        let vh = episodeDetailScrollViewportHeight

        if ch <= vh + enterShortSlack {
            detailBottomChrome.shortEpisodeDetailLocksCompactChrome = true
            if !detailBottomChrome.isCompact {
                withAnimation(PlayerChromeAnimation.morph) {
                    detailBottomChrome.isCompact = true
                }
            }
        } else if ch > vh + exitShortSlack {
            detailBottomChrome.shortEpisodeDetailLocksCompactChrome = false
        }
    }

    /// Keeps the current player when browsing other episodes or non-audio posts; only syncs metadata when this episode is already loaded.
    private func applyPlaybackSource() {
        guard let url = episodePlaybackURL else { return }
        guard playback.loadedMediaURL == url else { return }
        _ = playback.load(url: url, nowPlaying: episodeNowPlayingMeta, episodeKey: episode.stableKey)
    }

    private func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            toast = nil
        }
    }

    private func saveFavorite() {
        if existingFavorite != nil {
            flash("Already in favorites")
            return
        }
        let item = SavedItem(
            episodeKey: episode.stableKey,
            episodeTitle: episode.title,
            showTitle: episode.showTitle,
            feedID: episode.feedID,
            feedURLString: episode.feedURLString,
            audioURLString: episode.audioURL?.absoluteString,
            episodePubDate: episode.pubDate,
            linkURLString: episode.linkURL?.absoluteString,
            excerpt: "",
            note: nil
        )
        modelContext.insert(item)
        flash("Saved to favorites")
    }
}

// MARK: - Episode player card (split observation so playback time ticks don’t rebuild the sleep timer Menu)

@MainActor
private enum EpisodeDetailPlaybackBinder {
    static func audioURLs(episode: Episode, downloads: EpisodeDownloadStore) -> [URL] {
        var urls: [URL] = []
        if let remote = episode.audioURL { urls.append(remote) }
        if let local = downloads.localFileURL(forEpisodeKey: episode.stableKey) { urls.append(local) }
        return urls
    }

    static func isPlaybackBound(episode: Episode, playback: EpisodePlaybackController, downloads: EpisodeDownloadStore) -> Bool {
        if playback.loadedEpisodeKey == episode.stableKey { return true }
        guard let loaded = playback.loadedMediaURL else { return false }
        return audioURLs(episode: episode, downloads: downloads).contains(loaded)
    }

    static func nowPlayingMeta(for episode: Episode) -> EpisodeNowPlayingMetadata {
        EpisodeNowPlayingMetadata(
            title: episode.title,
            showTitle: episode.showTitle,
            artworkURL: episode.artworkURL
        )
    }

    static func loadThisEpisodeIfNeeded(episode: Episode, playback: EpisodePlaybackController, downloads: EpisodeDownloadStore) -> Bool {
        guard let url = downloads.playbackURL(for: episode) else { return false }
        _ = playback.load(
            url: url,
            nowPlaying: nowPlayingMeta(for: episode),
            episodeKey: episode.stableKey
        )
        return true
    }

    static func takeOverThisEpisodeThen(episode: Episode, playback: EpisodePlaybackController, downloads: EpisodeDownloadStore, body: () -> Void) {
        guard loadThisEpisodeIfNeeded(episode: episode, playback: playback, downloads: downloads) else { return }
        playback.play()
        body()
    }
}

private enum EpisodeDetailTimeFormatting {
    static func playbackLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN, t >= 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            let h = m / 60
            let rm = m % 60
            return String(format: "%d:%02d:%02d", h, rm, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func countdownLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN, t >= 0 else { return "00:00" }
        let total = Int(t.rounded(.down))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            let h = m / 60
            let rm = m % 60
            return String(format: "%d:%02d:%02d", h, rm, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct EpisodeDetailPlayerCard: View {
    let episode: Episode
    let playback: EpisodePlaybackController
    let sleepTimer: SleepTimerStore
    let downloads: EpisodeDownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                PodcastArtworkView(url: episode.artworkURL, size: 220, cornerRadius: 14)
                Spacer(minLength: 0)
            }
            EpisodeDetailPlayerScrubberBlock(episode: episode, playback: playback, downloads: downloads)
            HStack(spacing: 12) {
                EpisodeDetailSleepTimerMenu(episode: episode, sleepTimer: sleepTimer, playback: playback, downloads: downloads)
                Spacer(minLength: 8)
                EpisodeDetailSpeedPicker(episode: episode, playback: playback, downloads: downloads)
            }
            .padding(.top, 16)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct EpisodeDetailPlayerScrubberBlock: View {
    let episode: Episode
    @ObservedObject var playback: EpisodePlaybackController
    @ObservedObject var downloads: EpisodeDownloadStore

    /// SF Symbols only define `gobackward` / `goforward` with specific second values; fall back to the undecorated symbol when needed.
    private static let skipGlyphSeconds = Set([5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120])

    private var isBound: Bool {
        EpisodeDetailPlaybackBinder.isPlaybackBound(episode: episode, playback: playback, downloads: downloads)
    }

    private var savedBookmark: (position: TimeInterval, duration: TimeInterval?)? {
        playback.progressStore.bookmark(forEpisodeKey: episode.stableKey)
    }

    private var detailScrubberCurrentTime: TimeInterval {
        if isBound {
            let live = playback.currentTime
            if live > 0.25 || playback.isPlaying { return live }
            if playback.loadedEpisodeKey == episode.stableKey,
               let b = savedBookmark, b.position > 1 {
                return b.position
            }
            return live
        }
        if let bookmark = savedBookmark {
            return bookmark.position
        }
        return 0
    }

    private var detailScrubberSpan: TimeInterval {
        if isBound {
            let live = playback.currentTime
            if playback.duration > 0 {
                return max(playback.duration, live, detailScrubberCurrentTime, 1)
            }
            if let d = savedBookmark?.duration, d > 0 {
                return max(d, detailScrubberCurrentTime, 1)
            }
            return max(live, detailScrubberCurrentTime, 1)
        }
        if let bookmark = savedBookmark {
            if let d = bookmark.duration, d > 0 {
                return max(d, bookmark.position, 1)
            }
            return max(bookmark.position + max(60, bookmark.position * 0.08), bookmark.position, 1)
        }
        return 1
    }

    private var detailDurationLabel: String {
        if isBound {
            if playback.duration > 0 {
                return EpisodeDetailTimeFormatting.playbackLabel(playback.duration)
            }
            if let d = savedBookmark?.duration, d > 0 {
                return EpisodeDetailTimeFormatting.playbackLabel(d)
            }
            return "–:–"
        }
        if let d = savedBookmark?.duration, d > 0 {
            return EpisodeDetailTimeFormatting.playbackLabel(d)
        }
        return "–:–"
    }

    private var detailTransportShowsPause: Bool {
        isBound && playback.isPlaying
    }

    private func skipRewindSymbol(seconds: Int) -> String {
        Self.skipGlyphSeconds.contains(seconds) ? "gobackward.\(seconds)" : "gobackward"
    }

    private func skipAheadSymbol(seconds: Int) -> String {
        Self.skipGlyphSeconds.contains(seconds) ? "goforward.\(seconds)" : "goforward"
    }

    var body: some View {
        let span = detailScrubberSpan
        let back = playback.skipBackwardIntervals
        let fwd = playback.skipForwardIntervals
        VStack(alignment: .leading, spacing: 12) {
            Slider(
                value: Binding(
                    get: { min(max(detailScrubberCurrentTime, 0), span) },
                    set: { newTime in
                        if isBound {
                            playback.seek(to: newTime)
                        } else {
                            guard EpisodeDetailPlaybackBinder.loadThisEpisodeIfNeeded(
                                episode: episode,
                                playback: playback,
                                downloads: downloads
                            ) else { return }
                            playback.seek(to: newTime)
                            playback.play()
                        }
                    }
                ),
                in: 0 ... span
            )
            .tint(.accentColor)

            HStack {
                Text(EpisodeDetailTimeFormatting.playbackLabel(detailScrubberCurrentTime))
                Spacer(minLength: 8)
                Text(detailDurationLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    if back.count >= 2 {
                        skipBackButton(
                            seconds: Int(back[0]),
                            systemName: skipRewindSymbol(seconds: Int(back[0]))
                        )
                        skipBackButton(
                            seconds: Int(back[1]),
                            systemName: skipRewindSymbol(seconds: Int(back[1]))
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    if isBound {
                        playback.togglePlayback()
                    } else {
                        guard EpisodeDetailPlaybackBinder.loadThisEpisodeIfNeeded(
                            episode: episode,
                            playback: playback,
                            downloads: downloads
                        ) else { return }
                        playback.play()
                    }
                } label: {
                    Image(systemName: detailTransportShowsPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(detailTransportShowsPause ? "Pause" : "Play")

                HStack(spacing: 4) {
                    if fwd.count >= 2 {
                        skipForwardButton(
                            seconds: Int(fwd[0]),
                            systemName: skipAheadSymbol(seconds: Int(fwd[0]))
                        )
                        skipForwardButton(
                            seconds: Int(fwd[1]),
                            systemName: skipAheadSymbol(seconds: Int(fwd[1]))
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func skipBackButton(seconds: Int, systemName: String) -> some View {
        Button {
            if isBound {
                playback.skipBackward(by: TimeInterval(seconds))
            } else {
                EpisodeDetailPlaybackBinder.takeOverThisEpisodeThen(
                    episode: episode,
                    playback: playback,
                    downloads: downloads
                ) {
                    playback.skipBackward(by: TimeInterval(seconds))
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rewind \(seconds) seconds")
    }

    @ViewBuilder
    private func skipForwardButton(seconds: Int, systemName: String) -> some View {
        Button {
            if isBound {
                playback.skipForward(by: TimeInterval(seconds))
            } else {
                EpisodeDetailPlaybackBinder.takeOverThisEpisodeThen(
                    episode: episode,
                    playback: playback,
                    downloads: downloads
                ) {
                    playback.skipForward(by: TimeInterval(seconds))
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast forward \(seconds) seconds")
    }
}

/// Observes only `SleepTimerStore` so `EpisodePlaybackController.currentTime` does not throttle‑rebuild this `Menu`.
private struct EpisodeDetailSleepTimerMenu: View {
    let episode: Episode
    @ObservedObject var sleepTimer: SleepTimerStore
    let playback: EpisodePlaybackController
    let downloads: EpisodeDownloadStore

    private var isBound: Bool {
        EpisodeDetailPlaybackBinder.isPlaybackBound(episode: episode, playback: playback, downloads: downloads)
    }

    private var menuLabelNeedsTicker: Bool {
        guard sleepTimer.preset.countdownDuration != nil else { return false }
        guard let r = sleepTimer.remainingUntilFire(), r > 0 else { return false }
        return true
    }

    private var menuLabel: some View {
        Label(menuTitle, systemImage: "moon.zzz.fill")
            .font(.subheadline.weight(.medium).monospacedDigit())
    }

    private var menuTitle: String {
        if sleepTimer.preset == .off { return "Sleep timer" }
        if sleepTimer.preset == .endOfEpisode { return "Sleep · End of episode" }
        if let r = sleepTimer.remainingUntilFire(), r > 0 {
            return "Sleep · \(EpisodeDetailTimeFormatting.countdownLabel(r)) left"
        }
        return "Sleep · \(sleepTimer.preset == .fifteenMinutes ? "15 min" : "30 min")"
    }

    var body: some View {
        Menu {
            ForEach(SleepTimerPreset.allCases) { preset in
                Button {
                    if isBound {
                        sleepTimer.applyPreset(preset)
                    } else {
                        EpisodeDetailPlaybackBinder.takeOverThisEpisodeThen(
                            episode: episode,
                            playback: playback,
                            downloads: downloads
                        ) {
                            sleepTimer.applyPreset(preset)
                        }
                    }
                } label: {
                    HStack {
                        Text(preset.label)
                        Spacer(minLength: 12)
                        if sleepTimer.preset == preset {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Group {
                if menuLabelNeedsTicker {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        menuLabel
                    }
                } else {
                    menuLabel
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

private struct EpisodeDetailSpeedPicker: View {
    let episode: Episode
    @ObservedObject var playback: EpisodePlaybackController
    let downloads: EpisodeDownloadStore

    private var isBound: Bool {
        EpisodeDetailPlaybackBinder.isPlaybackBound(episode: episode, playback: playback, downloads: downloads)
    }

    private func speedSegmentLabel(_ rate: Float) -> String {
        if abs(rate - 1.0) < 0.001 { return "1×" }
        return String(format: "%.1f×", rate)
    }

    var body: some View {
        Picker("Speed", selection: Binding(
            get: { playback.playbackRate },
            set: { newRate in
                if isBound {
                    playback.setPlaybackRate(newRate)
                } else {
                    guard EpisodeDetailPlaybackBinder.loadThisEpisodeIfNeeded(
                        episode: episode,
                        playback: playback,
                        downloads: downloads
                    ) else { return }
                    playback.setPlaybackRate(newRate)
                    playback.play()
                }
            }
        )) {
            ForEach(playback.playbackRateOptions, id: \.self) { rate in
                Text(speedSegmentLabel(rate)).tag(rate)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }
}
