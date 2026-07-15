// tools/music/Tests/MusicTests/KittyGraphicsTests.swift
import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import music

final class KittyGraphicsTests: XCTestCase {

    // MARK: - kittyGraphicsSupported: env-based detection

    func testKittyWindowIDSetImpliesSupport() {
        XCTAssertTrue(kittyGraphicsSupported(env: ["KITTY_WINDOW_ID": "1"]))
    }

    func testTermContainingKittyImpliesSupport() {
        XCTAssertTrue(kittyGraphicsSupported(env: ["TERM": "xterm-kitty"]))
    }

    func testTermProgramWezTermImpliesSupport() {
        XCTAssertTrue(kittyGraphicsSupported(env: ["TERM_PROGRAM": "WezTerm"]))
    }

    func testTermProgramGhosttyImpliesSupport() {
        XCTAssertTrue(kittyGraphicsSupported(env: ["TERM_PROGRAM": "ghostty"]))
    }

    func testITermAtOrAbove3_5ImpliesSupport() {
        XCTAssertTrue(kittyGraphicsSupported(env: [
            "TERM_PROGRAM": "iTerm.app",
            "TERM_PROGRAM_VERSION": "3.5.9",
        ]))
    }

    func testITermBelow3_5DoesNotImplySupport() {
        XCTAssertFalse(kittyGraphicsSupported(env: [
            "TERM_PROGRAM": "iTerm.app",
            "TERM_PROGRAM_VERSION": "3.4.19",
        ]))
    }

    func testAppleTerminalDoesNotImplySupport() {
        XCTAssertFalse(kittyGraphicsSupported(env: ["TERM_PROGRAM": "Apple_Terminal"]))
    }

    func testEmptyEnvDoesNotImplySupport() {
        XCTAssertFalse(kittyGraphicsSupported(env: [:]))
    }

    // MARK: - kittyImageID: deterministic, nonzero

    func testImageIDIsDeterministic() {
        XCTAssertEqual(kittyImageID(forKey: "l_abc123"), kittyImageID(forKey: "l_abc123"))
        XCTAssertEqual(kittyImageID(forKey: "p_xyz"), kittyImageID(forKey: "p_xyz"))
        XCTAssertEqual(kittyImageID(forKey: ""), kittyImageID(forKey: ""))
    }

    func testImageIDIsNonzeroForRealShapedKeys() {
        XCTAssertNotEqual(kittyImageID(forKey: "l_abc123"), 0)
        XCTAssertNotEqual(kittyImageID(forKey: "p_xyz"), 0)
        XCTAssertNotEqual(kittyImageID(forKey: ""), 0)
    }

    func testImageIDDiffersForDifferentKeys() {
        XCTAssertNotEqual(kittyImageID(forKey: "l_abc123"), kittyImageID(forKey: "p_xyz"))
    }

    // MARK: - imageDataToPNG

    func testImageDataToPNGConvertsJPEGFixture() {
        guard let jpeg = makeSolidColorJPEGFixture() else {
            XCTFail("failed to build JPEG fixture")
            return
        }
        guard let png = imageDataToPNG(jpeg) else {
            XCTFail("imageDataToPNG returned nil for a valid JPEG")
            return
        }
        // PNG magic bytes: 0x89 'P' 'N' 'G'
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        XCTAssertGreaterThanOrEqual(png.count, magic.count)
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
    }

