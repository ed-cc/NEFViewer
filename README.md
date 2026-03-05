# NEFViewer

A macOS application for efficient viewing and thumbnail generation of Nikon NEF raw files, with a focus on performance over network shares (SMB/NAS).

## Overview

NEFViewer enables viewing, preview and thumbnails for Nikon HE★/HE compressed NEF files.

NEFViewer provides:
- **Finder thumbnail integration** — Custom icons in Finder for `.nef` files
- **Quick Look preview** — Space Bar preview for full-resolution JPEG viewing
- **Bandwidth optimization** — Extracts only the embedded JPEG (~1–2 MB) instead of downloading the full file
- **EXIF metadata reading** — Camera settings, ISO, focal length, etc.

## Building and Installation

### Requirements
- macOS 13+ (Ventura)
- Xcode 14+
- Swift 5.9+

### Build
```bash
cd NEFViewer
xcodebuild build -scheme NEFViewer
```

### Installation
Run the built application once to register the extensions:
```bash
open build/Release/NEFViewer.app
```

Once the app runs, the Finder thumbnail and Quick Look preview extensions are registered. You can then quit the app — the extensions remain active.

## How It Works

### Embedded JPEG Extraction

Nikon NEF files are TIFF-based containers with multiple embedded images:
- **IFD#0**: Tiny 160×120 thumbnail
- **SubIFD#1 (JpgFromRaw)**: Full-resolution JPEG with Picture Control settings applied
- **SubIFD#2**: Raw sensor data (Lossless/HE★/HE compressed)

The key insight: **every NEF file contains a full-resolution JPEG**, regardless of compression mode. NEFViewer:

1. Opens the file and reads the TIFF header (~8 bytes)
2. Parses the IFD chain to find SubIFD#1 location (~32–64 KB read)
3. Extracts the byte offset and length of the embedded JPEG
4. Performs a single ranged read of only the JPEG data (~1–2 MB)

For a typical Z6III NEF:
- **Full file**: 15–50 MB
- **Embedded JPEG**: 1–2 MB
- **Bandwidth saved**: 80–95%

### Quick Look Extensions

#### Thumbnail Provider (QLThumbnailProvider)
Invoked by Finder when displaying file icons. The extension:
1. Extracts the embedded JPEG using ranged reads
2. Scales to the requested size
3. Returns to Finder

#### Preview Provider (QLPreviewingController)
Invoked when user presses Space Bar in Finder. Currently displays the embedded JPEG at full resolution.

## Testing

Run unit tests:
```bash
xcodebuild test -scheme NEFViewerCore
```

Tests include:
- TIFF/IFD parsing on synthetic and real NEF files
- Embedded JPEG extraction
- Metadata reading
- Byte-order handling (big-endian, little-endian)

Test fixtures include real NEF samples:
- `lossless.nef` (Lossless compressed)
- `he_star.nef` (HE★ compressed)

## Contributing

Found a bug or have a suggestion? Please open an issue or create a pull request.

---

**Last updated**: March 2026
