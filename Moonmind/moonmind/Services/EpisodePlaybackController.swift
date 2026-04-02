import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

struct EpisodeNowPlayingMetadata: Equatable {
    var title: String
    var showTitle: String
    var artworkURL: URL?
}

/// When autoplay advances, the owning feed’s `NavigationStack` should show this episode’s detail (replacing the finished one if still on-screen).
struct AutoplayDetailNavigation: Equatable {
    enum Feed: Equatable {
        case podcast
        case newsletter
    }

    let feed: Feed
    let episode: Episode
}

final class EpisodePlaybackController: ObservableObject {
    static let skipBackLeftDefaultsKey = "moonmind.skipBackLeftSeconds"
    static let skipBackRightDefaultsKey = "moonmind.skipBackRightSeconds"
    static let skipForwardLeftDefaultsKey = "moonmind.skipForwardLeftSeconds"
    static let skipForwardRightDefaultsKey = "moonmind.skipForwardRightSeconds"
    static let defaultSkipBackLeft: TimeInterval = 15
    static let defaultSkipBackRight: TimeInterval = 30
    static let defaultSkipForwardLeft: TimeInterval = 30
    static let defaultSkipForwardRight: TimeInterval = 60
    static let skipSecondsMin: TimeInterval = 5
    static let skipSecondsMax: TimeInterval = 300

    static let playbackRateSlowDefaultsKey = "moonmind.playbackRateSlow"
    static let playbackRateFastDefaultsKey = "moonmind.playbackRateFast"
    static let defaultSlowPlaybackRate: Float = 0.8
    static let defaultFastPlaybackRate: Float = 1.3
    static let slowRateRange: ClosedRange<Float> = 0.5...0.95
    static let fastRateRange: ClosedRange<Float> = 1.05...2.5

    private static let playbackRateDefaultsKey = "moonmind.playbackRate"
    static let autoplayNextDefaultsKey = "moonmind.autoplayNextInFeed"
    /// Stored raw value of `AutoplayScope` (`feed` or `sameShow`).
    static let autoplayScopeDefaultsKey = "moonmind.autoplayScope"

    enum AutoplayScope: String, CaseIterable, Identifiable {
        /// Next unplayed episode in full feed order (newest first).
        case feed
        /// Next unplayed episode from the same podcast / newsletter (`feedID`).
        case sameShow

        var id: String { rawValue }

        static func resolvedFromUserDefaults() -> AutoplayScope {
            let raw = UserDefaults.standard.string(forKey: EpisodePlaybackController.autoplayScopeDefaultsKey)
            guard let raw, let scope = AutoplayScope(rawValue: raw) else { return .feed }
            return scope
        }
    }

    private static let minResumeSeconds: TimeInterval = 3
    private static let nearEndClearSeconds: TimeInterval = 15
    private static let periodicProgressSaveInterval: TimeInterval = 12

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float

    /// Three speeds: slow, 1×, fast (slow/fast come from Settings).
    var playbackRateOptions: [Float] {
        Self.resolvedPlaybackRateTiers()
    }

    /// Skip amounts for the two rewind / fast-forward controls and lock-screen skip (seconds).
    private(set) var skipBackwardIntervals: [TimeInterval]
    private(set) var skipForwardIntervals: [TimeInterval]

    /// Currently loaded stream; used to avoid resetting playback when reopening the same episode.
    @Published private(set) var loadedMediaURL: URL?

    /// Episode whose progress is tracked for persistence (matches the playing asset).
    private(set) var loadedEpisodeKey: String?

    @Published private(set) var autoplayDetailNavigation: AutoplayDetailNavigation?

    /// User tapped the mini player; owning feed tab should reset its stack and push this detail.
    @Published private(set) var miniPlayerDetailNavigation: AutoplayDetailNavigation?

    var sleepTimerStore: SleepTimerStore?
    weak var downloadStore: EpisodeDownloadStore?
    weak var feedHomeModel: HomeViewModel?
    weak var feedNewsletterModel: HomeViewModel?

    let progressStore = EpisodePlaybackProgressStore()

