# Nikon NEF Raw File Viewer for macOS
## Technical Research Report & Implementation Plan

---

## 1. Background: How Nikon RAW (NEF) Files Work

### 1.1 The NEF Container Format

Nikon Electronic Format (NEF) files are based on the **TIFF/EP standard** — specifically the TIFF 6.0 container format with proprietary extensions. This means a NEF file is structurally a TIFF file and can be partially parsed using standard TIFF-reading logic. The file begins with an 8-byte TIFF header pointing to the first Image File Directory (IFD), which chains to further IFDs and SubIFDs containing the various image layers embedded in the file.

A typical NEF from a modern Nikon camera (such as the Z6III) contains three distinct image layers:

- **IFD#0 / Thumbnail**: A tiny 160×120 uncompressed RGB TIFF image used for in-camera menu display
- **SubIFD#1 (JpgFromRaw)**: A full-resolution JPEG — effectively the camera's "baked" JPEG rendered from the raw sensor data, with all Picture Control settings applied. On the Z6III this is a 6048×4032 JPEG at Basic compression (~1:16). This is stored at a known byte offset and length in the file's SubIFD metadata.
- **SubIFD#2**: The actual RAW sensor data, in one of the compression modes described below
- **MakerNote IFD**: Nikon-proprietary metadata including NikonImagePreview (tag 0x0011) which holds a medium-size JPEG preview (~570×375)

### 1.2 Compression Modes on the Nikon Z6III

The Z6III offers three NEF compression options, each with significant differences in software support:

**Lossless Compression**
The traditional Nikon lossless JPEG-like compression. A reversible algorithm that reduces file size by approximately 20–40% with no data loss. This format is well-understood and supported universally — by LibRaw, Apple Core Image RAW, Adobe Camera Raw, and virtually all raw processing software.

**High Efficiency★ (HE★)**
The higher-quality variant of Nikon's new lossy compression. Produces files comparable in quality to lossless but significantly smaller. Reduces file size by approximately 35–55%. This format is built on **TICO-RAW** (TIny COdec), a patented compression technology developed by **intoPIX**. Software vendors must license the intoPIX SDK to decode this format. This is a critical constraint: open-source libraries (LibRaw, dcraw) cannot support HE★ due to the patent, and **Apple's Core Image RAW does not support it as of macOS Sequoia** — meaning Finder, Preview.app, and Photos.app all fail to display HE★ NEF files.

**High Efficiency (HE)**
The more aggressive lossy variant. Smaller files than HE★, at some quality cost. Same TICO-RAW basis, same licensing requirement, same macOS compatibility gap.

The software compatibility landscape as of early 2026:

| Software | Lossless | HE★ | HE |
|---|---|---|---|
| Apple Core Image RAW (Finder/Preview) | ✅ | ❌ | ❌ |
| Adobe Camera Raw / Lightroom | ✅ | ✅ | ✅ |
| Capture One | ✅ | ✅ | ✅ |
| Affinity Photo 2.6+ | ✅ | ✅ (via Nikon SDK) | ✅ |
| LibRaw (open source) | ✅ | ❌ | ❌ |
| Nikon NX Studio | ✅ | ✅ | ✅ |
| Camera RawX (macOS extension) | ✅ | ✅ | ✅ |
| DxO PhotoLab 5.9+ | ✅ | ✅ (via intoPIX SDK) | ✅ |

---

## 2. SDK and Decoding Library Options

### 2.1 Apple Core Image RAW

Apple's built-in RAW decoder is used by Finder, Preview, and Photos. It requires no licensing and integrates seamlessly with macOS. However, it does **not support HE/HE★ formats** and Apple's update cadence for new cameras is slow. For lossless NEF files, this is the easiest and most performant path — rendering is done in hardware on Apple Silicon via Core Image GPU pipelines.

**API**: `CIFilter`, `CIRAWFilter` (macOS 12+), `CGImageSource`

### 2.2 Nikon Image SDK

