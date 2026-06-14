import SwiftUI
import UIKit

/// Native share sheet for an episode’s show-notes page or podcast website.
struct EpisodeShareLink: View {
    let episode: Episode

    private var cachedArtwork: UIImage? {
        episode.artworkURL.flatMap { PodcastArtworkCache.cachedImage(for: $0) }
    }

    private var shareLabel: some View {
        Label("Share Episode", systemImage: "square.and.arrow.up")
    }

    var body: some View {
        if let url = episode.shareURL {
            if let artwork = cachedArtwork {
                ShareLink(
                    item: url,
                    subject: Text(episode.title),
                    message: Text(episode.shareCaption),
                    preview: SharePreview(episode.title, image: Image(uiImage: artwork))
                ) {
                    shareLabel
                }
            } else {
                ShareLink(
                    item: url,
                    subject: Text(episode.title),
                    message: Text(episode.shareCaption)
                ) {
                    shareLabel
                }
            }
        } else if let artwork = cachedArtwork {
            ShareLink(
                item: episode.shareMessage,
                subject: Text(episode.title),
                preview: SharePreview(episode.title, image: Image(uiImage: artwork))
            ) {
                shareLabel
            }
        } else {
            ShareLink(item: episode.shareMessage, subject: Text(episode.title)) {
                shareLabel
            }
        }
    }
}
