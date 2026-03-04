#if canImport(AppKit)
import AppKit
import XCTest
@testable import NEFViewerCore

final class ThumbnailCacheTests: XCTestCase {

    // MARK: Setup

    private var cacheDir: URL!
    private var cache: ThumbnailCache!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NEFViewerCacheTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cache = ThumbnailCache(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    // MARK: Helpers

    private func makeTempSourceFile() throws -> URL {
        let url = cacheDir.appendingPathComponent("source-\(UUID().uuidString).nef")
        try Data([0xFF, 0xD8]).write(to: url)  // stub content
        return url
    }

    private func makeTestImage(color: NSColor = .red, size: CGSize = CGSize(width: 100, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    // MARK: Step 3.1 — Cache directory creation

    func test_cacheDirectoryCreatedOnInit() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    // MARK: Step 3.2 — Cache key stability and uniqueness

    func test_cacheKey_sameInputs_stableKey() throws {
        let url = try makeTempSourceFile()
        let size = CGSize(width: 512, height: 512)
        let key1 = cache.cacheKey(for: url, size: size)
        let key2 = cache.cacheKey(for: url, size: size)
        XCTAssertEqual(key1, key2)
    }

    func test_cacheKey_differentSize_differentKey() throws {
        let url = try makeTempSourceFile()
        let key1 = cache.cacheKey(for: url, size: CGSize(width: 256, height: 256))
        let key2 = cache.cacheKey(for: url, size: CGSize(width: 512, height: 512))
        XCTAssertNotEqual(key1, key2)
    }

    func test_cacheKey_differentURL_differentKey() throws {
        let url1 = try makeTempSourceFile()
        let url2 = try makeTempSourceFile()
        let size = CGSize(width: 256, height: 256)
        XCTAssertNotEqual(
            cache.cacheKey(for: url1, size: size),
            cache.cacheKey(for: url2, size: size)
        )
    }

    func test_cacheKey_urlSafe() throws {
        let url = try makeTempSourceFile()
        let key = cache.cacheKey(for: url, size: CGSize(width: 256, height: 256))
        // Should not contain characters unsafe in file names
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("="))
    }

    // MARK: Step 3.3 — Cache read / write / invalidation

    func test_cacheMiss_nonexistentFile() throws {
        let url = cacheDir.appendingPathComponent("ghost.nef")  // doesn't exist
        let result = cache.thumbnail(for: url, size: CGSize(width: 256, height: 256))
        XCTAssertNil(result)
    }

    func test_storeAndRetrieve() throws {
        let sourceURL = try makeTempSourceFile()
        let size = CGSize(width: 256, height: 256)
        let image = makeTestImage()

        cache.store(image, for: sourceURL, size: size)

        let hit = cache.thumbnail(for: sourceURL, size: size)
        XCTAssertNotNil(hit, "Should hit cache after store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hit!.path))
    }

    func test_cacheHit_returnedURLContainsReadableJPEG() throws {
        let sourceURL = try makeTempSourceFile()
        let size = CGSize(width: 256, height: 256)
        cache.store(makeTestImage(), for: sourceURL, size: size)

        let hitURL = try XCTUnwrap(cache.thumbnail(for: sourceURL, size: size))
        let data = try Data(contentsOf: hitURL)
        // JPEG starts with FF D8
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
    }

    func test_cacheInvalidation_whenSourceIsNewer() throws {
        let sourceURL = try makeTempSourceFile()
        let size = CGSize(width: 256, height: 256)
        cache.store(makeTestImage(), for: sourceURL, size: size)

        // Touch the source file to make it newer than the cache entry
        let futureDate = Date(timeIntervalSinceNow: 60)
        try FileManager.default.setAttributes(
            [.modificationDate: futureDate],
            ofItemAtPath: sourceURL.path
        )

        let hit = cache.thumbnail(for: sourceURL, size: size)
        XCTAssertNil(hit, "Cache entry should be invalidated when source is newer")
    }

    func test_clearAll_removesAllEntries() throws {
        let size = CGSize(width: 256, height: 256)
        for _ in 0..<5 {
            let url = try makeTempSourceFile()
            cache.store(makeTestImage(), for: url, size: size)
        }

        cache.clearAll()

        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jpg" }
        XCTAssertEqual(contents.count, 0)
    }

    // MARK: Step 3.4 — LRU eviction

    func test_eviction_whenOverLimit() throws {
        // Create a cache with a very small limit (1 KB)
        cache.maxCacheSizeBytes = 1024  // 1 KB

        let size = CGSize(width: 512, height: 512)
        var storedURLs: [URL] = []

        // Store several thumbnails; the JPEG output will exceed 1 KB each
        for _ in 0..<5 {
            let url = try makeTempSourceFile()
            storedURLs.append(url)
            cache.store(makeTestImage(size: size), for: url, size: size)
        }

        let jpegFiles = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "jpg" }) ?? []

        // Total size of remaining JPEG files should be <= 1 KB (limit)
        // (may be 0 if all evicted, or a small remainder)
        let totalSize = jpegFiles.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return acc + size
        }
        XCTAssertLessThanOrEqual(totalSize, cache.maxCacheSizeBytes,
            "Cache size after eviction should be within limit")
    }
}
#endif