Nikon offers a free-of-charge Image SDK available via application at `sdk.nikonimaging.com`. Notably, the SDK does **not expose raw sensor data** — it delivers a pre-processed, demosaiced bitmap image (essentially Nikon's own conversion). This makes it unsuitable for photographers who need full raw processing control, but perfectly adequate for generating **previews and Finder icons**. It supports all NEF formats including HE/HE★ and is the approach used by Affinity Photo 2.6.

**Pros**: Supports HE/HE★, free to obtain, covers all Nikon cameras
**Cons**: Requires an application process, no open redistribution, not open source, delivers processed image rather than raw data

### 2.3 intoPIX TICO-RAW SDK

The underlying technology behind HE/HE★. Available for licensing from intoPIX (`intopix.com`). This is a commercial SDK requiring a paid license agreement. It provides full decode access to the TICO-RAW compressed sensor data. Used by DxO, Topaz, and others. ARM-native support was added in September 2022.

**Pros**: Full HE/HE★ decode capability, ARM-native
**Cons**: Commercial licensing cost, adds dependency complexity

### 2.4 Adobe DNG SDK

Adobe's open, royalty-free SDK for reading and writing DNG files (`helpx.adobe.com/camera-raw/digital-negative.html`). The DNG SDK 1.7.1 (released January 2026) can read DNG files converted from NEF. It does not natively decode proprietary NEF compression but is useful when paired with Adobe's DNG Converter as a pre-processing step. The SDK is free and the specification is publicly documented.

**Use case for this project**: Not ideal for direct NEF reading, but could be used to handle DNG-converted files as a fallback.

### 2.5 LibRaw

The most widely-used open-source RAW decoding library. It supports lossless NEF reliably and is used by Darktable, RawTherapee, and many others. HE/HE★ support is absent due to the patent situation and is unlikely to arrive until TICO-RAW patents expire. Available under LGPL/CDDL licensing.

**Use case**: Best choice for lossless NEF; absolutely no HE/HE★ support.

### 2.6 The Embedded JPEG Approach (Key Insight)

This is the most important technical insight for the SMB bandwidth problem. Every Nikon NEF file — **regardless of compression mode, including HE★ and HE** — contains a full-resolution JPEG embedded inside the TIFF/IFD structure. This JPEG is stored at a known byte offset recorded in SubIFD#1 as EXIF tags `0x0201` (JpgFromRawStart) and `0x0202` (JpgFromRawLength).

Crucially, to read this JPEG you do **not** need to download or decode the raw sensor data. The process is:

1. Read the first few kilobytes of the NEF file to parse the TIFF header and IFD chain
2. Locate the SubIFD#1 offset from the main IFD
3. Read SubIFD#1 tags to find `JpgFromRawStart` and `JpgFromRawLength`
4. Perform a single ranged byte-read at that offset for exactly `JpgFromRawLength` bytes
5. Decode the resulting JPEG

For a Z6III file, this full-resolution JPEG is typically **1–2 MB**, while the entire NEF file (HE★) may be 15–25 MB. For lossless NEF files the full file may be 30–50 MB. **Fetching only the embedded JPEG can reduce the network read by 80–95%** compared to downloading the full raw file. This makes it the optimal strategy for Finder icon generation over SMB shares.

The embedded JPEG has one caveat: it reflects the camera's Picture Control settings (sharpening, contrast, color profile) baked in, so it is not suitable for professional raw processing workflows. For icon/thumbnail purposes, it is ideal.

---

## 3. macOS Finder Integration: How It Works

macOS provides two extension points for Finder integration:

### 3.1 Quick Look Thumbnail Extension (QLThumbnailProvider)

This is the primary mechanism for providing custom file icons in Finder. Introduced as a modern Swift API at WWDC 2019 (replacing the older CF plug-in generator system), it runs as a sandboxed app extension.

The extension subclasses `QLThumbnailProvider` and implements `provideThumbnail(for:_:)`. The system calls this when Finder needs an icon for a file matching the declared UTI types. The extension receives a `QLFileThumbnailRequest` with the file URL and requested size, and returns a `QLThumbnailReply` containing the rendered image. The system caches results automatically.

**Important constraint**: The extension must be bundled inside a macOS application that lives in `/Applications`. The app must be run at least once to register the extensions. This is a sandboxing requirement — the extension runs in a separate process with limited file access.

### 3.2 Quick Look Preview Extension (QLPreviewProvider)

This powers the Space Bar preview and the Finder column view sidebar preview. A `QLPreviewController` presents a view provided by your extension when the user activates Quick Look on a file. This is appropriate for full-resolution viewing.

### 3.3 UTI Declaration

Both extensions require registering a Uniform Type Identifier (UTI) for the `.nef` file type in the app's `Info.plist`. The appropriate UTI for NEF files is `com.nikon.nef`. The app's UTI declaration tells macOS to associate the extension with files of that type.

---

## 4. The SMB Bandwidth Problem & Solutions

### 4.1 Problem Statement

When NEF files are stored on an SMB (Server Message Block) network share — a NAS, a file server, or a cloud-synced folder — macOS Finder's default behaviour is to download the entire file before it can generate a thumbnail. A 30–50 MB lossless NEF file requires a full 30–50 MB download just to show an icon. With hundreds of files in a folder, this creates severe network congestion and slow Finder rendering.

### 4.2 Solution: Ranged HTTP/SMB Reads of the Embedded JPEG

The embedded JPEG approach described in Section 2.6 is the direct answer to this problem. Since NEF is a TIFF-based format, the IFD metadata (typically within the first 1–64 KB of the file) contains the byte offset and length of the embedded JPEG. Using `NSFileHandle` or Swift's low-level file I/O, a Quick Look extension can:

1. Open the remote file handle (SMB presents as a local file path on macOS via `/Volumes/`)
2. Read only the first ~64 KB to parse the IFD chain
3. Seek to the exact offset of the embedded JPEG
4. Read only those specific bytes

Modern SMB implementations (SMB 2.0+) on macOS support random-access reads at arbitrary offsets, so this does not require downloading the full file. The OS will issue ranged read requests to the server. The savings are substantial: approximately **1–2 MB transferred instead of 15–50 MB per file**.

---

## 5. Implementation Plan

### 5.1 Architecture Overview

The application consists of four components:

```
NEFViewer.app (Main Application)
├── NEFViewerCore.framework (shared Swift package)
│   ├── NEFParser          — TIFF/IFD parser, embedded JPEG extractor
│   ├── ThumbnailCache     — Local LRU disk cache
│   ├── RAWDecoder         — Full raw decode (via Core Image / Nikon SDK)
│   └── MetadataReader     — EXIF extraction
├── ThumbnailExtension     — QLThumbnailProvider (Finder icons)
├── PreviewExtension       — QLPreviewProvider (Space Bar preview)
└── SpotlightExtension     — NSMetadataImporter (search metadata)
```

### 5.2 Phase 1: Embedded JPEG Extractor

**Goal**: Read the embedded JPEG from any NEF file with minimal byte reads.

**File**: `Sources/NEFViewerCore/NEFParser.swift`

```swift
import Foundation

struct NEFEmbeddedJPEG {
    let offset: UInt32
    let length: UInt32
}

class NEFParser {

    enum NEFError: Error {
        case notTIFF
        case jpgFromRawNotFound
        case readError
    }

    /// Parses NEF IFD chain to locate the JpgFromRaw embedded JPEG.
    /// Only reads the first ~64 KB of the file (IFD metadata).
    /// Returns byte offset and length to enable a ranged read.
    static func findEmbeddedJPEG(at url: URL) throws -> NEFEmbeddedJPEG {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NEFError.readError
        }
        defer { handle.closeFile() }

        // Read TIFF header (8 bytes)
        let header = handle.readData(ofLength: 8)
        guard header.count == 8 else { throw NEFError.notTIFF }

        // Determine byte order
        let byteOrder = header.withUnsafeBytes { ptr -> UInt16 in
            ptr.load(as: UInt16.self)
        }
        let isLittleEndian = byteOrder == 0x4949 // "II"

        // Verify TIFF magic number (42)
        let magic = readUInt16(data: header, offset: 2, littleEndian: isLittleEndian)
        guard magic == 42 else { throw NEFError.notTIFF }

        // First IFD offset
        let ifdOffset = readUInt32(data: header, offset: 4, littleEndian: isLittleEndian)

        // Read IFD chain to find SubIFD tag (0x014a)
        // Then read SubIFD#1 to find JpgFromRawStart (0x0201) and JpgFromRawLength (0x0202)
        return try parseIFD(handle: handle,
                           offset: ifdOffset,
                           littleEndian: isLittleEndian)
    }

    /// Extract the embedded JPEG bytes using a ranged read.
    /// This is the key bandwidth-optimisation — only these bytes are read.
    static func extractEmbeddedJPEG(at url: URL) throws -> Data {
        let location = try findEmbeddedJPEG(at: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NEFError.readError
        }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(location.offset))
        let jpegData = handle.readData(ofLength: Int(location.length))
        guard jpegData.count == Int(location.length) else {
            throw NEFError.readError
        }
        return jpegData
    }

    // ... TIFF parsing helpers (readUInt16, readUInt32, parseIFD, parseSubIFD)
}
```

**Key implementation notes**:
- Parse IFD#0 to find the SubIFD tag (0x014a), which gives the offset to SubIFD#1
- SubIFD#1 contains tag 0x0201 (JpgFromRawStart) and 0x0202 (JpgFromRawLength)
- The JPEG data sits at that offset in the raw file bytes
- Handle both big-endian and little-endian TIFF (NEF files from modern Nikon bodies are little-endian)
- The IFD data is typically within the first 32–64 KB; read conservatively

### 5.3 Phase 2: Thumbnail Extension (Finder Icon Support)

**Goal**: Register a `QLThumbnailProvider` that supplies Finder icons for `.nef` files.

**File**: `ThumbnailExtension/ThumbnailProvider.swift`

```swift
import QuickLookThumbnailing
import AppKit
import NEFViewerCore

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maxSize = request.maximumSize

        // Step 1: Check local thumbnail cache first (zero network traffic)
        if let cached = ThumbnailCache.shared.thumbnail(for: fileURL,
                                                         size: maxSize) {
            handler(QLThumbnailReply(imageFileURL: cached), nil)
            return
        }

        // Step 2: Extract embedded JPEG (ranged read — minimal network traffic)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: fileURL)
                guard let image = NSImage(data: jpegData) else {
                    handler(nil, ThumbnailError.decodeFailure)
                    return
                }

                // Scale to requested size
                let thumbnail = image.scaled(toFit: maxSize)

                // Cache for future zero-network access
                ThumbnailCache.shared.store(thumbnail, for: fileURL, size: maxSize)

                let reply = QLThumbnailReply(contextSize: maxSize) { context in
                    thumbnail.draw(in: CGRect(origin: .zero, size: maxSize))
                    return true
                }
                handler(reply, nil)

            } catch {
                // Fallback: try Core Image RAW decode (works for lossless NEF)
                self.fallbackCoreImageThumbnail(
                    url: fileURL,
                    size: maxSize,
                    handler: handler
                )
            }
        }
    }

    private func fallbackCoreImageThumbnail(
        url: URL,
        size: CGSize,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Use CGImageSource to attempt a system-level decode
        // Works for lossless NEF; gracefully fails for HE/HE*
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            handler(nil, ThumbnailError.unsupportedFormat)
            return
        }
        let reply = QLThumbnailReply(contextSize: size) { context in
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
```

**`Info.plist` for Thumbnail Extension**:
```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>QLSupportedContentTypes</key>
        <array>
            <string>com.nikon.nef</string>
        </array>
        <key>QLThumbnailMinimumDimension</key>
        <integer>64</integer>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ThumbnailProvider</string>
</dict>
```

### 5.4 Phase 3: Quick Look Preview Extension (Space Bar Preview)

**Goal**: Full-resolution preview when user presses Space Bar on a NEF file.

**File**: `PreviewExtension/PreviewViewController.swift`

```swift
import Cocoa
import QuickLook
import NEFViewerCore

class PreviewViewController: NSViewController, QLPreviewingController {

    @IBOutlet weak var imageView: NSImageView!
    @IBOutlet weak var loadingIndicator: NSProgressIndicator!
    @IBOutlet weak var metadataLabel: NSTextField!

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        loadingIndicator.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // For preview, use embedded JPEG for speed
                // Show immediately, then upgrade to full RAW if user requests
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: url)
                let image = NSImage(data: jpegData)
                let metadata = try MetadataReader.read(from: url)

                DispatchQueue.main.async {
                    self.imageView.image = image
                    self.metadataLabel.stringValue = metadata.summaryString
                    self.loadingIndicator.stopAnimation(nil)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }
}
```

For a more complete viewer (full raw decode with colour science), Phase 3 can be extended with a `CIRAWFilter`-based decode path for lossless NEFs, and a Nikon SDK / intoPIX SDK path for HE/HE★ files.


### 5.6 Phase 5: Main Application UI

The container application (required for extension registration) doubles as a full NEF viewer with:

- **Folder browser** with thumbnail grid (served from cache)
- **Full-screen viewer** with zoom and pan
- **Metadata inspector** (EXIF, shooting data)
- **Preferences panel**: cache size limit, thumbnail quality, decode engine selection
- **"Pre-cache folder" action**: background JPEG extraction for an entire directory (useful before disconnecting from VPN/SMB)

---

## 6. Recommended Decode Engine Strategy

Based on the research above, the recommended approach for handling all Z6III NEF variants is a tiered strategy:

**Tier 1 — Icon/Thumbnail generation (all compression modes)**
Use the embedded JPEG ranged-read technique. Works for lossless, HE★, and HE. No SDK required. Minimal bandwidth (~1–2 MB per file). Fast (pure Swift TIFF parsing + JPEG decode). This handles 100% of files regardless of compression mode.

**Tier 2 — Full preview, lossless NEF only**
Use `CIRAWFilter` (Core Image RAW) for lossless compressed NEF files. This is the highest-quality path for full-resolution viewing and requires no licensing. Hardware-accelerated on Apple Silicon.

**Tier 3 — Full preview, HE/HE★ NEF**
Two options, in order of preference:
- Option A: **Nikon Image SDK** — free, requires application/approval, delivers processed image (not raw data). Suitable for viewing. Used by Affinity Photo 2.6.
- Option B: **intoPIX TICO-RAW SDK** — commercial license required, provides access to compressed sensor data. Suitable if full raw editing capability is needed.

For a preview/icon-focused tool (the scope of this plan), Option A (Nikon Image SDK) is the right choice for HE/HE★.

---

## 7. Project Structure and Technology Choices

```
NEFViewer/
├── NEFViewer.xcodeproj
├── NEFViewerCore/               ← Swift Package, shared by all targets
│   ├── Sources/NEFViewerCore/
│   │   ├── NEFParser.swift      ← TIFF/IFD parsing, JPEG extraction
│   │   ├── ThumbnailCache.swift ← Persistent LRU thumbnail cache
│   │   ├── MetadataReader.swift ← EXIF/IPTC extraction
│   │   └── RAWDecoder.swift     ← Core Image + Nikon SDK dispatch
│   └── Package.swift
├── NEFViewer/                   ← Main app target (SwiftUI)
│   ├── ContentView.swift
│   ├── ThumbnailGridView.swift
│   ├── FullscreenViewerView.swift
│   └── Info.plist               ← UTI declarations for .nef
├── ThumbnailExtension/          ← QLThumbnailProvider target
│   ├── ThumbnailProvider.swift
│   └── Info.plist
└── PreviewExtension/            ← QLPreviewingController target
    ├── PreviewViewController.swift
    └── Info.plist
```

**Language**: Swift 5.9+
**Minimum deployment**: macOS 13 Ventura (for `CIRAWFilter` API stability)
**UI framework**: SwiftUI (main app), AppKit where required by extension APIs
**No third-party dependencies** required for Phase 1 and 2 (pure Swift + system frameworks)

---

## 8. Potential Issues and Mitigations

**IFD layout variation**: While the SubIFD structure is consistent across modern Nikon bodies, older or unusual configurations may vary. Mitigation: implement a robust IFD walker that doesn't assume fixed offsets, and fall back to full-file CoreImage decode if the embedded JPEG is not found.

**Orientation**: The embedded JPEG may not be auto-rotated. The EXIF orientation tag must be read from the parent NEF's IFD (tag 0x0112) and applied manually to the decoded JPEG before display.

**HE★/HE fallback**: If the Nikon SDK is not available (not bundled, or approval pending), the app should gracefully display a placeholder with the EXIF metadata visible, rather than a broken icon.

**SMB file handles**: macOS maps SMB paths to `/Volumes/`. Swift's `FileHandle` and `Data(contentsOf:options:.mappedRead)` will work, but mapped reads on SMB may trigger full-file fetches on some servers. Prefer explicit `seek` + `readData(ofLength:)` over memory-mapping for SMB files to guarantee ranged reads.

**Cache invalidation**: When files on an SMB share are modified by another workstation, the modification date should change and the cache will automatically invalidate on next access. Monitor `FSEventStream` for local-volume files; for SMB, rely on modification date comparison.

**Sandbox restrictions**: Quick Look extensions run in a sandboxed process. The extension has read access to the file it is asked to thumbnail, but **not** to arbitrary directories. The main app must use App Sandbox entitlements with `com.apple.security.files.user-selected.read-only` or bookmark-based security-scoped access for the thumbnail cache write path.

---

## 9. Alternative Solutions Worth Considering

Before building a custom application, it is worth evaluating these existing tools:

**Camera RawX** (App Store, paid): A macOS Quick Look extension that already handles Nikon HE/HE★ files using Nikon's SDK. It provides fast Finder thumbnails and uses a "RawBridge" preprocessing approach. If the primary goal is simply fixing Finder icons on macOS, this may be the fastest path to a working solution.

**FastRawViewer**: A professional raw viewer that handles NEF culling efficiently by reading embedded previews. Not a Finder extension but very fast for image review workflows over network shares.

**Adobe DNG Converter as a workflow step**: Converting HE★ files to DNG on ingest ensures full macOS compatibility. The downside is file size increases significantly (DNG doubles file size). Not suitable for high-volume shooting.

**Shoot in Lossless NEF**: For workflows where Finder preview compatibility is critical, shooting in Lossless Compressed (rather than HE★) ensures full Apple/Finder support with no additional software. Files are larger but universally compatible.

---

## 10. Summary and Recommendations

1. **The embedded JPEG approach is the correct answer** to the SMB bandwidth problem. Every NEF file contains a full-resolution JPEG that can be read with a ranged byte fetch of ~1–2 MB instead of the full 15–50 MB file. This requires parsing the TIFF/IFD header (typically under 64 KB) to find the offset, then a single targeted read. This is feasible in pure Swift with no external dependencies.

2. **Apple Core Image RAW cannot decode HE/HE★** as of macOS Sequoia. Building a macOS tool that properly handles all Z6III NEF variants requires either the Nikon Image SDK or the commercial intoPIX SDK. For icon/preview purposes, the Nikon Image SDK (free, with application) is the appropriate choice.

3. **The application architecture** should be a macOS app with two embedded extensions — a `QLThumbnailProvider` for Finder icons and a `QLPreviewProvider` for Space Bar previews — backed by a shared Swift framework containing the TIFF parser, JPEG extractor, and thumbnail cache.

4. **A local thumbnail cache** eliminates SMB traffic entirely for repeat accesses and should be implemented as a secondary optimisation after the ranged-read approach.

5. **If immediate results are needed**, Camera RawX from the App Store already solves the Finder icon problem for HE/HE★ NEF files. A custom build is warranted if workflow integration, batch processing, or the viewing application itself is also required.

---

*Report compiled March 2026. SDK availability and macOS support status are subject to change; verify against Nikon SDK portal and Apple camera RAW compatibility pages before beginning development.*
