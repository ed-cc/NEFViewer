import XCTest
@testable import NEFViewerCore

final class MetadataReaderTests: XCTestCase {

    // MARK: Synthetic EXIF NEF builder

    /// Builds a minimal TIFF/NEF binary containing:
    ///   IFD0: make, model, orientation, ExifIFD pointer
    ///   ExifIFD: ISO, ExposureTime, FNumber, FocalLength, DateTimeOriginal
    private func makeSyntheticEXIFNEF(
        make: String  = "Nikon",
        model: String = "Z 6III",
        orientation: UInt16 = 1,
        iso: UInt16 = 800,
        // ExposureTime as rational (e.g. 1/500)
        expNum: UInt32 = 1, expDen: UInt32 = 500,
        // FNumber as rational (e.g. 28/10 = f/2.8)
        fnNum: UInt32 = 28, fnDen: UInt32 = 10,
        // FocalLength as rational (e.g. 85/1 = 85mm)
        flNum: UInt32 = 85, flDen: UInt32 = 1,
        dateTime: String = "2026:03:04 12:00:00"
    ) -> Data {
        // We build the binary bottom-up, then assemble.
        // All values are little-endian.

        func le<T: FixedWidthInteger>(_ v: T) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
            le(tag) + le(type) + le(count) + le(value)
        }

        // ── Collect out-of-line data blocks ──────────────────────────────────
        // We need to place: make ASCII, model ASCII, dateTime ASCII,
        // expTime rational, fNumber rational, focalLength rational,
        // and the ExifIFD itself.
        //
        // Strategy: lay out IFD0 first (with placeholder offsets), then ExifIFD,
        // then all the variable-length data.

        let makeBytes  = Data((make  + "\0").utf8)
        let modelBytes = Data((model + "\0").utf8)
        let dtBytes    = Data((dateTime + "\0").utf8)  // 20 bytes inc NUL

        // Offsets (calculated after knowing IFD0 and ExifIFD sizes)
        // IFD0: 8 (header) + 2 (count) + 7×12 (entries) + 4 (next) = 98
        let ifd0Offset: UInt32 = 8
        let ifd0EntryCount = 7  // make, model, orientation, ExifIFD pointer, + 3 reserved = actually 4 in IFD0
        // IFD0 has: Make(0x010f), Model(0x0110), Orientation(0x0112), ExifIFD(0x8769) → 4 entries
        let ifd0Size = 2 + 4 * 12 + 4  // = 54
        let exifOffset: UInt32 = ifd0Offset + UInt32(ifd0Size)  // = 62

        // ExifIFD has: ISO(0x8827), ExposureTime(0x829a), FNumber(0x829d),
        //              FocalLength(0x920a), DateTimeOriginal(0x9003) → 5 entries
        let exifSize = 2 + 5 * 12 + 4  // = 66
        let dataStart: UInt32 = exifOffset + UInt32(exifSize)  // = 128

        // Variable data layout starting at dataStart:
        var dataBlock = Data()
        let makeOff  = dataStart + UInt32(dataBlock.count); dataBlock += makeBytes
        let modelOff = dataStart + UInt32(dataBlock.count); dataBlock += modelBytes
        let dtOff    = dataStart + UInt32(dataBlock.count); dataBlock += dtBytes
        // Rationals (8 bytes each)
        let expOff   = dataStart + UInt32(dataBlock.count); dataBlock += le(expNum) + le(expDen)
        let fnOff    = dataStart + UInt32(dataBlock.count); dataBlock += le(fnNum)  + le(fnDen)
        let flOff    = dataStart + UInt32(dataBlock.count); dataBlock += le(flNum)  + le(flDen)

        // ── Assemble ─────────────────────────────────────────────────────────
        var d = Data()

        // TIFF header
        d += le(UInt16(0x4949))  // II
        d += le(UInt16(42))      // magic
        d += le(ifd0Offset)

        // IFD0 at offset 8
        _ = ifd0EntryCount  // suppress unused warning
        d += le(UInt16(4))  // 4 entries

        // Make (ASCII, offset)
        d += entry(tag: 0x010f, type: 2, count: UInt32(makeBytes.count),  value: makeOff)
        // Model (ASCII, offset)
        d += entry(tag: 0x0110, type: 2, count: UInt32(modelBytes.count), value: modelOff)
        // Orientation (SHORT, inline)
        d += entry(tag: 0x0112, type: 3, count: 1, value: UInt32(orientation))
        // ExifIFD pointer (LONG)
        d += entry(tag: 0x8769, type: 4, count: 1, value: exifOffset)

