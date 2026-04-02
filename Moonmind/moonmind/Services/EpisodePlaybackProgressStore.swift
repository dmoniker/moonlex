import Foundation
import SwiftData

private struct PersistedPlaybackProgressV2: Codable {
    var positions: [String: Double]
    var played: [String]
    var durations: [String: Double]?
}

/// Persists per-episode playback positions and “fully played” flags (Podcasts-style), synced via SwiftData + CloudKit.
/// Call sites are expected to run on the main thread (player timebase, SwiftUI).
final class EpisodePlaybackProgressStore: ObservableObject {
    private static let legacyDefaultsKey = "moonmind.episodePlaybackProgress.v1"

    private var modelContext: ModelContext?

    private var positions: [String: TimeInterval] = [:]
    private var lastKnownDurations: [String: TimeInterval] = [:]
    private var playedEpisodeKeys: Set<String> = []

    init() {}

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        playedEpisodeKeys = []
        positions = [:]
        lastKnownDurations = [:]
        migrateFromUserDefaultsIfNeeded(into: modelContext)
        reloadFromSwiftData(using: modelContext)
    }

    /// Reload cache after CloudKit merges `PlaybackProgressRecord` rows (mirrors `attach` without re-running legacy migration).
    func refreshFromCloudKitImport(modelContext: ModelContext) {
        self.modelContext = modelContext
        playedEpisodeKeys = []
        positions = [:]
        lastKnownDurations = [:]
        reloadFromSwiftData(using: modelContext)
        objectWillChange.send()
    }

    func position(forEpisodeKey stableKey: String) -> TimeInterval? {
        guard playedEpisodeKeys.contains(stableKey) == false else { return nil }
        guard let p = positions[stableKey], p.isFinite, p > 0 else { return nil }
        return p
    }

    func bookmark(forEpisodeKey stableKey: String) -> (position: TimeInterval, duration: TimeInterval?)? {
        guard playedEpisodeKeys.contains(stableKey) == false else { return nil }
        guard let p = positions[stableKey], p.isFinite, p > 0 else { return nil }
        let dur: TimeInterval? = {
            guard let d = lastKnownDurations[stableKey], d > 0, d.isFinite else { return nil }
            return d
        }()
        return (p, dur)
    }

    func isMarkedPlayed(forEpisodeKey stableKey: String) -> Bool {
        playedEpisodeKeys.contains(stableKey)
    }

    func savePosition(
        _ seconds: TimeInterval,
        lastKnownDuration: TimeInterval? = nil,
        forEpisodeKey stableKey: String
    ) {
        guard seconds.isFinite, !seconds.isNaN, seconds > 0 else { return }
        playedEpisodeKeys.remove(stableKey)
        positions[stableKey] = seconds
        if let d = lastKnownDuration, d.isFinite, d > 0 {
            lastKnownDurations[stableKey] = d
        }
        persistRecord(forEpisodeKey: stableKey)
        objectWillChange.send()
    }

    func removePosition(forEpisodeKey stableKey: String) {
        let hadPosition = positions.removeValue(forKey: stableKey) != nil
        let hadDuration = lastKnownDurations.removeValue(forKey: stableKey) != nil
        guard hadPosition || hadDuration else { return }
        persistRecord(forEpisodeKey: stableKey)
        objectWillChange.send()
    }

    func markPlayed(forEpisodeKey stableKey: String) {
        positions.removeValue(forKey: stableKey)
        lastKnownDurations.removeValue(forKey: stableKey)
        playedEpisodeKeys.insert(stableKey)
        persistRecord(forEpisodeKey: stableKey)
        objectWillChange.send()
    }

    func clearPlayed(forEpisodeKey stableKey: String) {
        guard playedEpisodeKeys.remove(stableKey) != nil else { return }
        persistRecord(forEpisodeKey: stableKey)
        objectWillChange.send()
    }

    private func migrateFromUserDefaultsIfNeeded(into context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<PlaybackProgressRecord>())) ?? 0
        guard count == 0 else {
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey) else { return }

        if let v2 = try? JSONDecoder().decode(PersistedPlaybackProgressV2.self, from: data) {
            let playedSet = Set(v2.played)
            for (key, secs) in v2.positions {
                guard secs > 0, secs.isFinite, !playedSet.contains(key) else { continue }
                context.insert(
                    PlaybackProgressRecord(
                        episodeKey: key,
                        positionSeconds: secs,
                        lastKnownDurationSeconds: v2.durations?[key],
                        isPlayed: false
                    )
                )
            }
            for key in v2.played {
                context.insert(
                    PlaybackProgressRecord(
                        episodeKey: key,
                        positionSeconds: nil,
                        lastKnownDurationSeconds: nil,
                        isPlayed: true
                    )
                )
            }
        } else if let legacy = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (key, secs) in legacy {
                guard secs > 0, secs.isFinite else { continue }
                context.insert(
                    PlaybackProgressRecord(
                        episodeKey: key,
                        positionSeconds: secs,
                        lastKnownDurationSeconds: nil,
                        isPlayed: false
                    )
                )
            }
        }

        try? context.save()
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private func reloadFromSwiftData(using context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<PlaybackProgressRecord>())) ?? []
        var byKey: [String: [PlaybackProgressRecord]] = [:]
        for row in rows {
            byKey[row.episodeKey, default: []].append(row)
        }
        for (key, group) in byKey {
            if group.contains(where: { $0.isPlayed }) {
                playedEpisodeKeys.insert(key)
                continue
            }
            if let p = group.compactMap({ $0.positionSeconds }).filter({ $0.isFinite && $0 > 0 }).max() {
                positions[key] = p
            }
            if let d = group.compactMap({ $0.lastKnownDurationSeconds }).filter({ $0.isFinite && $0 > 0 }).max()
            {
                lastKnownDurations[key] = d
            }
        }
    }

    private func fetchRecords(episodeKey: String, in context: ModelContext) throws -> [PlaybackProgressRecord] {
        let fd = FetchDescriptor<PlaybackProgressRecord>(predicate: #Predicate { $0.episodeKey == episodeKey })
        return try context.fetch(fd)
    }

    private func persistRecord(forEpisodeKey stableKey: String) {
        guard let context = modelContext else { return }

        let played = playedEpisodeKeys.contains(stableKey)
        let pos = positions[stableKey]
        let dur = lastKnownDurations[stableKey]

        do {
            var rows = try fetchRecords(episodeKey: stableKey, in: context)
            if rows.count > 1 {
                for dup in rows.dropFirst() { context.delete(dup) }
                try context.save()
                rows = try fetchRecords(episodeKey: stableKey, in: context)
            }
            if let row = rows.first {
                if played {
                    row.isPlayed = true
                    row.positionSeconds = nil
                    row.lastKnownDurationSeconds = nil
                } else if let p = pos, p > 0 {
                    row.isPlayed = false
                    row.positionSeconds = p
                    row.lastKnownDurationSeconds = (dur != nil && dur! > 0) ? dur : nil
                } else {
                    context.delete(row)
                    try context.save()
                    return
                }
            } else {
                if played {
                    context.insert(
                        PlaybackProgressRecord(
                            episodeKey: stableKey,
                            positionSeconds: nil,
                            lastKnownDurationSeconds: nil,
                            isPlayed: true
                        )
                    )
                } else if let p = pos, p > 0 {
                    context.insert(
                        PlaybackProgressRecord(
                            episodeKey: stableKey,
                            positionSeconds: p,
                            lastKnownDurationSeconds: (dur != nil && dur! > 0) ? dur : nil,
                            isPlayed: false
                        )
                    )
                }
            }
            try context.save()
        } catch {
            assertionFailure("Playback progress save failed: \(error)")
        }
    }
}
