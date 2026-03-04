import Foundation

/// Helpers that build minimal valid TIFF/NEF binary blobs for unit testing
/// the parser without requiring real camera files.
enum SyntheticNEF {

    // MARK: - Minimal NEF (little-endian)

    /// Builds a synthetic LE NEF binary with:
    ///   IFD0 → orientation tag (0x0112) + SubIFD pointer (0x014a, 1 sub-IFD)
    ///   SubIFD1 → JpgFromRawStart (0x0201) + JpgFromRawLength (0x0202)
    ///   JPEG stub at the specified offset (SOI + EOI = 0xFF 0xD8 0xFF 0xD9)
    ///
    /// Layout (all offsets in decimal bytes):
    ///   0  – TIFF header (8 bytes)
    ///   8  – IFD0 (2 + 2×12 + 4 = 30 bytes)
    ///   38 – SubIFD1 (2 + 2×12 + 4 = 30 bytes)
    ///   68 – JPEG stub (4 bytes)
    ///   Total: 72 bytes
    static func minimalLE(orientation: UInt16 = 1) -> Data {
        var d = Data()

        // TIFF header
        d += bytes(UInt16(0x4949))          // byte order "II" (little-endian)
        d += bytes(UInt16(42))              // TIFF magic
        d += bytes(UInt32(8))              // IFD0 at offset 8

        // IFD0 at offset 8: 2 entries
        d += bytes(UInt16(2))

        // Entry: Orientation (0x0112), type SHORT (3), count 1, value = orientation
        d += ifdEntry(tag: 0x0112, type: 3, count: 1, value: UInt32(orientation))

        // Entry: SubIFD (0x014a), type LONG (4), count 1, value = SubIFD1 offset (38)
        d += ifdEntry(tag: 0x014A, type: 4, count: 1, value: 38)

        // Next IFD offset (none)
        d += bytes(UInt32(0))
        // IFD0 ends at 8 + 2 + 24 + 4 = 38 ✓

        // SubIFD1 at offset 38: 2 entries
        d += bytes(UInt16(2))

        let jpegOffset: UInt32 = 68
        let jpegLength: UInt32 = 4   // SOI + EOI

        // Entry: JpgFromRawStart (0x0201), type LONG, count 1, value = jpegOffset
        d += ifdEntry(tag: 0x0201, type: 4, count: 1, value: jpegOffset)

        // Entry: JpgFromRawLength (0x0202), type LONG, count 1, value = jpegLength
        d += ifdEntry(tag: 0x0202, type: 4, count: 1, value: jpegLength)

        // Next SubIFD offset (none)
        d += bytes(UInt32(0))
        // SubIFD1 ends at 38 + 2 + 24 + 4 = 68 ✓

        // JPEG stub: minimal SOI + EOI
        d += Data([0xFF, 0xD8, 0xFF, 0xD9])
        // Total: 72 bytes ✓

        assert(d.count == 72, "Synthetic NEF should be 72 bytes, got \(d.count)")
        return d
    }

    // MARK: - Minimal NEF (big-endian)

    /// Same structure as `minimalLE` but with big-endian byte order ("MM").
    static func minimalBE(orientation: UInt16 = 1) -> Data {
        var d = Data()

        d += beBytes(UInt16(0x4D4D))       // "MM"
        d += beBytes(UInt16(42))
        d += beBytes(UInt32(8))

        d += beBytes(UInt16(2))

        d += beShortIfdEntry(tag: 0x0112, count: 1, value: orientation)
        d += beIfdEntry(tag: 0x014A, type: 4, count: 1, value: 38)

        d += beBytes(UInt32(0))

        d += beBytes(UInt16(2))

        let jpegOffset: UInt32 = 68
        let jpegLength: UInt32 = 4

        d += beIfdEntry(tag: 0x0201, type: 4, count: 1, value: jpegOffset)
        d += beIfdEntry(tag: 0x0202, type: 4, count: 1, value: jpegLength)

        d += beBytes(UInt32(0))

        d += Data([0xFF, 0xD8, 0xFF, 0xD9])

        assert(d.count == 72)
        return d
    }

    // MARK: - Multi-SubIFD NEF (SubIFD array, count > 1)

