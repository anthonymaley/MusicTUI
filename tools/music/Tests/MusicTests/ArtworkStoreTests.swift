import XCTest
import CoreGraphics
import ImageIO
@testable import music

final class ArtworkStoreTests: XCTestCase {

    // MARK: resolveURL — both live-probed URL shapes

    func testResolveURLSubstitutesTemplate() {
        let t = "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/df/db/61/x/18UMGIM31076.rgb.jpg/{w}x{h}bb.jpg"
        XCTAssertEqual(
            ArtworkStore.resolveURL(t, width: 300, height: 300),
            "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/df/db/61/x/18UMGIM31076.rgb.jpg/300x300bb.jpg")
    }

    func testResolveURLPassesThroughPreSignedURL() {
        let t = "https://store-033.blobstore.apple.com/sq-mq-us/image?X-Amz-Expires=86400&X-Amz-Signature=abc"
        XCTAssertEqual(ArtworkStore.resolveURL(t, width: 300, height: 300), t)
    }

    // MARK: cacheKey — filesystem-safe, distinct-enough

    func testCacheKeySanitizesNonAlphanumerics() {
        XCTAssertEqual(ArtworkStore.cacheKey("p.abc123XY/z"), "p_abc123XY_z")
    }

    func testCacheKeyKeepsAlphanumerics() {
        XCTAssertEqual(ArtworkStore.cacheKey("l4bC9"), "l4bC9")
    }

    // MARK: lines() — fetch/cache/render via injected seams (no network, no chafa)

