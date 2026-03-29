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

final class EpisodePlaybackController: ObservableObject {
    static let playbackRateOptions: [Float] = [0.8, 1.0, 1.3]
    static let skipBackwardOptions: [TimeInterval] = [15, 30]
    static let skipForwardOptions: [TimeInterval] = [30, 60]

    private static let playbackRateDefaultsKey = "moonlex.playbackRate"

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float

    /// Currently loaded stream; used to avoid resetting playback when reopening the same episode.
    private(set) var loadedMediaURL: URL?

    var sleepTimerStore: SleepTimerStore?

    private var nowPlayingMetadata: EpisodeNowPlayingMetadata?
    private var nowPlayingArtwork: UIImage?
    private var artworkFetchTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        let stored = Float(UserDefaults.standard.double(forKey: Self.playbackRateDefaultsKey))
        playbackRate = Self.playbackRateOptions.first(where: { abs($0 - stored) < 0.001 }) ?? 1.0

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        configureRemoteCommands()
    }

    /// Returns `true` if the current item was replaced (new URL or cleared). Caller can use this to reset episode-scoped UI state.
    @discardableResult
    func load(url: URL?, nowPlaying: EpisodeNowPlayingMetadata? = nil) -> Bool {
        guard let url else {
            let changed = player != nil
            stopAndClear()
            return changed
        }

        if let loaded = loadedMediaURL, loaded == url, player != nil {
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

        resetPlayer()
        loadedMediaURL = url
        cancelArtworkFetch()
        nowPlayingArtwork = nil
        if let nowPlaying {
            nowPlayingMetadata = nowPlaying
        }

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.defaultRate = playbackRate
        player = p

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let playback = self else { return }
            guard observed.status == .readyToPlay else { return }
            let durationUpdate: TimeInterval? = {
                let d = observed.duration
                return (d.isNumeric && d.seconds.isFinite) ? d.seconds : nil
            }()
            DispatchQueue.main.async { [playback, durationUpdate] in
                if let s = durationUpdate {
                    playback.duration = s
                }
                playback.pushNowPlayingInfo()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let playback = self else { return }
            playback.player?.pause()
            playback.isPlaying = false
            let endDuration = playback.duration
            if endDuration.isFinite {
                playback.currentTime = endDuration
            }
            playback.pushNowPlayingInfo()
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

    func setPlaybackRate(_ rate: Float) {
        guard Self.playbackRateOptions.contains(where: { abs($0 - rate) < 0.001 }) else { return }
        playbackRate = rate
        UserDefaults.standard.set(Double(rate), forKey: Self.playbackRateDefaultsKey)
        player?.defaultRate = rate
        if isPlaying { player?.rate = rate }
        pushNowPlayingInfo()
    }

    func play() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        sleepTimerStore?.armCountdownIfNeeded()
        player?.playImmediately(atRate: playbackRate)
        isPlaying = true
        pushNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        pushNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        let t = max(0, time)
        let cm = CMTime(seconds: t, preferredTimescale: 600)
        player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
        pushNowPlayingInfo()
    }

    func skipBackward(by interval: TimeInterval) {
        guard let delta = Self.skipBackwardOptions.first(where: { abs($0 - interval) < 0.5 }) else { return }
        seek(to: max(0, currentTime - delta))
    }

    func skipForward(by interval: TimeInterval) {
        guard let delta = Self.skipForwardOptions.first(where: { abs($0 - interval) < 0.5 }) else { return }
        let target = currentTime + delta
        if duration > 0, duration.isFinite {
            seek(to: min(target, duration))
        } else {
            seek(to: target)
        }
    }

    func stopAndClear() {
        pause()
        resetPlayer()
        loadedMediaURL = nil
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
        center.skipBackwardCommand.preferredIntervals = Self.skipBackwardOptions.map { NSNumber(value: $0) }
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
        center.skipForwardCommand.preferredIntervals = Self.skipForwardOptions.map { NSNumber(value: $0) }
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let playback = self,
                  let e = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            DispatchQueue.main.async { [playback] in
                playback.skipForward(by: e.interval)
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
    }
}
