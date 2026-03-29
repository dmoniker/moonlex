import SwiftUI
import UIKit

/// Remote podcast artwork via ``PodcastArtworkCache`` (shared with Now Playing).
struct PodcastArtworkView: View {
    let url: URL?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    @State private var loadedImage: UIImage?
    @State private var didFail = false

    init(url: URL?, size: CGFloat = 56, cornerRadius: CGFloat = 8) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        _loadedImage = State(initialValue: url.flatMap { PodcastArtworkCache.cachedImage(for: $0) })
    }

    var body: some View {
        Group {
            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if url != nil, !didFail {
                ZStack {
                    placeholderSurface
                    ProgressView()
                        .scaleEffect(0.85)
                }
            } else {
                placeholderSurface
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url?.absoluteString) {
            await loadArtwork()
        }
    }

    private var placeholderSurface: some View {
        Color.secondary.opacity(0.12)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: max(14, size * 0.28), weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))
            }
    }

    private func loadArtwork() async {
        guard let url else {
            await MainActor.run {
                loadedImage = nil
                didFail = false
            }
            return
        }

        if let cached = PodcastArtworkCache.cachedImage(for: url) {
            await MainActor.run {
                loadedImage = cached
                didFail = false
            }
            return
        }

        await MainActor.run {
            loadedImage = nil
            didFail = false
        }

        let image = await PodcastArtworkCache.loadImage(for: url)
        await MainActor.run {
            if let image {
                loadedImage = image
                didFail = false
            } else {
                didFail = true
            }
        }
    }
}
