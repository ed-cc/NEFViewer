import Foundation

// MARK: - Public types

/// Key shooting metadata extracted from a NEF file's EXIF IFD.
public struct NEFMetadata: Equatable {
    /// Camera make (EXIF tag 0x010f).
    public let make: String
    /// Camera model (EXIF tag 0x0110).
    public let model: String
    /// Capture date/time as a string (EXIF tag 0x9003 "DateTimeOriginal").
    public let dateTimeOriginal: String
    /// ISO speed rating (EXIF tag 0x8827).
    public let iso: UInt32
    /// Exposure time numerator/denominator (EXIF tag 0x829a), e.g. (1, 500).
    public let exposureTimeRational: (numerator: UInt32, denominator: UInt32)
    /// F-number numerator/denominator (EXIF tag 0x829d), e.g. (28, 10) → f/2.8.
    public let fNumberRational: (numerator: UInt32, denominator: UInt32)
    /// Focal length numerator/denominator (EXIF tag 0x920a), e.g. (85, 1) → 85 mm.
    public let focalLengthRational: (numerator: UInt32, denominator: UInt32)
    /// Image orientation (EXIF tag 0x0112), values 1–8.
    public let orientation: UInt16

    // MARK: Convenience formatters

    public var exposureTimeString: String {
        guard exposureTimeRational.denominator != 0 else { return "–" }
        let n = exposureTimeRational.numerator
        let d = exposureTimeRational.denominator
        if n == 1 { return "1/\(d)s" }
        let seconds = Double(n) / Double(d)
        return String(format: "%.4fs", seconds)
    }

    public var fNumberString: String {
        guard fNumberRational.denominator != 0 else { return "–" }
        let value = Double(fNumberRational.numerator) / Double(fNumberRational.denominator)
        return String(format: "f/%.1f", value)
    }

    public var focalLengthString: String {
        guard focalLengthRational.denominator != 0 else { return "–" }
        let mm = focalLengthRational.numerator / focalLengthRational.denominator
        return "\(mm) mm"
    }

    public var summaryString: String {
        "\(model) · ISO \(iso) · \(exposureTimeString) · \(fNumberString) · \(focalLengthString)"
    }

    // MARK: Equatable (manual because tuples aren't auto-Equatable)

    public static func == (lhs: NEFMetadata, rhs: NEFMetadata) -> Bool {
        lhs.make == rhs.make &&
        lhs.model == rhs.model &&
        lhs.dateTimeOriginal == rhs.dateTimeOriginal &&
        lhs.iso == rhs.iso &&
        lhs.exposureTimeRational == rhs.exposureTimeRational &&
        lhs.fNumberRational == rhs.fNumberRational &&
        lhs.focalLengthRational == rhs.focalLengthRational &&
        lhs.orientation == rhs.orientation
    }
}

public enum MetadataReaderError: Error {
    case notTIFF
    case exifIFDNotFound
    case readError(String)
}

// MARK: - Reader

/// Extracts EXIF shooting metadata from a NEF file.
/// Reads only the IFD header region — no raw sensor data is downloaded.
public enum MetadataReader {

    // MARK: Public API

