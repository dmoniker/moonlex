import Foundation

@MainActor
final class FeedFilters: ObservableObject {
    private let key = "moonlex.feedEnabled"

    @Published private(set) var enabledByFeedID: [String: Bool] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            enabledByFeedID = decoded
        }
    }

    func isOn(_ feedID: String) -> Bool {
        enabledByFeedID[feedID, default: true]
    }

    func setOn(_ feedID: String, _ on: Bool) {
        var next = enabledByFeedID
        next[feedID] = on
        enabledByFeedID = next
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(enabledByFeedID) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
