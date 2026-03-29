import Combine
import Foundation

enum SleepTimerPreset: String, CaseIterable, Identifiable {
    case off
    case fifteenMinutes
    case thirtyMinutes
    case endOfEpisode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .endOfEpisode: return "End of episode"
        }
    }

    var countdownDuration: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        default: return nil
        }
    }
}

/// Persists the sleep timer **preset** (sticky). Countdown deadlines are also persisted so the timer survives backgrounding.
final class SleepTimerStore: ObservableObject {
    private let presetKey = "moonlex.sleepTimerPreset"
    private let deadlineKey = "moonlex.sleepTimerFireDeadline"

    @Published private(set) var preset: SleepTimerPreset
    @Published private(set) var fireDeadline: Date?

    init() {
        let raw = UserDefaults.standard.string(forKey: presetKey) ?? SleepTimerPreset.off.rawValue
        preset = SleepTimerPreset(rawValue: raw) ?? .off

        let ts = UserDefaults.standard.double(forKey: deadlineKey)
        var deadline: Date?
        if ts > 0 {
            deadline = Date(timeIntervalSince1970: ts)
        }
        if let d = deadline, d <= Date() {
            deadline = nil
            UserDefaults.standard.removeObject(forKey: deadlineKey)
        }
        fireDeadline = deadline
    }

    /// Call when opening a different episode so a previous countdown does not carry over.
    func onNewEpisodeLoaded() {
        guard preset.countdownDuration != nil else { return }
        fireDeadline = nil
        persistDeadline()
        objectWillChange.send()
    }

    func applyPreset(_ new: SleepTimerPreset) {
        preset = new
        UserDefaults.standard.set(new.rawValue, forKey: presetKey)
        switch new {
        case .off, .endOfEpisode:
            fireDeadline = nil
        case .fifteenMinutes, .thirtyMinutes:
            if let d = new.countdownDuration {
                fireDeadline = Date().addingTimeInterval(d)
            }
        }
        persistDeadline()
        objectWillChange.send()
    }

    /// When playback starts, start (or refresh) the countdown if there is no active deadline.
    func armCountdownIfNeeded() {
        guard let duration = preset.countdownDuration else { return }
        if let existing = fireDeadline, existing > Date() { return }
        fireDeadline = Date().addingTimeInterval(duration)
        persistDeadline()
        objectWillChange.send()
    }

    func checkFire(now: Date = Date()) -> Bool {
        guard preset.countdownDuration != nil, let deadline = fireDeadline else { return false }
        return now >= deadline
    }

    func consumeFiredCountdown() {
        fireDeadline = nil
        persistDeadline()
        objectWillChange.send()
    }

    func remainingUntilFire(now: Date = Date()) -> TimeInterval? {
        guard let deadline = fireDeadline, preset.countdownDuration != nil else { return nil }
        let r = deadline.timeIntervalSince(now)
        return r > 0 ? r : 0
    }

    private func persistDeadline() {
        if let d = fireDeadline {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: deadlineKey)
        } else {
            UserDefaults.standard.removeObject(forKey: deadlineKey)
        }
    }
}
