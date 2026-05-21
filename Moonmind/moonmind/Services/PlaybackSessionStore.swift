import Foundation

/// Enough episode metadata to reload the player after a cold launch when feed lists are still loading.
struct LoadedEpisodeSessionInfo: Codable, Equatable {
    let episodeKey: String
    let title: String
    let showTitle: String
    let feedID: String
    let feedURLString: String
    let feedContentKind: String
    let audioURLString: String?
    let artworkURLString: String?
    let pubDateInterval: TimeInterval?

    init(episode: Episode) {
        episodeKey = episode.stableKey
        title = episode.title
        showTitle = episode.showTitle
        feedID = episode.feedID
        feedURLString = episode.feedURLString
        feedContentKind = episode.feedContentKind.rawValue
        audioURLString = episode.audioURL?.absoluteString
        artworkURLString = episode.artworkURL?.absoluteString
        pubDateInterval = episode.pubDate?.timeIntervalSince1970
    }

    func makeEpisode() -> Episode {
        Episode(
            stableKey: episodeKey,
            title: title,
            pubDate: pubDateInterval.map { Date(timeIntervalSince1970: $0) },
            audioURL: audioURLString.flatMap { URL(string: $0) },
            showTitle: showTitle,
            feedID: feedID,
            feedURLString: feedURLString,
            linkURL: nil,
            descriptionRaw: "",
            artworkURL: artworkURLString.flatMap { URL(string: $0) },
            authorName: nil,
            authorAvatarURL: nil,
            feedContentKind: FeedContentKind(rawValue: feedContentKind) ?? .podcast
        )
    }
}

struct PlaybackSessionSnapshot: Codable, Equatable {
    enum Tab: Int, Codable {
        case feed = 0
        case newsletters = 1
        case favorites = 2
    }

    let episodeInfo: LoadedEpisodeSessionInfo
    let selectedTab: Tab
    let showsEpisodeDetail: Bool
    let wasPlaying: Bool
    let savedAt: Date
}

enum PlaybackSessionStore {
    static let defaultsKey = "moonmind.playbackSession.v1"

    static func save(_ snapshot: PlaybackSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func load() -> PlaybackSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Owning feed tab should reopen episode detail after a session restore.
struct PlaybackSessionRestoreNavigation: Equatable {
    let tab: PlaybackSessionSnapshot.Tab
    let episode: Episode
}