    private func tmpDir() -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testMissFetchesRendersThenHitsMemory() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return Data([1, 2, 3]) },
                                 render: { _, _, _ in ["ART"] })
        XCTAssertNil(store.lines(key: "a.1", url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: "a.1", url: "u", width: 8, height: 4) { }, ["ART"])
        XCTAssertEqual(fetches, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/a_1"))
    }

    func testDiskHitSkipsFetch() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try? Data([9]).write(to: URL(fileURLWithPath: "\(dir)/a_2"))
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in XCTFail("fetch must not run on disk hit"); return nil },
                                 render: { _, _, _ in ["DISK"] })
        XCTAssertNil(store.lines(key: "a.2", url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: "a.2", url: "u", width: 8, height: 4) { }, ["DISK"])
    }

    func testFailedFetchIsNegativeCachedForTheSession() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return nil },
                                 render: { _, _, _ in XCTFail("render must not run"); return [] })
        XCTAssertNil(store.lines(key: "a.3", url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        let settle = expectation(description: "settle"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertNil(store.lines(key: "a.3", url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        let settle2 = expectation(description: "settle2"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2)
        XCTAssertEqual(fetches, 1)
    }

    // MARK: - block() — kitty path (fetch/PNG/transmit-once via injected seams)

    /// A tiny solid-color JPEG built via CoreGraphics, for exercising the
    /// kitty PNG-conversion path without a fixture file on disk (mirrors
    /// KittyGraphicsTests' helper — kept file-local since Swift `private`
    /// helpers don't cross test files).
    private func makeSolidColorJPEGFixture() -> Data? {
        let width = 4, height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            pixelData[i] = 30; pixelData[i + 1] = 60; pixelData[i + 2] = 90; pixelData[i + 3] = 255
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

    func testBlockKittyFalseStillReturnsLines() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in Data([1, 2, 3]) },
                                 render: { _, _, _ in ["ART"] })
        XCTAssertNil(store.block(key: "k.1", url: "u", width: 8, height: 4, kitty: false) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        guard case .lines(let l) = store.block(key: "k.1", url: "u", width: 8, height: 4, kitty: false, onReady: {}) else {
            XCTFail("expected .lines"); return
        }
        XCTAssertEqual(l, ["ART"])
    }

    /// Regression test for the 3.6.0 "art shows once per session" bug: the
    /// store used to gate the transmit escape to the FIRST call per id
    /// (`transmitted: Set<UInt32>`), returning `.kitty(id:, transmit: nil)`
    /// on every call after — on the theory that the terminal's `d=i` delete
    /// kept image data resident so a bare placement could re-display it.
    /// Confirmed false live: scrolling away from a cover and back never
    /// brought it back. The store must now hand out the cached escape on
    /// EVERY call once the PNG conversion has completed, so a revisit can
    /// always re-transmit — the expensive PNG conversion itself still only
    /// runs once (see `fetches` below), and per-frame re-emission is
    /// prevented by the caller-side placement dedup, not by this store.
    func testBlockKittyTrueKeepsHandingOutTransmitOnRepeatCallsForSameID() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let jpeg = makeSolidColorJPEGFixture() else { XCTFail("failed to build JPEG fixture"); return }
        var fetches = 0
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return jpeg },
                                 render: { _, _, _ in XCTFail("render (chafa) path must not run for kitty"); return [] })
        XCTAssertNil(store.block(key: "k.2", url: "u", width: 8, height: 4, kitty: true) { ready.fulfill() })
        wait(for: [ready], timeout: 2)

        guard case .kitty(let id1, let transmit1) = store.block(key: "k.2", url: "u", width: 8, height: 4, kitty: true, onReady: {}) else {
            XCTFail("expected .kitty"); return
        }
        XCTAssertNotNil(transmit1)
        XCTAssertTrue(transmit1?.hasPrefix("\u{1B}_G") ?? false)

        // Simulate "scrolled away and back": call again for the same id.
        guard case .kitty(let id2, let transmit2) = store.block(key: "k.2", url: "u", width: 8, height: 4, kitty: true, onReady: {}) else {
            XCTFail("expected .kitty"); return
        }
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(transmit2, transmit1, "revisit must still carry the transmit escape, not nil")

        // A third call, for good measure — this is not a one-more-time gate.
        guard case .kitty(_, let transmit3) = store.block(key: "k.2", url: "u", width: 8, height: 4, kitty: true, onReady: {}) else {
            XCTFail("expected .kitty"); return
        }
        XCTAssertEqual(transmit3, transmit1)

        // The expensive part (fetch + PNG conversion) still only ran once.
        XCTAssertEqual(fetches, 1)
    }

    func testBlockKittyPNGConversionFailureIsNegativeCached() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return Data([0x00, 0x01, 0x02, 0xFF]) },
                                 render: { _, _, _ in [] })
        XCTAssertNil(store.block(key: "k.3", url: "u", width: 8, height: 4, kitty: true) { })
        let settle = expectation(description: "settle"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertNil(store.block(key: "k.3", url: "u", width: 8, height: 4, kitty: true) { XCTFail("must not refetch a negative-cached key") })
        let settle2 = expectation(description: "settle2"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2)
        XCTAssertEqual(fetches, 1)
    }

    // MARK: - renderArtHero's .none (gradient placeholder) path — square rect parity with .kitty

    /// The placeholder must occupy EXACTLY the square-equivalent rect a real
    /// kitty cover would (`kittySquareRect`), not the raw gw x gh box — a
    /// placeholder that renders taller/wider than a real cover is visibly a
    /// different shape side by side with one. At the user's real terminal
    /// (14x34px cells, 1:2.429) a 54x34 box squares to 54x22, not 54x34.
    func testPlaceholderRectMatchesKittySquareRectAtRealCellSize() {
        var out = ""
        let (pc, pr) = kittySquareRect(maxCols: 54, maxRows: 34, cellW: 14, cellH: 34)
        XCTAssertEqual(pc, 54, "sanity: kittySquareRect itself")
        XCTAssertEqual(pr, 22, "sanity: kittySquareRect itself")

        let result = renderArtHero(artBlock: nil, gradientSeedText: "Test Station",
                                   gw: 54, gh: 34, x: 1, y: 1,
                                   cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &out)

        // One moveTo + gradient row per rendered line — exactly pr (22) of
        // them, not gh (34): a moveTo targeting row 23 (pr+1) must be absent,
        // and row 1 through row pr (22) must all be present.
        for row in 1...pr {
            XCTAssertTrue(out.contains(ANSICode.moveTo(row: row, col: 1)), "missing row \(row)")
        }
        XCTAssertFalse(out.contains(ANSICode.moveTo(row: pr + 1, col: 1)), "placeholder drew a row beyond the square rect (row \(pr + 1))")
        XCTAssertEqual(out.components(separatedBy: ANSICode.reset).count - 1, pr,
                       "expected exactly \(pr) rendered gradient rows (one reset each), not gh (34)")

        // y advances by pr (22), NOT the full reserved gh (34) — that was the
        // dead-gap bug: gh grew to 34 when the hero panes were unclamped to
        // fill the pane, but the placeholder (and a real kitty cover) only
        // ever occupy pr rows, so advancing by gh left 12 dead rows between
        // the art and everything below it.
        XCTAssertEqual(result.y, 1 + pr)
    }

    // MARK: - renderArtHero: all three art paths advance y by the same amount
    // (pr), so the metadata below never jumps depending on which art path
    // rendered — the dead-gap bug and its fix, for .kitty and .lines too.

    func testKittyAdvancesYByPrNotGh() {
        var out = ""
        let (_, pr) = kittySquareRect(maxCols: 54, maxRows: 34, cellW: 14, cellH: 34)
        XCTAssertEqual(pr, 22, "sanity")
        let result = renderArtHero(artBlock: .kitty(id: 42, transmit: "ESCAPE"),
                                   gradientSeedText: "Test",
                                   gw: 54, gh: 34, x: 1, y: 1,
                                   cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &out)
        XCTAssertEqual(result.y, 1 + pr, "kitty must advance by pr (22), not gh (34)")
    }

    func testLinesAdvancesYByPrNotGhAndCropsToIt() {
        var out = ""
        let (_, pr) = kittySquareRect(maxCols: 54, maxRows: 34, cellW: 14, cellH: 34)
        // More real rows than pr (mirrors chafa's own font-ratio guess
        // typically overshooting the terminal's true measured aspect) —
        // confirms the .lines branch caps to pr like .kitty/.none, not gh.
        let art = (1...30).map { "row\($0)" }
        let result = renderArtHero(artBlock: .lines(art), gradientSeedText: "Test",
                                   gw: 54, gh: 34, x: 1, y: 1,
                                   cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &out)
        XCTAssertEqual(result.y, 1 + pr, "lines must advance by pr (22), not gh (34) or art.count (30)")
        XCTAssertTrue(out.contains("row22"), "the pr'th real row should still be drawn")
        XCTAssertFalse(out.contains("row23"), "rows beyond pr must be cropped, not drawn")
    }

    func testLinesPadsWithBlanksWhenShorterThanPr() {
        var out = ""
        let (_, pr) = kittySquareRect(maxCols: 54, maxRows: 34, cellW: 14, cellH: 34)
        // Fewer real rows than pr (chafa genuinely letterboxed short) — the
        // shortfall must still be blank-padded up to pr, not left as a gap,
        // and y must still land at the same pr-based place.
        let art = ["only one row"]
        let result = renderArtHero(artBlock: .lines(art), gradientSeedText: "Test",
                                   gw: 54, gh: 34, x: 1, y: 1,
                                   cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &out)
        XCTAssertEqual(result.y, 1 + pr)
        // Every row from 1 through pr got a moveTo (real content or blank
        // padding) — nothing left undrawn inside the reserved rect.
        for row in 1...pr {
            XCTAssertTrue(out.contains(ANSICode.moveTo(row: row, col: 1)), "missing row \(row)")
        }
    }

    func testAllThreeArtPathsAdvanceYIdentically() {
        let (_, pr) = kittySquareRect(maxCols: 54, maxRows: 34, cellW: 14, cellH: 34)
        var outNone = ""
        let yNone = renderArtHero(artBlock: nil, gradientSeedText: "Test",
                                  gw: 54, gh: 34, x: 1, y: 1, cellW: 14, cellH: 34,
                                  lastPlaced: nil, into: &outNone).y
        var outKitty = ""
        let yKitty = renderArtHero(artBlock: .kitty(id: 7, transmit: "X"), gradientSeedText: "Test",
                                   gw: 54, gh: 34, x: 1, y: 1, cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &outKitty).y
        var outLines = ""
        let yLines = renderArtHero(artBlock: .lines(["a", "b"]), gradientSeedText: "Test",
                                   gw: 54, gh: 34, x: 1, y: 1, cellW: 14, cellH: 34,
                                   lastPlaced: nil, into: &outLines).y
        XCTAssertEqual(yNone, 1 + pr)
        XCTAssertEqual(yKitty, 1 + pr)
        XCTAssertEqual(yLines, 1 + pr)
        XCTAssertEqual(yNone, yKitty)
        XCTAssertEqual(yKitty, yLines)
    }
}