    func testImageDataToPNGReturnsNilForGarbage() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        XCTAssertNil(imageDataToPNG(garbage))
    }

    // MARK: - kittyTransmitEscape

    func testTransmitEscapeChunksLargePayload() {
        // A payload whose base64 encoding exceeds 4096 chars: 4096 chars of
        // base64 decode to 3072 bytes, so use comfortably more than that.
        let payload = Data(repeating: 0xAB, count: 6000)
        let escape = kittyTransmitEscape(id: 42, png: payload)

        let frames = splitKittyEscapes(escape)
        XCTAssertGreaterThan(frames.count, 1, "expected more than one chunk for a >4096-char base64 payload")

        for frame in frames {
            XCTAssertTrue(frame.raw.hasPrefix("\u{1B}_G"))
            XCTAssertTrue(frame.raw.hasSuffix("\u{1B}\\"))
        }

        guard let first = frames.first, let last = frames.last else {
            XCTFail("no frames parsed")
            return
        }
        XCTAssertTrue(first.controls.contains("a=t"))
        XCTAssertTrue(first.controls.contains("f=100"))
        XCTAssertTrue(first.controls.contains("i=42"))
        XCTAssertTrue(first.controls.contains("q=2"))
        XCTAssertTrue(first.controls.contains("m=1"))
        XCTAssertTrue(last.controls.contains("m=0"))

        for frame in frames {
            XCTAssertLessThanOrEqual(frame.payload.count, 4096)
        }

        let reassembled = frames.map { $0.payload }.joined()
        guard let decoded = Data(base64Encoded: reassembled) else {
            XCTFail("reassembled base64 payload did not decode")
            return
        }
        XCTAssertEqual(decoded, payload)
    }

    func testTransmitEscapeSingleChunkHasFinalMarker() {
        let payload = Data(repeating: 0x11, count: 16)
        let escape = kittyTransmitEscape(id: 7, png: payload)
        let frames = splitKittyEscapes(escape)
        XCTAssertEqual(frames.count, 1)
        guard let only = frames.first else { return }
        XCTAssertTrue(only.controls.contains("a=t"))
        XCTAssertTrue(only.controls.contains("f=100"))
        XCTAssertTrue(only.controls.contains("i=7"))
        XCTAssertTrue(only.controls.contains("q=2"))
        XCTAssertTrue(only.controls.contains("m=0"))
        XCTAssertEqual(Data(base64Encoded: only.payload), payload)
    }

    // MARK: - kittyPlaceEscape

    func testPlaceEscapeContainsExpectedKeys() {
        let escape = kittyPlaceEscape(id: 99, cols: 12, rows: 6)
        let frames = splitKittyEscapes(escape)
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertTrue(frame.controls.contains("a=p"))
        XCTAssertTrue(frame.controls.contains("i=99"))
        XCTAssertTrue(frame.controls.contains("c=12"))
        XCTAssertTrue(frame.controls.contains("r=6"))
        XCTAssertTrue(frame.controls.contains("q=2"))
    }

    // MARK: - kittySquareRect

    // The bug this whole session exists to fix: the user's real terminal
    // measures 14x34px cells (1:2.429), not the assumed 1:2. A 44x22 placement
    // at that cell size rendered 616x748px — 21.4% taller than wide. The
    // correct rect for a 44x22 max box at 14x34 cells is 44x18 (616x612px,
    // 0.7% off square).
    func testMeasuredCellSizeProducesFortyFourByEighteen() {
        let rect = kittySquareRect(maxCols: 44, maxRows: 22, cellW: 14, cellH: 34)
        XCTAssertEqual(rect.cols, 44)
        XCTAssertEqual(rect.rows, 18)
    }

    // The historical fallback (cells assumed exactly 1:2) must reproduce
    // today's behavior exactly: cols = 2 * rows, i.e. 44x22 unchanged.
    func testOneToTwoFallbackReproducesTodaysFortyFourByTwentyTwo() {
        let rect = kittySquareRect(maxCols: 44, maxRows: 22, cellW: 1, cellH: 2)
        XCTAssertEqual(rect.cols, 44)
        XCTAssertEqual(rect.rows, 22)
    }

    func testSquareCellsClampByHeightWhenWidthWouldOverflow() {
        // Square cells (1:1): a 44-col-wide rect wants 44 rows to stay square,
        // but only 22 rows are available, so the height clamp kicks in and
        // both dimensions shrink to the smaller bound (22x22).
        let rect = kittySquareRect(maxCols: 44, maxRows: 22, cellW: 10, cellH: 10)
        XCTAssertEqual(rect.cols, 22)
        XCTAssertEqual(rect.rows, 22)
    }

    // The hero panes (Radio/Library/Playlists) no longer cap maxCols at 44 —
    // they feed the real available hero width, which is wider than the rows
    // available can fill square. At the user's real terminal (14x34 cells)
    // with, say, 80 cols and 22 rows on offer, the square rect is derived
    // from the scarcer dimension (height): pc=80 -> pr=round(80*14/34)=33,
    // which exceeds maxRows(22), so it re-derives from height: pr=22 ->
    // pc=round(22*34/14)=53.
    func testWideHeroBudgetClampsToAvailableRowsAtMeasuredCellSize() {
        let rect = kittySquareRect(maxCols: 80, maxRows: 22, cellW: 14, cellH: 34)
        XCTAssertEqual(rect.cols, 53)
        XCTAssertEqual(rect.rows, 22)
    }

    func testHeightConstrainedBoxClampsByAvailableRowsNotCols() {
        // maxRows is scarce relative to maxCols here (10 vs. 44) at a normal
        // ~1:2 cell aspect: pc=44 -> pr = round(44*10/20) = 22, which exceeds
        // maxRows(10), so the height clamp fires: pr=10 -> pc = round(10*20/10) = 20.
        let rect = kittySquareRect(maxCols: 44, maxRows: 10, cellW: 10, cellH: 20)
        XCTAssertEqual(rect.rows, 10)
        XCTAssertEqual(rect.cols, 20)
        XCTAssertLessThanOrEqual(rect.cols, 44)
    }

    func testResultNeverExceedsMaxBoxInEitherDimension() {
        // Sweep a range of cell aspects and confirm the result always fits.
        let cellSizes: [(Double, Double)] = [(1, 1), (1, 2), (2, 1), (14, 34), (34, 14), (7, 3), (3, 7)]
        for (cw, ch) in cellSizes {
            let rect = kittySquareRect(maxCols: 44, maxRows: 22, cellW: cw, cellH: ch)
            XCTAssertLessThanOrEqual(rect.cols, 44, "cw=\(cw) ch=\(ch)")
            XCTAssertLessThanOrEqual(rect.rows, 22, "cw=\(cw) ch=\(ch)")
            XCTAssertGreaterThanOrEqual(rect.cols, 0, "cw=\(cw) ch=\(ch)")
            XCTAssertGreaterThanOrEqual(rect.rows, 0, "cw=\(cw) ch=\(ch)")
        }
    }

    func testZeroOrNegativeInputsDegradeToZeroRect() {
        XCTAssertEqual(kittySquareRect(maxCols: 0, maxRows: 22, cellW: 14, cellH: 34).cols, 0)
        XCTAssertEqual(kittySquareRect(maxCols: 44, maxRows: 0, cellW: 14, cellH: 34).rows, 0)
        XCTAssertEqual(kittySquareRect(maxCols: 44, maxRows: 22, cellW: 0, cellH: 34).cols, 0)
        XCTAssertEqual(kittySquareRect(maxCols: 44, maxRows: 22, cellW: 14, cellH: 0).cols, 0)
        XCTAssertEqual(kittySquareRect(maxCols: -5, maxRows: 22, cellW: 14, cellH: 34).cols, 0)
    }

    // MARK: - kittyDeleteEscape / kittyDeleteAllEscape

    func testDeleteEscapeDeletesOnlyOneImagesPlacementsWithoutFreeingData() {
        // Lowercase d=i: delete this image's placements, keep the stored
        // data so a later placement needs no re-transmit (spec: "The
        // lowercase variant only deletes the images without necessarily
        // freeing up the stored image data").
        let escape = kittyDeleteEscape(id: 5)
        let frames = splitKittyEscapes(escape)
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertTrue(frame.controls.contains("a=d"))
        XCTAssertTrue(frame.controls.contains("d=i"))
        XCTAssertTrue(frame.controls.contains("i=5"))
        XCTAssertTrue(frame.controls.contains("q=2"))
    }

    func testDeleteAllEscapeFreesEverything() {
        // Uppercase d=A: delete every visible placement AND free the
        // underlying image data (spec: uppercase variants "delete the image
        // data as well"), so no image ghosts survive into scrollback.
        let escape = kittyDeleteAllEscape()
        let frames = splitKittyEscapes(escape)
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertTrue(frame.controls.contains("a=d"))
        XCTAssertTrue(frame.controls.contains("d=A"))
        XCTAssertTrue(frame.controls.contains("q=2"))
    }

    // MARK: - kittyDeletePlacementsEscape

    func testDeletePlacementsEscapeDeletesAllPlacementsWithoutFreeingData() {
        // Lowercase d=a: delete every placement (unscoped by id) but keep the
        // stored image data — used on scene switches so the incoming scene
        // can re-place without re-transmitting.
        let escape = kittyDeletePlacementsEscape()
        let frames = splitKittyEscapes(escape)
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertTrue(frame.controls.contains("a=d"))
        XCTAssertTrue(frame.controls.contains("d=a"))
        XCTAssertTrue(frame.controls.contains("q=2"))
        XCTAssertFalse(frame.controls.contains("d=A"))
        XCTAssertFalse(frame.controls.contains("d=i"))
    }
}

