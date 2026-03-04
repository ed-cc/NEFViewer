import XCTest
@testable import NEFViewerCore

final class NEFParserTests: XCTestCase {

    // MARK: Helpers

    /// Writes `data` to a temp file, runs `block` with the FileHandle, then cleans up.
    func withTempFile(_ data: Data, block: (FileHandle, URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".nef")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            XCTFail("Cannot open temp file")
            return
        }
        defer { handle.closeFile() }
        try block(handle, url)
    }

    // MARK: Step 1.1 — Endian-safe integer reads

    func test_readUInt16_littleEndian() {
        let data = Data([0x34, 0x12, 0x00, 0x00])
        XCTAssertEqual(NEFParser.readUInt16(from: data, at: 0, littleEndian: true), 0x1234)
    }

    func test_readUInt16_bigEndian() {
        let data = Data([0x12, 0x34, 0x00, 0x00])
        XCTAssertEqual(NEFParser.readUInt16(from: data, at: 0, littleEndian: false), 0x1234)
    }

    func test_readUInt32_littleEndian() {
        let data = Data([0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(NEFParser.readUInt32(from: data, at: 0, littleEndian: true), 0x12345678)
    }

    func test_readUInt32_bigEndian() {
        let data = Data([0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(NEFParser.readUInt32(from: data, at: 0, littleEndian: false), 0x12345678)
    }

    func test_readUInt16_atOffset() {
        let data = Data([0x00, 0x00, 0xAB, 0xCD])
        XCTAssertEqual(NEFParser.readUInt16(from: data, at: 2, littleEndian: true), 0xCDAB)
    }

    // MARK: Step 1.1 — TIFF header parsing (via findEmbeddedJPEGInHandle)

    func test_notTIFF_truncatedHeader() throws {
        let data = SyntheticNEF.truncatedHeader()
        try withTempFile(data) { handle, _ in
            XCTAssertThrowsError(try NEFParser.findEmbeddedJPEGInHandle(handle)) { error in
                XCTAssertEqual(error as? NEFParserError, .notTIFF)
            }
        }
    }

    func test_notTIFF_wrongMagic() throws {
        let data = SyntheticNEF.wrongMagic()
        try withTempFile(data) { handle, _ in
            XCTAssertThrowsError(try NEFParser.findEmbeddedJPEGInHandle(handle)) { error in
                XCTAssertEqual(error as? NEFParserError, .notTIFF)
            }
        }
    }

    func test_littleEndian_validHeader() throws {
        let data = SyntheticNEF.minimalLE()
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.offset, 68)
            XCTAssertEqual(location.length, 4)
        }
    }

    func test_bigEndian_validHeader() throws {
        let data = SyntheticNEF.minimalBE()
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.offset, 68)
            XCTAssertEqual(location.length, 4)
        }
    }

    // MARK: Step 1.2 — IFD chain walking / SubIFD pointer resolution

    func test_noSubIFD_throwsNotFound() throws {
        let data = SyntheticNEF.noSubIFD()
        try withTempFile(data) { handle, _ in
            XCTAssertThrowsError(try NEFParser.findEmbeddedJPEGInHandle(handle)) { error in
                XCTAssertEqual(error as? NEFParserError, .jpgFromRawNotFound)
            }
        }
    }

    func test_multiSubIFD_findsCorrectSubIFD() throws {
        let data = SyntheticNEF.multiSubIFD()
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.offset, 78)
            XCTAssertEqual(location.length, 4)
        }
    }

    // MARK: Step 1.3 — JpgFromRaw tag location

    func test_findEmbeddedJPEG_via_URL() throws {
        let data = SyntheticNEF.minimalLE()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".nef")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let location = try NEFParser.findEmbeddedJPEG(at: url)
        XCTAssertEqual(location.offset, 68)
        XCTAssertEqual(location.length, 4)
    }

    // MARK: Step 1.4 — Ranged JPEG extraction and magic validation

    func test_extractEmbeddedJPEG_returnsCorrectBytes() throws {
        let data = SyntheticNEF.minimalLE()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".nef")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let jpeg = try NEFParser.extractEmbeddedJPEG(at: url)
        XCTAssertEqual(jpeg.count, 4)
        XCTAssertEqual(jpeg[0], 0xFF)
        XCTAssertEqual(jpeg[1], 0xD8)
    }

    func test_extractEmbeddedJPEG_invalidMagic() throws {
        // Build a NEF where the "JPEG" bytes don't start with FF D8
        var data = SyntheticNEF.minimalLE()
        data[68] = 0x00  // corrupt the SOI marker
        try withTempFile(data) { _, url in
            XCTAssertThrowsError(try NEFParser.extractEmbeddedJPEG(at: url)) { error in
                XCTAssertEqual(error as? NEFParserError, .invalidJPEGMagic)
            }
        }
    }

    // MARK: Step 1.5 — EXIF orientation

    func test_orientation_normalLE() throws {
        let data = SyntheticNEF.minimalLE(orientation: 1)
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.orientation, 1)
        }
    }

    func test_orientation_rotated180_LE() throws {
        let data = SyntheticNEF.minimalLE(orientation: 3)
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.orientation, 3)
        }
    }

    func test_orientation_rotated90CW_LE() throws {
        let data = SyntheticNEF.minimalLE(orientation: 6)
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.orientation, 6)
        }
    }

    func test_orientation_normalBE() throws {
        let data = SyntheticNEF.minimalBE(orientation: 1)
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.orientation, 1)
        }
    }

    func test_orientation_rotated90CW_BE() throws {
        let data = SyntheticNEF.minimalBE(orientation: 6)
        try withTempFile(data) { handle, _ in
            let location = try NEFParser.findEmbeddedJPEGInHandle(handle)
            XCTAssertEqual(location.orientation, 6)
        }
    }

    // MARK: Real file integration (skipped unless fixture present)

    func test_realLosslessNEF_integration() throws {
        guard let url = Bundle.module.url(forResource: "lossless", withExtension: "nef",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("lossless.nef fixture not available")
        }
        let jpeg = try NEFParser.extractEmbeddedJPEG(at: url)
        XCTAssertGreaterThan(jpeg.count, 100_000, "Embedded JPEG should be at least 100 KB")
        XCTAssertEqual(jpeg[0], 0xFF)
        XCTAssertEqual(jpeg[1], 0xD8)
    }

    func test_realHEStarNEF_integration() throws {
        guard let url = Bundle.module.url(forResource: "he_star", withExtension: "nef",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("he_star.nef fixture not available")
        }
        // HE★ NEF — embedded JPEG still present regardless of RAW compression mode
        let jpeg = try NEFParser.extractEmbeddedJPEG(at: url)
        XCTAssertEqual(jpeg[0], 0xFF)
        XCTAssertEqual(jpeg[1], 0xD8)
    }
}