    public static func read(from url: URL) throws -> NEFMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw MetadataReaderError.readError("Cannot open \(url.lastPathComponent)")
        }
        defer { handle.closeFile() }
        return try readFromHandle(handle)
    }

    // MARK: Internal

    static func readFromHandle(_ handle: FileHandle) throws -> NEFMetadata {
        // Reuse NEFParser for TIFF setup
        guard let headerData = NEFParser.readBytes(handle: handle, at: 0, length: 8),
              headerData.count == 8 else {
            throw MetadataReaderError.notTIFF
        }

        let byteOrderMark = NEFParser.readUInt16(from: headerData, at: 0, littleEndian: true)
        let isLE: Bool
        switch byteOrderMark {
        case 0x4949: isLE = true
        case 0x4D4D: isLE = false
        default: throw MetadataReaderError.notTIFF
        }

        let magic = NEFParser.readUInt16(from: headerData, at: 2, littleEndian: isLE)
        guard magic == 42 else { throw MetadataReaderError.notTIFF }

        let ifd0Offset = UInt64(NEFParser.readUInt32(from: headerData, at: 4, littleEndian: isLE))

        // Parse IFD0 for baseline tags + pointer to EXIF IFD (tag 0x8769)
        let ifd0 = try parseIFD(handle: handle, at: ifd0Offset, isLE: isLE)

        var make  = ""
        var model = ""
        var orientation: UInt16 = 1

        if let offset = ifd0[0x010f] { make        = readASCII(handle: handle, entry: offset, isLE: isLE) }
        if let offset = ifd0[0x0110] { model       = readASCII(handle: handle, entry: offset, isLE: isLE) }
        if let entry  = ifd0[0x0112] { orientation = UInt16(entry.value & 0xFFFF) }

        // Follow EXIF IFD pointer (tag 0x8769 in IFD0)
        guard let exifPointer = ifd0[0x8769] else {
            throw MetadataReaderError.exifIFDNotFound
        }
        let exifOffset = UInt64(exifPointer.value)
        let exifIFD = try parseIFD(handle: handle, at: exifOffset, isLE: isLE)

        var iso: UInt32 = 0
        var exposureNum: UInt32 = 0; var exposureDen: UInt32 = 1
        var fNum: UInt32 = 0;        var fDen: UInt32 = 1
        var focalNum: UInt32 = 0;    var focalDen: UInt32 = 1
        var dateTime = ""

        if let e = exifIFD[0x8827] { iso = e.value }   // ISOSpeedRatings (SHORT)
        if let e = exifIFD[0x829a] {                    // ExposureTime (RATIONAL)
            let r = readRational(handle: handle, valueOffset: e.value, isLE: isLE)
            exposureNum = r.0; exposureDen = r.1
        }
        if let e = exifIFD[0x829d] {                    // FNumber (RATIONAL)
            let r = readRational(handle: handle, valueOffset: e.value, isLE: isLE)
            fNum = r.0; fDen = r.1
        }
        if let e = exifIFD[0x920a] {                    // FocalLength (RATIONAL)
            let r = readRational(handle: handle, valueOffset: e.value, isLE: isLE)
            focalNum = r.0; focalDen = r.1
        }
        if let e = exifIFD[0x9003] {                    // DateTimeOriginal (ASCII)
            dateTime = readASCII(handle: handle, entry: e, isLE: isLE)
        }

        return NEFMetadata(
            make: make,
            model: model,
            dateTimeOriginal: dateTime,
            iso: iso,
            exposureTimeRational: (exposureNum, exposureDen),
            fNumberRational: (fNum, fDen),
            focalLengthRational: (focalNum, focalDen),
            orientation: orientation
        )
    }

    // MARK: IFD helpers

    /// Represents a parsed IFD entry's type/count/value triple.
    struct IFDEntry {
        let type: UInt16
        let count: UInt32
        /// Either the inline value or, for large types, the file offset to the data.
        let value: UInt32
    }

    /// Returns a tag→IFDEntry map for all entries in the IFD at `offset`.
    static func parseIFD(handle: FileHandle, at offset: UInt64, isLE: Bool) throws -> [UInt16: IFDEntry] {
        guard let countData = NEFParser.readBytes(handle: handle, at: offset, length: 2) else {
            throw MetadataReaderError.readError("Cannot read IFD entry count at \(offset)")
        }
        let count = Int(NEFParser.readUInt16(from: countData, at: 0, littleEndian: isLE))
        guard count > 0, count < 1000 else {
            throw MetadataReaderError.readError("Unreasonable IFD entry count: \(count)")
        }
        guard let entries = NEFParser.readBytes(handle: handle, at: offset + 2, length: count * 12) else {
            throw MetadataReaderError.readError("Cannot read IFD entries")
        }

        var result: [UInt16: IFDEntry] = [:]
        for i in 0..<count {
            let b = i * 12
            let tag   = NEFParser.readUInt16(from: entries, at: b,     littleEndian: isLE)
            let type  = NEFParser.readUInt16(from: entries, at: b + 2, littleEndian: isLE)
            let cnt   = NEFParser.readUInt32(from: entries, at: b + 4, littleEndian: isLE)
            let value = NEFParser.readUInt32(from: entries, at: b + 8, littleEndian: isLE)
            result[tag] = IFDEntry(type: type, count: cnt, value: value)
        }
        return result
    }

    /// Reads an ASCII string for tags where the value either fits inline or is a file offset.
    private static func readASCII(handle: FileHandle, entry: IFDEntry, isLE: Bool) -> String {
        let length = Int(entry.count)
        // If the string fits in 4 bytes, it's stored inline in the value field.
        if length <= 4 {
            var bytes = [UInt8](repeating: 0, count: 4)
            let v = entry.value
            if isLE {
                bytes[0] = UInt8(v & 0xFF)
                bytes[1] = UInt8((v >> 8) & 0xFF)
                bytes[2] = UInt8((v >> 16) & 0xFF)
                bytes[3] = UInt8((v >> 24) & 0xFF)
            } else {
                bytes[0] = UInt8((v >> 24) & 0xFF)
                bytes[1] = UInt8((v >> 16) & 0xFF)
                bytes[2] = UInt8((v >> 8) & 0xFF)
                bytes[3] = UInt8(v & 0xFF)
            }
            return String(bytes: bytes.prefix(length), encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        }
        guard let data = NEFParser.readBytes(handle: handle, at: UInt64(entry.value), length: length) else {
            return ""
        }
        return String(bytes: data, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters) ?? ""
    }

    /// Reads an unsigned rational (two UInt32 values) at the given file offset.
    private static func readRational(handle: FileHandle, valueOffset: UInt32, isLE: Bool) -> (UInt32, UInt32) {
        guard let data = NEFParser.readBytes(handle: handle, at: UInt64(valueOffset), length: 8) else {
            return (0, 1)
        }
        let num = NEFParser.readUInt32(from: data, at: 0, littleEndian: isLE)
        let den = NEFParser.readUInt32(from: data, at: 4, littleEndian: isLE)
        return (num, den)
    }
}