    /// Builds a synthetic NEF where the SubIFD tag has count=2:
    ///   SubIFD[0] = a small IFD with no JPEG tags (should be skipped by the parser)
    ///   SubIFD[1] = the JpgFromRaw IFD
    ///
    /// Layout:
    ///   0   – TIFF header (8 bytes)
    ///   8   – IFD0 (2 + 1×12 + 4 = 18 bytes) [only SubIFD tag, no orientation]
    ///   26  – SubIFD offset array [subIFD0=42, subIFD1=48] (8 bytes)
    ///   34  – padding to 42 (8 bytes)
    ///   42  – SubIFD0: 0 entries (6 bytes) — skipped by parser (no JPEG tags)
    ///   48  – SubIFD1: 2 entries — JpgFromRaw (30 bytes)
    ///   78  – JPEG stub (4 bytes)
    ///   Total: 82 bytes
    static func multiSubIFD() -> Data {
        var d = Data()

        // Header
        d += bytes(UInt16(0x4949))
        d += bytes(UInt16(42))
        d += bytes(UInt32(8))

        // IFD0 at 8: 1 entry (SubIFD only, no orientation)
        d += bytes(UInt16(1))

        // SubIFD tag: count=2, value = offset to offset array (26)
        d += ifdEntry(tag: 0x014A, type: 4, count: 2, value: 26)
        d += bytes(UInt32(0))  // next IFD = 0
        // IFD0 ends at 8 + 2 + 12 + 4 = 26 ✓

        // SubIFD offset array at 26: two LONG offsets
        let subIFD0Offset: UInt32 = 42
        let subIFD1Offset: UInt32 = 48  // subIFD0 (6 bytes) ends at 48
        d += bytes(subIFD0Offset)
        d += bytes(subIFD1Offset)
        // 26 + 8 = 34

        // Pad to 42
        d += Data(repeating: 0, count: 42 - d.count)

        // SubIFD0 at 42: 0 entries (no JPEG tags) — parser should skip it
        d += bytes(UInt16(0))  // 0 entries
        d += bytes(UInt32(0))  // next SubIFD = 0
        // 42 + 2 + 4 = 48 ✓

        // SubIFD1 at 48: 2 entries (JpgFromRaw)
        d += bytes(UInt16(2))

        let jpegOffset: UInt32 = 78
        let jpegLength: UInt32 = 4

        d += ifdEntry(tag: 0x0201, type: 4, count: 1, value: jpegOffset)
        d += ifdEntry(tag: 0x0202, type: 4, count: 1, value: jpegLength)
        d += bytes(UInt32(0))
        // SubIFD1 ends at 48 + 2 + 24 + 4 = 78 ✓

        // JPEG stub at 78
        d += Data([0xFF, 0xD8, 0xFF, 0xD9])

        return d
    }

    // MARK: - Corrupt data helpers

    static func truncatedHeader() -> Data {
        Data([0x49, 0x49, 0x2A])  // only 3 bytes — too short
    }

    static func wrongMagic() -> Data {
        var d = Data()
        d += bytes(UInt16(0x4949))
        d += bytes(UInt16(99))   // should be 42
        d += bytes(UInt32(8))
        return d
    }

    static func noSubIFD() -> Data {
        var d = Data()
        d += bytes(UInt16(0x4949))
        d += bytes(UInt16(42))
        d += bytes(UInt32(8))
        d += bytes(UInt16(1))
        // Only an orientation tag, no SubIFD tag
        d += ifdEntry(tag: 0x0112, type: 3, count: 1, value: 1)
        d += bytes(UInt32(0))
        return d
    }

    // MARK: - Private helpers

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func beBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Builds a 12-byte little-endian IFD entry.
    private static func ifdEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        bytes(tag) + bytes(type) + bytes(count) + bytes(value)
    }

    /// 12-byte big-endian IFD entry for LONG (4-byte) values.
    private static func beIfdEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        beBytes(tag) + beBytes(type) + beBytes(count) + beBytes(value)
    }

    /// 12-byte big-endian IFD entry for SHORT (2-byte) values.
    /// Per TIFF spec, a SHORT stored in the 4-byte value field is left-justified
    /// in the file's byte order: [hi, lo, 0x00, 0x00] for big-endian.
    private static func beShortIfdEntry(tag: UInt16, count: UInt32, value: UInt16) -> Data {
        beBytes(tag) + beBytes(UInt16(3)) + beBytes(count) + beBytes(value) + beBytes(UInt16(0))
    }
}