    /// Title, show, and artwork for the current load; `nil` after `stopAndClear()`. Published for mini-player UI.
    @Published private(set) var nowPlayingMetadata: EpisodeNowPlayingMetadata?
    private var nowPlayingArtwork: UIImage?
    private var artworkFetchTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    /// Avoid saving `0` while a resume seek is still in flight for a newly loaded item.
    private var resumeSetupComplete = true
    private var lastPeriodicProgressSave = Date.distantPast
    private var progressForwardCancellable: AnyCancellable?

    init() {
        skipBackwardIntervals = Self.loadSkipBackwardIntervalsFromDefaults()
        skipForwardIntervals = Self.loadSkipForwardIntervalsFromDefaults()

        let tiers = Self.resolvedPlaybackRateTiers()
        let stored = Float(UserDefaults.standard.double(forKey: Self.playbackRateDefaultsKey))
        playbackRate = tiers.first(where: { abs($0 - stored) < 0.001 }) ?? 1.0

        progressForwardCancellable = progressStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        configureRemoteCommands()
    }

    static func clampSlowRate(_ value: Float) -> Float {
        min(max(value, slowRateRange.lowerBound), slowRateRange.upperBound)
    }

    static func clampFastRate(_ value: Float) -> Float {
        min(max(value, fastRateRange.lowerBound), fastRateRange.upperBound)
    }

    private static func resolvedPlaybackRateTiers() -> [Float] {
        let rawSlow = Float(UserDefaults.standard.double(forKey: playbackRateSlowDefaultsKey))
        let rawFast = Float(UserDefaults.standard.double(forKey: playbackRateFastDefaultsKey))
        let slow = (rawSlow > 0 && rawSlow < 1) ? clampSlowRate(rawSlow) : defaultSlowPlaybackRate
        let fast = (rawFast > 1) ? clampFastRate(rawFast) : defaultFastPlaybackRate
        return [slow, 1.0, fast]
    }

    private static func clampSkipSeconds(_ value: TimeInterval) -> TimeInterval {
        let rounded = round(value)
        return min(max(rounded, skipSecondsMin), skipSecondsMax)
    }