// MARK: - Test helpers

private struct KittyFrame {
    let raw: String
    let controls: [String]
    let payload: String
}

/// Split a string of one or more concatenated `ESC_G<control>;<payload>ESC\`
/// escapes into their parts, for assertions.
private func splitKittyEscapes(_ s: String) -> [KittyFrame] {
    let start = "\u{1B}_G"
    let end = "\u{1B}\\"
    var frames: [KittyFrame] = []
    var remainder = Substring(s)
    while let startRange = remainder.range(of: start) {
        guard let endRange = remainder.range(of: end, range: startRange.upperBound..<remainder.endIndex) else { break }
        let raw = String(remainder[startRange.lowerBound..<endRange.upperBound])
        let body = remainder[startRange.upperBound..<endRange.lowerBound]
        let parts = body.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let controls = parts[0].split(separator: ",").map(String.init)
        let payload = parts.count > 1 ? String(parts[1]) : ""
        frames.append(KittyFrame(raw: raw, controls: controls, payload: payload))
        remainder = remainder[endRange.upperBound...]
    }
    return frames
}

/// A tiny 4x4 solid-color JPEG built via CoreGraphics, for exercising
/// imageDataToPNG without any fixture file on disk.
private func makeSolidColorJPEGFixture() -> Data? {
    let width = 4, height = 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
    for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
        pixelData[i] = 200       // R
        pixelData[i + 1] = 80    // G
        pixelData[i + 2] = 40    // B
        pixelData[i + 3] = 255   // A
    }
    guard let context = CGContext(
        data: &pixelData, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let cgImage = context.makeImage() else { return nil }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
