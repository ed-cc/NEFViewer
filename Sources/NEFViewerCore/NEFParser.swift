import Foundation

// MARK: - Public types

/// Locates the full-resolution embedded JPEG within a NEF (TIFF-based) file.
public struct NEFEmbeddedJPEGLocation {
    /// Byte offset of the JPEG within the NEF file.
    public let offset: UInt64
    /// Byte length of the JPEG data.
    public let length: UInt32
    /// EXIF orientation tag (0x0112), values 1–8. Defaults to 1 (no rotation).
    public let orientation: UInt16
}

public enum NEFParserError: Error, Equatable {
    case notTIFF
    case jpgFromRawNotFound
    case readError(String)
    case invalidJPEGMagic
}

// MARK: - Parser

/// Parses Nikon NEF files (TIFF/EP format) to locate and extract the embedded
/// full-resolution JPEG (JpgFromRaw), enabling bandwidth-efficient thumbnail
/// generation over SMB network shares.
///
/// All compression modes (Lossless, HE★, HE) embed a JPEG — so this path
/// works universally without requiring the Nikon or intoPIX SDKs.
public enum NEFParser {

    // MARK: Public API

    /// Parses the TIFF/IFD chain to find the JpgFromRaw location.
    /// Reads only the first ~64 KB of the file (IFD metadata only).
    public static func findEmbeddedJPEG(at url: URL) throws -> NEFEmbeddedJPEGLocation {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NEFParserError.readError("Cannot open \(url.lastPathComponent)")
        }
        defer { handle.closeFile() }
        return try findEmbeddedJPEGInHandle(handle)
    }

    /// Extracts the embedded JPEG bytes using a ranged read.
    /// Only the ~1–2 MB JPEG is transferred, not the full 15–50 MB NEF file.
    public static func extractEmbeddedJPEG(at url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NEFParserError.readError("Cannot open \(url.lastPathComponent)")
        }
        defer { handle.closeFile() }
        let location = try findEmbeddedJPEGInHandle(handle)
        return try readJPEGData(from: handle, location: location)
    }

    // MARK: Internal helpers (internal so tests can reach them)

    static func findEmbeddedJPEGInHandle(_ handle: FileHandle) throws -> NEFEmbeddedJPEGLocation {
        // --- TIFF header (8 bytes) ---
        guard let headerData = readBytes(handle: handle, at: 0, length: 8), headerData.count == 8 else {
            throw NEFParserError.notTIFF
        }

        let byteOrderMark = readUInt16(from: headerData, at: 0, littleEndian: true) // raw bytes
        let isLE: Bool
        switch byteOrderMark {
        case 0x4949: isLE = true   // "II" Intel / little-endian
        case 0x4D4D: isLE = false  // "MM" Motorola / big-endian
        default: throw NEFParserError.notTIFF
        }

        let magic = readUInt16(from: headerData, at: 2, littleEndian: isLE)
        guard magic == 42 else { throw NEFParserError.notTIFF }

        let ifd0Offset = UInt64(readUInt32(from: headerData, at: 4, littleEndian: isLE))

        // --- IFD0: find orientation + SubIFD pointer ---
        let (subIFDOffsets, orientation) = try parseIFD0(handle: handle, at: ifd0Offset, isLE: isLE)

        // --- Search each SubIFD for JpgFromRaw tags ---
        for subOffset in subIFDOffsets {
            if let jpeg = try? parseSubIFDForJPEG(handle: handle, at: UInt64(subOffset), isLE: isLE) {
                return NEFEmbeddedJPEGLocation(
                    offset: UInt64(jpeg.start),
                    length: jpeg.length,
                    orientation: orientation
                )
            }
        }

        throw NEFParserError.jpgFromRawNotFound
    }

    static func readJPEGData(from handle: FileHandle, location: NEFEmbeddedJPEGLocation) throws -> Data {
        guard let data = readBytes(handle: handle, at: location.offset, length: Int(location.length)),
              data.count == Int(location.length) else {
            throw NEFParserError.readError("Incomplete read: wanted \(location.length) bytes at offset \(location.offset)")
        }
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw NEFParserError.invalidJPEGMagic
        }
        return data
    }

    // MARK: IFD parsing

    /// Parses IFD0 to extract:
    /// - The SubIFD pointer(s) (tag 0x014a) — where JpgFromRaw lives.
    /// - The image orientation (tag 0x0112) to apply correct rotation.
    private static func parseIFD0(
        handle: FileHandle, at offset: UInt64, isLE: Bool
    ) throws -> (subIFDOffsets: [UInt32], orientation: UInt16) {
        guard let countData = readBytes(handle: handle, at: offset, length: 2) else {
            throw NEFParserError.readError("Cannot read IFD0 entry count at offset \(offset)")
        }
        let entryCount = Int(readUInt16(from: countData, at: 0, littleEndian: isLE))
        guard entryCount > 0, entryCount < 1000 else {
            throw NEFParserError.readError("Unreasonable IFD0 entry count: \(entryCount)")
        }

        guard let entries = readBytes(handle: handle, at: offset + 2, length: entryCount * 12) else {
            throw NEFParserError.readError("Cannot read IFD0 entries")
        }

        var orientation: UInt16 = 1
        var subIFDCount: UInt32 = 0
        var subIFDValue: UInt32 = 0

        for i in 0..<entryCount {
            let b = i * 12
            let tag   = readUInt16(from: entries, at: b,     littleEndian: isLE)
            let type  = readUInt16(from: entries, at: b + 2, littleEndian: isLE)
            let count = readUInt32(from: entries, at: b + 4, littleEndian: isLE)
            let value = readUInt32(from: entries, at: b + 8, littleEndian: isLE)

            switch tag {
            case 0x0112: // Orientation
                if type == 3, count == 1 { // SHORT, single value
                    // SHORT is stored in first 2 bytes of the 4-byte value field.
                    orientation = readUInt16(from: entries, at: b + 8, littleEndian: isLE)
                }
            case 0x014a: // SubIFD
                subIFDCount = count
                subIFDValue = value
            default:
                break
            }
        }

        let subIFDOffsets = try resolveSubIFDOffsets(
            handle: handle, count: subIFDCount, value: subIFDValue, isLE: isLE
        )
        return (subIFDOffsets, orientation)
    }

    /// Resolves the SubIFD offset array.
    /// If count==1 the value IS the offset; if count>1 the value is a pointer to an array.
    private static func resolveSubIFDOffsets(
        handle: FileHandle, count: UInt32, value: UInt32, isLE: Bool
    ) throws -> [UInt32] {
        guard count > 0 else { return [] }
        if count == 1 { return [value] }

        guard let data = readBytes(handle: handle, at: UInt64(value), length: Int(count) * 4) else {
            throw NEFParserError.readError("Cannot read SubIFD offset array at \(value)")
        }
        return (0..<Int(count)).map { readUInt32(from: data, at: $0 * 4, littleEndian: isLE) }
    }

    /// Scans a SubIFD for JpgFromRawStart (0x0201) and JpgFromRawLength (0x0202).
    /// Returns nil if the SubIFD doesn't contain both tags (skip to next SubIFD).
    private static func parseSubIFDForJPEG(
        handle: FileHandle, at offset: UInt64, isLE: Bool
    ) throws -> (start: UInt32, length: UInt32)? {
        guard let countData = readBytes(handle: handle, at: offset, length: 2) else { return nil }
        let entryCount = Int(readUInt16(from: countData, at: 0, littleEndian: isLE))
        guard entryCount > 0, entryCount < 1000 else { return nil }

        guard let entries = readBytes(handle: handle, at: offset + 2, length: entryCount * 12) else {
            return nil
        }

        var jpgStart: UInt32?
        var jpgLength: UInt32?

        for i in 0..<entryCount {
            let b = i * 12
            let tag   = readUInt16(from: entries, at: b,     littleEndian: isLE)
            let value = readUInt32(from: entries, at: b + 8, littleEndian: isLE)

            switch tag {
            case 0x0201: jpgStart  = value
            case 0x0202: jpgLength = value
            default: break
            }
        }

        guard let start = jpgStart, let length = jpgLength else { return nil }
        return (start, length)
    }

    // MARK: Low-level I/O

    static func readBytes(handle: FileHandle, at offset: UInt64, length: Int) -> Data? {
        handle.seek(toFileOffset: offset)
        let data = handle.readData(ofLength: length)
        return data.count == length ? data : nil
    }

    // MARK: Endian-safe integer reads

    /// Reads a UInt16 from `data` at `offset` respecting file byte order.
    static func readUInt16(from data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? b0 | (b1 << 8) : (b0 << 8) | b1
    }

    /// Reads a UInt32 from `data` at `offset` respecting file byte order.
    static func readUInt32(from data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return littleEndian
            ? b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
