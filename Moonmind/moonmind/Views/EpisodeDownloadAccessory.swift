import SwiftUI

/// Matches feed row styling; when `interactive` is true (episode detail), tap downloads and a menu offers removal.
struct EpisodeDownloadAccessory: View {
    let episode: Episode
    @ObservedObject var downloads: EpisodeDownloadStore
    var interactive: Bool = false

    var body: some View {
        Group {
            if episode.audioURL == nil {
                EmptyView()
            } else if downloads.isDownloading(episodeKey: episode.stableKey) {
                ProgressView()
                    .scaleEffect(0.85)
                    .frame(width: 28, height: 28)
            } else if downloads.isDownloaded(episodeKey: episode.stableKey) {
                if interactive {
                    Menu {
                        Button("Remove Download", role: .destructive) {
                            downloads.removeDownload(forEpisodeKey: episode.stableKey)
                        }
                    } label: {
                        downloadedImage
                    }
                } else {
                    downloadedImage
                }
            } else if interactive {
                Button {
                    Task { await downloads.downloadIfNeeded(episode: episode) }
                } label: {
                    notDownloadedImage
                }
                .buttonStyle(.plain)
            } else {
                notDownloadedImage
            }
        }
    }

    private var downloadedImage: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Downloaded")
    }

    private var notDownloadedImage: some View {
        Image(systemName: "arrow.down.circle")
            .font(.title3)
            .foregroundStyle(.tertiary)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Not downloaded")
    }
}