    private static func readSkipSeconds(key: String, default def: TimeInterval) -> TimeInterval {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return clampSkipSeconds(def)
        }
        let v = UserDefaults.standard.double(forKey: key)
        if v <= 0 { return clampSkipSeconds(def) }
        return clampSkipSeconds(v)
    }

    private static func loadSkipBackwardIntervalsFromDefaults() -> [TimeInterval] {
        let a = readSkipSeconds(key: skipBackLeftDefaultsKey, default: defaultSkipBackLeft)
        let b = readSkipSeconds(key: skipBackRightDefaultsKey, default: defaultSkipBackRight)
        return [a, b]
    }

    private static func loadSkipForwardIntervalsFromDefaults() -> [TimeInterval] {
        let a = readSkipSeconds(key: skipForwardLeftDefaultsKey, default: defaultSkipForwardLeft)
        let b = readSkipSeconds(key: skipForwardRightDefaultsKey, default: defaultSkipForwardRight)
        return [a, b]
    }

    /// Call when skip interval values change in Settings (updates Now Playing / lock screen).
    func refreshSkipIntervalsFromUserDefaults() {
        skipBackwardIntervals = Self.loadSkipBackwardIntervalsFromDefaults()
        skipForwardIntervals = Self.loadSkipForwardIntervalsFromDefaults()
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = skipBackwardIntervals.map { NSNumber(value: $0) }
        center.skipForwardCommand.preferredIntervals = skipForwardIntervals.map { NSNumber(value: $0) }
        objectWillChange.send()
    }

    /// Call after slow/fast tiers change in Settings so the current rate stays valid and the player updates.
    func refreshPlaybackRateTiersFromUserDefaults() {
        let tiers = Self.resolvedPlaybackRateTiers()
        if tiers.contains(where: { abs($0 - playbackRate) < 0.001 }) {
            // keep current rate
        } else {
            let nearest = tiers.min(by: { abs($0 - playbackRate) < abs($1 - playbackRate) }) ?? 1.0
            playbackRate = nearest
            UserDefaults.standard.set(Double(nearest), forKey: Self.playbackRateDefaultsKey)
        }
        player?.defaultRate = playbackRate
        if isPlaying { player?.rate = playbackRate }
        objectWillChange.send()
        pushNowPlayingInfo()
    }

    private func handleCurrentItemPlayedToEnd() {
        let finishedKey = loadedEpisodeKey
        if let key = finishedKey {
            progressStore.markPlayed(forEpisodeKey: key)
        }
        player?.pause()
        isPlaying = false
        let endDuration = duration
        if endDuration.isFinite {
            currentTime = endDuration
        }
        pushNowPlayingInfo()
        Task { @MainActor [weak self] in
            self?.attemptAutoplayAfterFinishedEpisode(finishedKey: finishedKey)
        }
    }

    func consumeAutoplayDetailNavigation() {
        autoplayDetailNavigation = nil
    }

    func consumeMiniPlayerDetailNavigation() {
        miniPlayerDetailNavigation = nil
    }

    /// Call `selectTab` with `0` (Feed) or `1` (Newsletters), then publishes ``miniPlayerDetailNavigation`` when the episode is in that feed list.
    @MainActor
    func openNowPlayingDetail(selectTab: (Int) -> Void) {
        guard let key = loadedEpisodeKey else { return }
        if let ep = feedHomeModel?.episodes.first(where: { $0.stableKey == key }) {
            selectTab(0)
            miniPlayerDetailNavigation = AutoplayDetailNavigation(feed: .podcast, episode: ep)
            return
        }
        if let ep = feedNewsletterModel?.episodes.first(where: { $0.stableKey == key }) {
            selectTab(1)
            miniPlayerDetailNavigation = AutoplayDetailNavigation(feed: .newsletter, episode: ep)
            return
        }
    }

    @MainActor
    private func attemptAutoplayAfterFinishedEpisode(finishedKey: String?) {
        guard UserDefaults.standard.bool(forKey: Self.autoplayNextDefaultsKey) else { return }
        guard let key = finishedKey, let downloads = downloadStore else { return }
        let scope = AutoplayScope.resolvedFromUserDefaults()

        func tryAdvance(in episodes: [Episode], feed: AutoplayDetailNavigation.Feed) -> Bool {
            guard let next = nextUnplayedEpisodeWithAudio(after: key, in: episodes, scope: scope) else { return false }
            guard let url = downloads.playbackURL(for: next) else { return false }
            let meta = EpisodeNowPlayingMetadata(
                title: next.title,
                showTitle: next.showTitle,
                artworkURL: next.artworkURL
            )
            _ = load(url: url, nowPlaying: meta, episodeKey: next.stableKey)
            play(armSleepTimerIfNeeded: false)
            autoplayDetailNavigation = AutoplayDetailNavigation(feed: feed, episode: next)
            return true
        }

        if let home = feedHomeModel?.episodes, tryAdvance(in: home, feed: .podcast) { return }
        if let newsletters = feedNewsletterModel?.episodes, tryAdvance(in: newsletters, feed: .newsletter) { return }
    }

    /// Next episode with audio after `key` in feed order that is not marked fully played; nil if none (autoplay stops).
    private func nextUnplayedEpisodeWithAudio(
        after key: String,
        in episodes: [Episode],
        scope: AutoplayScope
    ) -> Episode? {
        let withAudio = episodes.filter { $0.audioURL != nil }
        guard let i = withAudio.firstIndex(where: { $0.stableKey == key }) else { return nil }
        let sameShowID = withAudio[i].feedID
        var j = i + 1
        while j < withAudio.count {
            let ep = withAudio[j]
            if scope == .sameShow, ep.feedID != sameShowID {
                j += 1
                continue
            }
            if !progressStore.isMarkedPlayed(forEpisodeKey: ep.stableKey) {
                return ep
            }
            j += 1
        }
        return nil
    }

    /// Listen Notes and some ad/CDN hops reject AVFoundation’s default user agent (stall after a few seconds or silent decode).
    private static func playerItem(for url: URL) -> AVPlayerItem {
        guard url.isFileURL == false, Self.needsBrowserLikeAssetHeaders(for: url) else {
            return AVPlayerItem(url: url)
        }
        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
        ]
        // `AVURLAssetHTTPHeaderFieldsKey` is not always visible to Swift; string matches AVFoundation’s option key.
        let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: opts)
        return AVPlayerItem(asset: asset)
    }

    private static func needsBrowserLikeAssetHeaders(for url: URL) -> Bool {
        let h = url.host?.lowercased() ?? ""
        if h.contains("megaphone.fm") { return true }
        if h.contains("omny.fm") || h.contains("omnycontent.com") { return true }
        if h.contains("podtrac.com") { return true }
        if h.contains("art19.com") { return true }
        if h.contains("spotifycdn.com") || h.contains("spotify.com") { return true }
        if h.contains("simplecast.com") { return true }
        if h.contains("anchor.fm") { return true }
        return false
    }

    /// Returns `true` if the current item was replaced (new URL or cleared). Caller can use this to reset episode-scoped UI state.
    @discardableResult
    func load(
        url: URL?,
        nowPlaying: EpisodeNowPlayingMetadata? = nil,
        episodeKey: String? = nil
    ) -> Bool {
        guard let url else {
            persistListeningProgressIfNeeded()
            let changed = player != nil
            stopAndClear()
            return changed
        }

        if let loaded = loadedMediaURL, loaded == url, player != nil {
            if let episodeKey { loadedEpisodeKey = episodeKey }
            resumeSetupComplete = true
            player?.defaultRate = playbackRate
            if isPlaying { player?.rate = playbackRate }
            if let np = nowPlaying {
                let artURLChanged = nowPlayingMetadata?.artworkURL != np.artworkURL
                nowPlayingMetadata = np
                if artURLChanged || (np.artworkURL != nil && nowPlayingArtwork == nil) {
                    if artURLChanged { nowPlayingArtwork = nil }
                    startArtworkFetchIfNeeded()
                }
                pushNowPlayingInfo()
            }
            return false
        }

        persistListeningProgressIfNeeded()
        resumeSetupComplete = false
        resetPlayer()
        currentTime = 0
        duration = 0
        loadedMediaURL = url
        loadedEpisodeKey = episodeKey
        cancelArtworkFetch()
        nowPlayingArtwork = nil
        if let nowPlaying {
            nowPlayingMetadata = nowPlaying
        }

        let item = Self.playerItem(for: url)
        item.preferredForwardBufferDuration = 45
        let p = AVPlayer(playerItem: item)
        p.defaultRate = playbackRate
        p.automaticallyWaitsToMinimizeStalling = true
        player = p

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let playback = self else { return }
            if observed.status == .failed {
                DispatchQueue.main.async {
                    playback.isPlaying = false
                    playback.statusObservation?.invalidate()
                    playback.statusObservation = nil
                    playback.pushNowPlayingInfo()
                }
                return
            }
            guard observed.status == .readyToPlay else { return }
            let durationUpdate: TimeInterval? = {
                let d = observed.duration
                return (d.isNumeric && d.seconds.isFinite) ? d.seconds : nil
            }()
            DispatchQueue.main.async { [playback, durationUpdate] in
                if let s = durationUpdate {
                    playback.duration = s
                }
                let key = episodeKey
                let knownDuration = playback.duration
                let resume = playback.resolvedResumePosition(episodeKey: key, knownDuration: knownDuration)
                if resume > 0.5 {
                    let cm = CMTime(seconds: resume, preferredTimescale: 600)
                    p.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        DispatchQueue.main.async {
                            guard let playback = self else { return }
                            if finished {
                                playback.currentTime = resume
                            }
                            playback.statusObservation?.invalidate()
                            playback.statusObservation = nil
                            playback.resumeSetupComplete = true
                            playback.pushNowPlayingInfo()
                        }
                    }
                } else {
                    playback.statusObservation?.invalidate()
                    playback.statusObservation = nil
                    playback.resumeSetupComplete = true
                    playback.pushNowPlayingInfo()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleCurrentItemPlayedToEnd()
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let playback = self, playback.isPlaying else { return }
            playback.player?.play()
        }

        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let playback = self else { return }
            playback.currentTime = t.seconds
            if let item = playback.player?.currentItem,
               playback.duration <= 0 || !playback.duration.isFinite,
               item.duration.isNumeric,
               item.duration.seconds.isFinite {
                playback.duration = item.duration.seconds
            }
            if playback.resumeSetupComplete, playback.isPlaying, playback.loadedEpisodeKey != nil {
                let now = Date()
                if now.timeIntervalSince(playback.lastPeriodicProgressSave) >= Self.periodicProgressSaveInterval {
                    playback.lastPeriodicProgressSave = now
                    playback.persistListeningProgressIfNeeded()
                }
            }
            if playback.isPlaying, let store = playback.sleepTimerStore, store.checkFire() {
                playback.pause()
                store.consumeFiredCountdown()
            }
            if playback.isPlaying {
                playback.pushNowPlayingInfo()
            }
        }

        startArtworkFetchIfNeeded()
        pushNowPlayingInfo()
        return true
    }

    /// When a download finishes while this URL is playing, swap to the local file and keep time / play state.
    func migrateStreamToLocalFileIfCurrentlyPlaying(remoteURL: URL, localURL: URL) {
        guard let p = player, let loaded = loadedMediaURL else { return }
        guard Self.urlsMatchForSameAsset(loaded, remoteURL) else { return }
        guard !Self.urlsMatchForSameAsset(localURL, loaded) else { return }

        let resumeTime = max(0, currentTime)
        let shouldResumePlaying = isPlaying

        if let obs = timeObserver {
            p.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil

        p.pause()
        isPlaying = false
        pushNowPlayingInfo()

        loadedMediaURL = localURL

        let newItem = AVPlayerItem(url: localURL)
        p.replaceCurrentItem(with: newItem)
        p.defaultRate = playbackRate

        statusObservation = newItem.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let playback = self else { return }
            guard observedItem.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                playback.statusObservation?.invalidate()
                playback.statusObservation = nil
                if let d = playback.durationIfReady(observedItem) {
                    playback.duration = d
                }
                let cm = CMTime(seconds: resumeTime, preferredTimescale: 600)
                p.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }
                    DispatchQueue.main.async { [weak playback] in
                        guard let playback else { return }
                        playback.currentTime = resumeTime
                        if shouldResumePlaying {
                            playback.play()
                        } else {
                            playback.pushNowPlayingInfo()
                        }
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleCurrentItemPlayedToEnd()
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            guard let playback = self, playback.isPlaying else { return }
            playback.player?.play()
        }

        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let playback = self else { return }
            playback.currentTime = t.seconds
            if let curItem = playback.player?.currentItem,
               playback.duration <= 0 || !playback.duration.isFinite,
               curItem.duration.isNumeric,
               curItem.duration.seconds.isFinite {
                playback.duration = curItem.duration.seconds
            }
            if playback.resumeSetupComplete, playback.isPlaying, playback.loadedEpisodeKey != nil {
                let now = Date()
                if now.timeIntervalSince(playback.lastPeriodicProgressSave) >= Self.periodicProgressSaveInterval {
                    playback.lastPeriodicProgressSave = now
                    playback.persistListeningProgressIfNeeded()
                }
            }
            if playback.isPlaying, let store = playback.sleepTimerStore, store.checkFire() {
                playback.pause()
                store.consumeFiredCountdown()
            }
            if playback.isPlaying {
                playback.pushNowPlayingInfo()
            }
        }

        pushNowPlayingInfo()
    }

    private func durationIfReady(_ item: AVPlayerItem) -> TimeInterval? {
        let d = item.duration
        guard d.isNumeric, d.seconds.isFinite else { return nil }
        return d.seconds
    }

    private static func urlsMatchForSameAsset(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString == b.absoluteString
    }

    private func resolvedResumePosition(episodeKey: String?, knownDuration: TimeInterval) -> TimeInterval {
        guard let key = episodeKey, let saved = progressStore.position(forEpisodeKey: key) else { return 0 }
        var t = saved
        if knownDuration > 0, knownDuration.isFinite {
            if t >= knownDuration - Self.nearEndClearSeconds { return 0 }
            t = min(t, max(0, knownDuration - 1))
        }
        return t
    }

    private func persistListeningProgressIfNeeded() {
        guard resumeSetupComplete else { return }
        guard let key = loadedEpisodeKey else { return }
        let t = currentTime
        guard t.isFinite, !t.isNaN else { return }
        if t < Self.minResumeSeconds {
            progressStore.removePosition(forEpisodeKey: key)
            return
        }
        if duration > 0, duration.isFinite, t >= duration - Self.nearEndClearSeconds {
            progressStore.markPlayed(forEpisodeKey: key)
            return
        }
        let knownDuration = (duration > 0 && duration.isFinite) ? duration : nil
        progressStore.savePosition(t, lastKnownDuration: knownDuration, forEpisodeKey: key)
    }

    func setPlaybackRate(_ rate: Float) {
        guard playbackRateOptions.contains(where: { abs($0 - rate) < 0.001 }) else { return }
        playbackRate = rate
        UserDefaults.standard.set(Double(rate), forKey: Self.playbackRateDefaultsKey)
        player?.defaultRate = rate
        if isPlaying { player?.rate = rate }
        pushNowPlayingInfo()
    }

    /// - Parameter armSleepTimerIfNeeded: When false (e.g. autoplay), does not start a new countdown if none is active—only explicit user playback should re-arm after the timer has fired.
    func play(armSleepTimerIfNeeded: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        if armSleepTimerIfNeeded {
            sleepTimerStore?.armCountdownIfNeeded()
        }
        guard let p = player else {
            isPlaying = false
            pushNowPlayingInfo()
            return
        }
        // `playImmediately(atRate:)` often no-ops until the item is ready; Listen Notes audio URLs redirect and buffer more slowly than direct MP3 enclosures.
        p.automaticallyWaitsToMinimizeStalling = true
        p.rate = playbackRate
        p.play()
        isPlaying = true
        pushNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        persistListeningProgressIfNeeded()
        pushNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Loads local file or stream for the episode and starts playback. Returns `false` when there is no audio URL.
    @MainActor
    @discardableResult
    func startPlayback(episode: Episode, downloads: EpisodeDownloadStore) -> Bool {
        guard let url = downloads.playbackURL(for: episode) else { return false }
        let meta = EpisodeNowPlayingMetadata(
            title: episode.title,
            showTitle: episode.showTitle,
            artworkURL: episode.artworkURL
        )
        _ = load(url: url, nowPlaying: meta, episodeKey: episode.stableKey)
        play()
        return true
    }

    /// Persists current playback position / played state before app background or termination.
    func flushListeningProgressToStore() {
        persistListeningProgressIfNeeded()
    }

    /// Marks the episode as fully played without listening to the end. Pauses and moves the scrubber to the end if this episode is loaded; does not trigger autoplay.
    func markEpisodePlayed(episodeKey: String) {
        progressStore.markPlayed(forEpisodeKey: episodeKey)
        guard loadedEpisodeKey == episodeKey else {
            pushNowPlayingInfo()
            return
        }
        player?.pause()
        isPlaying = false
        let d = duration
        if d > 0, d.isFinite {
            let cm = CMTime(seconds: d, preferredTimescale: 600)
            player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = d
        }
        pushNowPlayingInfo()
    }

    /// Clears the fully-played flag (episode shows as unplayed again). If this episode is still loaded at the end, seeks to the start so it is not immediately marked played again.
    func markEpisodeUnplayed(episodeKey: String) {
        progressStore.clearPlayed(forEpisodeKey: episodeKey)
        guard loadedEpisodeKey == episodeKey else { return }
        if duration > 0, duration.isFinite, currentTime >= duration - Self.nearEndClearSeconds {
            seek(to: 0)
        } else {
            persistListeningProgressIfNeeded()
            pushNowPlayingInfo()
        }
    }

    func seek(to time: TimeInterval) {
        let t = max(0, time)
        let cm = CMTime(seconds: t, preferredTimescale: 600)
        player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
        if resumeSetupComplete {
            persistListeningProgressIfNeeded()
        }
        pushNowPlayingInfo()
    }

    func skipBackward(by interval: TimeInterval) {
        guard let delta = skipBackwardIntervals.first(where: { abs($0 - interval) < 0.5 }) else { return }
        seek(to: max(0, currentTime - delta))
    }

    func skipForward(by interval: TimeInterval) {
        guard let delta = skipForwardIntervals.first(where: { abs($0 - interval) < 0.5 }) else { return }
        let target = currentTime + delta
        if duration > 0, duration.isFinite {
            seek(to: min(target, duration))
        } else {
            seek(to: target)
        }
    }

    func stopAndClear() {
        persistListeningProgressIfNeeded()
        player?.pause()
        isPlaying = false
        resetPlayer()
        loadedMediaURL = nil
        loadedEpisodeKey = nil
        miniPlayerDetailNavigation = nil
        nowPlayingMetadata = nil
        cancelArtworkFetch()
        nowPlayingArtwork = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func cancelArtworkFetch() {
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
    }

    private func startArtworkFetchIfNeeded() {
        cancelArtworkFetch()
        guard let url = nowPlayingMetadata?.artworkURL else { return }
        let expectedURL = url

        if let cached = PodcastArtworkCache.cachedImage(for: expectedURL) {
            nowPlayingArtwork = cached
            pushNowPlayingInfo()
            return
        }

        artworkFetchTask = Task { [weak self] in
            let image = await PodcastArtworkCache.loadImage(for: expectedURL)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let playback = self else { return }
                guard !Task.isCancelled else { return }
                guard playback.nowPlayingMetadata?.artworkURL == expectedURL else { return }
                if let image {
                    playback.nowPlayingArtwork = image
                    playback.pushNowPlayingInfo()
                }
            }
        }
    }

    /// Downscales huge podcast art so `MPMediaItemArtwork` and the OS can use it reliably.
    private static func artworkImageForLockScreen(_ image: UIImage, requestedSize: CGSize) -> UIImage {
        let target = max(requestedSize.width, requestedSize.height)
        guard target > 1, image.size.width > 0, image.size.height > 0 else { return image }
        let maxSide = max(image.size.width, image.size.height)
        if maxSide <= 1024, target >= maxSide { return image }
        let aim = min(1024, max(512, target))
        let scale = aim / maxSide
        let newSize = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        guard newSize.width >= 2, newSize.height >= 2 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func pushNowPlayingInfo() {
        guard loadedMediaURL != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = [String: Any]()
        if let meta = nowPlayingMetadata {
            info[MPMediaItemPropertyTitle] = meta.title
            info[MPMediaItemPropertyArtist] = meta.showTitle
        }
        if duration > 0, duration.isFinite, !duration.isNaN {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let elapsed = max(0, currentTime)
        if elapsed.isFinite, !elapsed.isNaN {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        let rate = Double(playbackRate)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
        if let img = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { size in
                Self.artworkImageForLockScreen(img, requestedSize: size)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let playback = self else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.play()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let playback = self else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.pause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let playback = self else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.togglePlayback()
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let playback = self,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let position = e.positionTime
            DispatchQueue.main.async { [playback] in
                playback.seek(to: position)
            }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = skipBackwardIntervals.map { NSNumber(value: $0) }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let playback = self,
                  let e = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.skipBackward(by: e.interval)
            }
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = skipForwardIntervals.map { NSNumber(value: $0) }
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let playback = self,
                  let e = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.skipForward(by: e.interval)
            }
            return .success
        }

        // AirPods stem: double-press → next track, triple-press → previous track (maps to interval skip for podcasts).
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let playback = self else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                guard let delta = playback.skipForwardIntervals.first else { return }
                playback.skipForward(by: delta)
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let playback = self else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                guard let delta = playback.skipBackwardIntervals.first else { return }
                playback.skipBackward(by: delta)
            }
            return .success
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            pause()
        case .ended:
            break
        @unknown default:
            break
        }
    }

    private func resetPlayer() {
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        stallObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    deinit {
        artworkFetchTask?.cancel()
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
}
