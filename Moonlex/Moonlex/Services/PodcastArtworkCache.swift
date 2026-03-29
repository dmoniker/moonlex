import CryptoKit
import Foundation
import UIKit

/// In-memory (`NSCache`) + on-disk JPEG cache so artwork survives app relaunch and lists avoid spinner flashes.
enum PodcastArtworkCache {
    static let userAgent = "Moonlex/1.0 (iOS Podcast; artwork)"

    fileprivate static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        return cache
    }()

    private static let fm = FileManager.default

    static func configure() {
        memory.countLimit = 96
        try? fm.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    /// Synchronous read: memory, then disk (promotes to memory). Thread-safe for concurrent reads.
    static func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let mem = memory.object(forKey: key) {
            return mem
        }
        let path = diskURL(for: url)
        guard fm.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let image = UIImage(data: data)
        else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    static func loadImage(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        return await PodcastArtworkDownloadCoalescer.shared.result(for: url, key: url.absoluteString)
    }

    /// Network fetch + decode; may run on cooperative pool. Writes through to memory and disk.
    fileprivate nonisolated static func fetchRemoteImage(url: URL, key: String) async -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        let path = diskURL(for: url)
        if fm.fileExists(atPath: path.path), let data = try? Data(contentsOf: path), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                return nil
            }
            guard let image = UIImage(data: data) else { return nil }
            memory.setObject(image, forKey: key as NSString)
            if let jpeg = image.jpegData(compressionQuality: 0.88) {
                try? fm.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
                try? jpeg.write(to: path, options: .atomic)
            }
            return image
        } catch {
            return nil
        }
    }

    private nonisolated static var artworkDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Moonlex/Artwork", isDirectory: true)
    }

    private nonisolated static func diskURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = hash.map { String(format: "%02x", $0) }.joined() + ".jpg"
        return artworkDirectory.appendingPathComponent(name, isDirectory: false)
    }
}

// MARK: - Download coalescing

private actor PodcastArtworkDownloadCoalescer {
    static let shared = PodcastArtworkDownloadCoalescer()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func result(for url: URL, key: String) async -> UIImage? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let urlCopy = url
        let keyCopy = key
        let task = Task<UIImage?, Never> {
            await PodcastArtworkCache.fetchRemoteImage(url: urlCopy, key: keyCopy)
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}