        d += le(UInt32(0))  // no next IFD
        // IFD0 ends at 8 + 54 = 62 ✓

        // ExifIFD at offset 62
        d += le(UInt16(5))  // 5 entries

        // ISOSpeedRatings (SHORT, inline)
        d += entry(tag: 0x8827, type: 3, count: 1, value: UInt32(iso))
        // ExposureTime (RATIONAL, offset)
        d += entry(tag: 0x829a, type: 5, count: 1, value: expOff)
        // FNumber (RATIONAL, offset)
        d += entry(tag: 0x829d, type: 5, count: 1, value: fnOff)
        // FocalLength (RATIONAL, offset)
        d += entry(tag: 0x920a, type: 5, count: 1, value: flOff)
        // DateTimeOriginal (ASCII, offset)
        d += entry(tag: 0x9003, type: 2, count: UInt32(dtBytes.count), value: dtOff)

        d += le(UInt32(0))  // no next ExifIFD
        // ExifIFD ends at 62 + 66 = 128 ✓

        // Variable data block
        d += dataBlock

        assert(d.count == Int(dataStart) + dataBlock.count)
        return d
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".nef")
        try data.write(to: url)
        return url
    }

    // MARK: Step 2.1 — Basic field extraction

    func test_model() throws {
        let data = makeSyntheticEXIFNEF(model: "Z 6III")
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.model, "Z 6III")
    }

    func test_make() throws {
        let data = makeSyntheticEXIFNEF(make: "Nikon")
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.make, "Nikon")
    }

    func test_iso() throws {
        let data = makeSyntheticEXIFNEF(iso: 3200)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.iso, 3200)
    }

    func test_orientation() throws {
        let data = makeSyntheticEXIFNEF(orientation: 6)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.orientation, 6)
    }

    func test_exposureTime_rational() throws {
        let data = makeSyntheticEXIFNEF(expNum: 1, expDen: 500)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.exposureTimeRational.numerator, 1)
        XCTAssertEqual(meta.exposureTimeRational.denominator, 500)
    }

    func test_fNumber_rational() throws {
        let data = makeSyntheticEXIFNEF(fnNum: 28, fnDen: 10)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.fNumberRational.numerator, 28)
        XCTAssertEqual(meta.fNumberRational.denominator, 10)
    }

    func test_focalLength_rational() throws {
        let data = makeSyntheticEXIFNEF(flNum: 85, flDen: 1)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.focalLengthRational.numerator, 85)
        XCTAssertEqual(meta.focalLengthRational.denominator, 1)
    }

    func test_dateTime() throws {
        let data = makeSyntheticEXIFNEF(dateTime: "2026:03:04 12:00:00")
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.dateTimeOriginal, "2026:03:04 12:00:00")
    }

    // MARK: Convenience string formatters

    func test_exposureTimeString_fractional() throws {
        let data = makeSyntheticEXIFNEF(expNum: 1, expDen: 250)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.exposureTimeString, "1/250 s")
    }

    func test_fNumberString() throws {
        let data = makeSyntheticEXIFNEF(fnNum: 40, fnDen: 10)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.fNumberString, "f/4.0")
    }

    func test_focalLengthString() throws {
        let data = makeSyntheticEXIFNEF(flNum: 50, flDen: 1)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try MetadataReader.read(from: url)
        XCTAssertEqual(meta.focalLengthString, "50 mm")
    }

    // MARK: Error paths

    func test_notTIFF_throwsError() throws {
        let url = try writeTempFile(Data([0x00, 0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try MetadataReader.read(from: url)) { error in
            XCTAssertEqual(error as? MetadataReaderError, .notTIFF)
        }
    }

    // MARK: Real-file integration (skipped unless fixture present)

    func test_realNEF_metadata() throws {
        guard let url = Bundle.module.url(forResource: "lossless", withExtension: "nef",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("lossless.nef fixture not available")
        }
        let meta = try MetadataReader.read(from: url)
        XCTAssertFalse(meta.model.isEmpty, "Model should be non-empty")
        XCTAssertGreaterThan(meta.iso, 0, "ISO should be > 0")
    }
}

// Make MetadataReaderError Equatable for XCTAssertEqual
extension MetadataReaderError: Equatable {
    public static func == (lhs: MetadataReaderError, rhs: MetadataReaderError) -> Bool {
        switch (lhs, rhs) {
        case (.notTIFF, .notTIFF), (.exifIFDNotFound, .exifIFDNotFound): return true
        case (.readError(let a), .readError(let b)): return a == b
        default: return false
        }
    }
}
