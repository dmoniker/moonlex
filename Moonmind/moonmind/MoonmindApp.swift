import SwiftUI
import SwiftData

@main
struct MoonmindApp: App {
    init() {
        PodcastArtworkCache.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: SavedItem.self)
    }
}
