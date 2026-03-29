import Foundation

/// Persists per-episode playback positions so switching between episodes can resume where the user left off.
final class EpisodePlaybackProgressStore {
    private static let defaultsKey = "moonmind.episodePlaybackProgress.v1"

    private var positions: [String: TimeInterval] = [:]
    private let lock = NSLock()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            positions = decoded.mapValues { TimeInterval($0) }
        }
    }

    func position(forEpisodeKey stableKey: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = positions[stableKey], p.isFinite, p > 0 else { return nil }
        return p
    }

    func savePosition(_ seconds: TimeInterval, forEpisodeKey stableKey: String) {
        guard seconds.isFinite, !seconds.isNaN, seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        positions[stableKey] = seconds
        persistLocked()
    }

    func removePosition(forEpisodeKey stableKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard positions.removeValue(forKey: stableKey) != nil else { return }
        persistLocked()
    }

    private func persistLocked() {
        let encoded = positions.mapValues { Double($0) }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
