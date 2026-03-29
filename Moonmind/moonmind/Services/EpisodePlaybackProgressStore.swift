import Foundation

private struct PersistedPlaybackProgressV2: Codable {
    var positions: [String: Double]
    var played: [String]
    /// Last known total duration when `savePosition` ran (for scrubber UI before playback loads).
    var durations: [String: Double]?
}

/// Persists per-episode playback positions and “fully played” flags (Podcasts-style).
/// Mutations are performed on the main queue (from `EpisodePlaybackController`).
final class EpisodePlaybackProgressStore: ObservableObject {
    private static let defaultsKey = "moonmind.episodePlaybackProgress.v1"

    private var positions: [String: TimeInterval] = [:]
    private var lastKnownDurations: [String: TimeInterval] = [:]
    private var playedEpisodeKeys: Set<String> = []
    private let lock = NSLock()

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }

        if let v2 = try? JSONDecoder().decode(PersistedPlaybackProgressV2.self, from: data) {
            positions = v2.positions.mapValues { TimeInterval($0) }
            playedEpisodeKeys = Set(v2.played)
            if let d = v2.durations {
                lastKnownDurations = d.mapValues { TimeInterval($0) }
            }
        } else if let legacy = try? JSONDecoder().decode([String: Double].self, from: data) {
            positions = legacy.mapValues { TimeInterval($0) }
            playedEpisodeKeys = []
            lastKnownDurations = [:]
        }
    }

    func position(forEpisodeKey stableKey: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard playedEpisodeKeys.contains(stableKey) == false else { return nil }
        guard let p = positions[stableKey], p.isFinite, p > 0 else { return nil }
        return p
    }

    /// Saved listen position and optional last-known duration for UI on the detail screen before this episode is loaded in the player.
    func bookmark(forEpisodeKey stableKey: String) -> (position: TimeInterval, duration: TimeInterval?)? {
        lock.lock()
        defer { lock.unlock() }
        guard playedEpisodeKeys.contains(stableKey) == false else { return nil }
        guard let p = positions[stableKey], p.isFinite, p > 0 else { return nil }
        let dur: TimeInterval? = {
            guard let d = lastKnownDurations[stableKey], d > 0, d.isFinite else { return nil }
            return d
        }()
        return (p, dur)
    }

    func isMarkedPlayed(forEpisodeKey stableKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return playedEpisodeKeys.contains(stableKey)
    }

    func savePosition(
        _ seconds: TimeInterval,
        lastKnownDuration: TimeInterval? = nil,
        forEpisodeKey stableKey: String
    ) {
        guard seconds.isFinite, !seconds.isNaN, seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        playedEpisodeKeys.remove(stableKey)
        positions[stableKey] = seconds
        if let d = lastKnownDuration, d.isFinite, d > 0 {
            lastKnownDurations[stableKey] = d
        }
        persistLocked()
        objectWillChange.send()
    }

    func removePosition(forEpisodeKey stableKey: String) {
        lock.lock()
        defer { lock.unlock() }
        let hadPosition = positions.removeValue(forKey: stableKey) != nil
        let hadDuration = lastKnownDurations.removeValue(forKey: stableKey) != nil
        guard hadPosition || hadDuration else { return }
        persistLocked()
        objectWillChange.send()
    }

    /// Episode finished or skipped near the end — Podcasts “played” state.
    func markPlayed(forEpisodeKey stableKey: String) {
        lock.lock()
        defer { lock.unlock() }
        positions.removeValue(forKey: stableKey)
        lastKnownDurations.removeValue(forKey: stableKey)
        playedEpisodeKeys.insert(stableKey)
        persistLocked()
        objectWillChange.send()
    }

    /// Mark as not played (e.g. user wants it back in the unplayed list).
    func clearPlayed(forEpisodeKey stableKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard playedEpisodeKeys.remove(stableKey) != nil else { return }
        persistLocked()
        objectWillChange.send()
    }

    private func persistLocked() {
        let encodedPositions = positions.mapValues { Double($0) }
        let encodedDurations = lastKnownDurations.mapValues { Double($0) }
        let v2 = PersistedPlaybackProgressV2(
            positions: encodedPositions,
            played: Array(playedEpisodeKeys),
            durations: encodedDurations.isEmpty ? nil : encodedDurations
        )
        guard let data = try? JSONEncoder().encode(v2) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
