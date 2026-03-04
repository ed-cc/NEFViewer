// ThumbnailCache is AppKit-dependent (NSImage / NSBitmapImageRep).
// The #if guard lets the rest of NEFViewerCore compile on Linux for CI.
#if canImport(AppKit)
import AppKit
import Foundation

/// A persistent, LRU-evicting disk cache for NEF thumbnail images.
///
/// Thumbnails are stored as JPEG files in `~/Library/Caches/com.nefviewer.app/thumbnails/`.
/// Cache keys encode the source file path, file size, modification date, and the
/// requested thumbnail size, so entries are automatically invalidated when the
/// source file changes.
public final class ThumbnailCache {

    // MARK: Shared instance

    public static let shared = ThumbnailCache()

    // MARK: Configuration

    /// Maximum on-disk cache size. Oldest-accessed entries are evicted when exceeded.
    public var maxCacheSizeBytes: Int = 500 * 1024 * 1024  // 500 MB

    // MARK: Private state

    private let cacheDirectory: URL
    private let fileManager = FileManager.default

    // MARK: Init

    public init(cacheDirectory: URL? = nil) {
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectory = caches.appendingPathComponent("com.nefviewer.app/thumbnails")
        }
        try? fileManager.createDirectory(at: self.cacheDirectory,
                                         withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Returns the file URL of a cached thumbnail if it is still valid, otherwise nil.
    /// A cached entry is invalid if it does not exist or if the source file's
    /// modification date is newer than the cached file's modification date.
    public func thumbnail(for sourceURL: URL, size: CGSize) -> URL? {
        let cacheURL = cacheURLFor(sourceURL: sourceURL, size: size)

        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }

        // Invalidate if source is newer than cache
        guard
            let sourceAttrs = try? fileManager.attributesOfItem(atPath: sourceURL.path),
            let cacheAttrs  = try? fileManager.attributesOfItem(atPath: cacheURL.path),
            let sourceMod   = sourceAttrs[.modificationDate] as? Date,
            let cacheMod    = cacheAttrs[.modificationDate]  as? Date,
            cacheMod >= sourceMod
        else { return nil }

        return cacheURL
    }

    /// Stores a thumbnail image for `sourceURL` at `size` as a JPEG file in the cache.
    /// Triggers LRU eviction if the cache exceeds `maxCacheSizeBytes` after writing.
    public func store(_ image: NSImage, for sourceURL: URL, size: CGSize) {
        guard
            let tiff   = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let jpeg   = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.85])
        else { return }

        let cacheURL = cacheURLFor(sourceURL: sourceURL, size: size)
        try? jpeg.write(to: cacheURL)
        evictIfNeeded()
    }

    /// Removes all entries from the cache directory.
    public func clearAll() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents { try? fileManager.removeItem(at: url) }
    }

    // MARK: Cache key

    /// Deterministic URL-safe cache key encoding path + file attributes + size.
    func cacheKey(for sourceURL: URL, size: CGSize) -> String {
        let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        let modDate  = (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let raw = "\(sourceURL.path)|\(fileSize)|\(modDate)|\(Int(size.width))x\(Int(size.height))"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    func cacheURLFor(sourceURL: URL, size: CGSize) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(for: sourceURL, size: size) + ".jpg")
    }

    // MARK: LRU eviction

    /// Deletes the least-recently-accessed cache files until total size is under the limit.
    private func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        // Sort oldest-accessed first
        let sorted = contents.compactMap { url -> (URL, Int, Date)? in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard let size = vals?.fileSize, let date = vals?.contentAccessDate else { return nil }
            return (url, size, date)
        }.sorted { $0.2 < $1.2 }

        var total = sorted.reduce(0) { $0 + $1.1 }
        for (url, size, _) in sorted {
            guard total > maxCacheSizeBytes else { break }
            try? fileManager.removeItem(at: url)
            total -= size
        }
    }
}
#endif
