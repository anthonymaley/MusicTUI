import XCTest
import Foundation
@testable import music

final class PlaylistBrowserModelTests: XCTestCase {
    // badge derivation
    func testRecentBadgeFromKnownName() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: true, specialKind: "Music"), .recent)
        XCTAssertEqual(playlistBadge(name: "Top 25 Most Played", isSmart: true, specialKind: "Music"), .recent)
    }
    func testSmartBadge() {
        XCTAssertEqual(playlistBadge(name: "Deep House Finds", isSmart: true, specialKind: "none"), .smart)
    }
    func testNoneBadgeForPlainUserPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Bluecoats 2024", isSmart: false, specialKind: "none"), .none)
    }
    func testAppleBadgeForSubscriptionPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Loops", isSmart: false, specialKind: "none", isSubscription: true), .apple)
    }
    func testAppleWinsOverSmart() {
        // `smart` errors on subscription playlists and defaults false, but if a
        // future read ever reports true, the Apple identity is the useful badge.
        XCTAssertEqual(playlistBadge(name: "Replay 2022", isSmart: true, specialKind: "none", isSubscription: true), .apple)
    }
    func testRecentWinsOverApple() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: false, specialKind: "none", isSubscription: true), .recent)
    }

    // subscription-aware rail fetch parsing
    func testParseRailNamesSplitsUserAndSubscription() {
        let raw = "U\u{1F}Working Vibes\nS\u{1F}Loops\nU\u{1F}__queue__ leftover\nS\u{1F}Replay 2022\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Working Vibes", "Loops", "Replay 2022"])
        XCTAssertEqual(parsed.subscription, ["Loops", "Replay 2022"])
    }
    func testParseRailNamesTolerantOfMalformedLines() {
        let raw = "garbage-no-sep\nU\u{1F}Real One\n\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Real One"])
        XCTAssertTrue(parsed.subscription.isEmpty)
    }
    /// Discover's temp playlists must be as invisible as the queue's. A user
    /// should never see a __discover__ uuid in their Playlists tab.
    func testRailNamesHideDiscoverTempPlaylists() {
        let raw = "U\u{1F}My Mix\nU\u{1F}__discover__ 8B1F\nU\u{1F}__queue__ House\nU\u{1F}Chill"
        XCTAssertEqual(parseRailPlaylistNames(raw).names, ["My Mix", "Chill"])
    }

    /// `__temp__` containers are playback plumbing and are hidden from the
    /// rail too. Anthony's product call, 2026-09-03: they are ephemeral,
    /// cleanup-eligible, and Music.app still exposes them for inspection.
    func testRailNamesHideTempPlaylists() {
        let raw = "U\u{1F}My Mix\nU\u{1F}__temp__1756789012\nU\u{1F}Chill"
        XCTAssertEqual(parseRailPlaylistNames(raw).names, ["My Mix", "Chill"])
    }

    /// The boundary: matching is by PREFIX, so a user's own playlist that
    /// merely contains the token stays visible and unchanged. Hiding it would
    /// be deleting a name the user chose, from their view, on a substring.
    func testRailNamesKeepNonPrefixedPlaylistContainingTheToken() {
        let raw = "U\u{1F}my __temp__ mix\nU\u{1F}Best of __temp__\nU\u{1F}__temp__9\nU\u{1F}Chill"
        XCTAssertEqual(parseRailPlaylistNames(raw).names,
                       ["my __temp__ mix", "Best of __temp__", "Chill"])
    }

    /// The same three boundaries at the predicate the search filter uses
    /// (`LibrarySearch.swift` filters playlist hits through this).
    func testIsTempPlaylistNameCoversTempAndRespectsPrefixBoundary() {
        XCTAssertTrue(isTempPlaylistName("__temp__1756789012"))
        XCTAssertTrue(isTempPlaylistName("__temp__"))
        XCTAssertFalse(isTempPlaylistName("my __temp__ mix"))
        XCTAssertFalse(isTempPlaylistName("Best of __temp__"))
        XCTAssertFalse(isTempPlaylistName("My Mix"))
    }

    // duration formatting
    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(formatPlaylistDuration(15132), "4h 12m")
    }
    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(formatPlaylistDuration(360), "6m")
    }
    func testFormatDurationZero() {
        XCTAssertEqual(formatPlaylistDuration(0), "0m")
    }
    func testFormatDurationRoundsDownToMinute() {
        XCTAssertEqual(formatPlaylistDuration(59), "0m")
    }

    // zone layout
    func testThreeZonesWhenWide() {
        let z = playlistZones(width: 188)
        XCTAssertEqual(z.mode, .three)
        XCTAssertGreaterThanOrEqual(z.railWidth, 30)
        XCTAssertNotNil(z.rightX)
        XCTAssertGreaterThan(z.heroX, z.railX + z.railWidth)
        XCTAssertGreaterThan(z.rightX!, z.heroX + z.heroWidth)
    }
    func testTwoZonesMidWidth() {
        let z = playlistZones(width: 120)
        XCTAssertEqual(z.mode, .two)
        XCTAssertNil(z.rightX)
    }
    func testOneZoneNarrow() {
        let z = playlistZones(width: 80)
        XCTAssertEqual(z.mode, .one)
        XCTAssertNil(z.rightX)
    }

    // gradient determinism
    //
    // gradientBlock's contract changed from "bare glyph rows the caller wraps
    // in one flat colour" to "rows that carry their own per-cell 24-bit colour
    // escapes" (the old 4-glyph shade ramp could only ever be 4 bands — real
    // colour does the shading now). Rows are still exactly `width` VISIBLE
    // columns; escape sequences don't count toward that, so tests that need
    // visible width or per-cell identity go through the helpers below instead
    // of raw `String.count`/`Array(string)` indexing.
    func testGradientDeterministicAndSized() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let b = gradientBlock(name: "House Classics", width: 12, height: 5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5)
    }
    func testGradientDiffersByName() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let c = gradientBlock(name: "Jazz Nights", width: 12, height: 5)
        XCTAssertNotEqual(a, c)
    }

    // Old buggy formula was `idx = abs(seed + r*31 + c*7) % 4`. Since
    // 31 % 4 == 3 and 7 % 4 == 3, idx(r, c) == idx(r + 4, c) == idx(r, c + 4)
    // for every r, c — a strict 4x4 repeating tile (a basket-weave lattice),
    // not a gradient. A real ramp must show variation across a 4-row or
    // 4-column shift somewhere in the block; the old lattice never did,
    // for any name. Verified this assertion fails against the pre-fix
    // implementation (reverted locally, ran the test, saw it fail) before
    // restoring the fix.
    //
    // Colour (not glyph) now carries the ramp, so periodicity is checked on
    // the colour assigned to each VISIBLE cell (via `perCellColors`) instead
    // of the raw character grid — every glyph is the same solid block now,
    // so a raw character diff would find nothing.
    func testGradientIsNotAPeriodicLattice() {
        let width = 16, height = 16
        for name in ["House Classics", "Jazz Nights", "Deep House Finds", "Bluecoats 2024", "Replay 2022", "Loops"] {
            let block = gradientBlock(name: name, width: width, height: height)
            let grid = block.map { perCellColors($0) }

            var rowShiftDiffers = false
            for r in 0..<(height - 4) where grid[r] != grid[r + 4] {
                rowShiftDiffers = true
                break
            }
            var colShiftDiffers = false
            outer: for r in 0..<height {
                for c in 0..<(width - 4) where grid[r][c] != grid[r][c + 4] {
                    colShiftDiffers = true
                    break outer
                }
            }
            XCTAssertTrue(rowShiftDiffers || colShiftDiffers,
                           "\(name): gradient must vary across a 4-row or 4-col shift, not tile like the old lattice bug")
        }
    }

    func testGradientRowWidthMatchesRequestedWidth() {
        for (w, h) in [(1, 1), (3, 7), (12, 5), (54, 22)] {
            let block = gradientBlock(name: "Deep House Finds", width: w, height: h)
            XCTAssertEqual(block.count, h)
            for row in block {
                XCTAssertEqual(visibleWidth(row), w, "row visible-width mismatch for size \(w)x\(h)")
            }
        }
    }

    func testGradientDegenerateSizesDoNotCrash() {
        XCTAssertEqual(gradientBlock(name: "Loops", width: 0, height: 10), [])
        XCTAssertEqual(gradientBlock(name: "Loops", width: 10, height: 0), [])
        XCTAssertEqual(gradientBlock(name: "Loops", width: 0, height: 0), [])
        let single = gradientBlock(name: "Loops", width: 1, height: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(visibleWidth(single[0]), 1)
    }

    func testGradientDeterministicAcrossSizes() {
        for (w, h) in [(1, 1), (12, 5), (54, 22)] {
            let a = gradientBlock(name: "Bluecoats 2024", width: w, height: h)
            let b = gradientBlock(name: "Bluecoats 2024", width: w, height: h)
            XCTAssertEqual(a, b, "size \(w)x\(h) must be deterministic")
        }
    }

    // Every row ends in ANSICode.reset and uses only solid block glyphs —
    // never the old 4-glyph shade ramp — and every colour value is real
    // 24-bit RGB (0...255 per channel), not a clamped/garbage value.
    func testGradientRowsAreSolidBlocksWithValidColor() {
        let block = gradientBlock(name: "Deep House Finds", width: 54, height: 22)
        for row in block {
            XCTAssertTrue(row.hasSuffix(ANSICode.reset))
            XCTAssertFalse(row.contains("\u{2593}"), "dark shade glyph must not appear — colour carries the ramp now")
            XCTAssertFalse(row.contains("\u{2592}"), "medium shade glyph must not appear — colour carries the ramp now")
            XCTAssertFalse(row.contains("\u{2591}"), "light shade glyph must not appear — colour carries the ramp now")
            for m in colorEscapeMatches(row) {
                XCTAssertEqual(m.count, 3, "expected r;g;b")
                for channel in m { XCTAssertTrue((0...255).contains(channel), "channel \(channel) out of 0...255") }
            }
        }
    }

    // Performance requirement: a colour escape is emitted only when the
    // colour changes from the previous cell in that row, never once per cell
    // (that would be 54*22 = 1188 escapes/frame at the real hero size).
    // Escape count is direction-dependent (the ramp angle is seeded per
    // name): a vertical-leaning ramp holds one colour across an entire row
    // (as low as 1 escape/row), while a horizontal/diagonal one can change up
    // to `gradientSteps` times per row. Either way this must stay far under
    // the unconditional per-cell baseline.
    func testGradientEscapeCountAtRealHeroSizeStaysWellUnderPerCellBaseline() {
        let width = 54, height = 22
        let perCellBaseline = width * height   // 1188 — what unconditional-per-cell would cost
        for name in ["House Classics", "Jazz Nights", "Deep House Finds", "Bluecoats 2024", "Replay 2022", "Loops",
                     "Working Vibes", "Top 25 Most Played", "Recently Played", "A", "The Long One Right Here"] {
            let block = gradientBlock(name: name, width: width, height: height)
            let escapes = block.reduce(0) { $0 + colorEscapeMatches($1).count }
            XCTAssertGreaterThan(escapes, 0, "\(name): expected at least one colour escape")
            XCTAssertLessThan(escapes, perCellBaseline / 2,
                              "\(name): \(escapes) escapes is not meaningfully cheaper than the \(perCellBaseline) per-cell baseline")
        }
    }

    // rail name truncation
    func testRailNameTruncatesWithEllipsis() {
        let r = railName("A Very Long Playlist Name That Overflows", nameWidth: 10)
        XCTAssertEqual(r.count, 10)
        XCTAssertTrue(r.hasSuffix("\u{2026}"))
    }
    func testRailNameShortUnchanged() {
        XCTAssertEqual(railName("Short", nameWidth: 10), "Short")
    }
}

// MARK: - gradientBlock test helpers
//
// gradientBlock rows now carry embedded `\u{1B}[38;2;r;g;bm` colour escapes
// (plus a trailing ANSICode.reset), so raw `String.count`/`Array(string)`
// indexing no longer lines up with visible columns. These helpers parse that
// contract back out for assertions.

/// Visible column count — the same thing a terminal would actually draw —
/// with every `ESC [ ... m` SGR sequence stripped out first.
private func visibleWidth(_ s: String) -> Int {
    var result = 0
    var it = s.makeIterator()
    while let ch = it.next() {
        if ch == "\u{1B}" {
            _ = it.next()   // '['
            while let next = it.next(), next != "m" {}
        } else {
            result += 1
        }
    }
    return result
}

/// The colour escape active at each VISIBLE glyph position, expanded across
/// every column it covers — e.g. one escape followed by 5 glyphs yields the
/// same escape string 5 times. Lets tests diff "the colour at cell (r, c)"
/// the same way the old glyph-per-cell grid did, now that colour (not glyph)
/// carries the ramp. The trailing `ANSICode.reset` never attaches to a glyph
/// (it always comes after the last one), so it's dropped automatically.
private func perCellColors(_ row: String) -> [String] {
    var colors: [String] = []
    var currentColor = ""
    let chars = Array(row)
    var i = 0
    while i < chars.count {
        if chars[i] == "\u{1B}" {
            var esc = "\u{1B}"
            i += 1
            while i < chars.count {
                esc.append(chars[i])
                let done = chars[i] == "m"
                i += 1
                if done { break }
            }
            currentColor = esc
        } else {
            colors.append(currentColor)
            i += 1
        }
    }
    return colors
}

/// Every `\u{1B}[38;2;r;g;bm` foreground-colour escape in `s`, as `[r, g, b]`
/// triples — `ANSICode.reset` (`\u{1B}[0m`) doesn't match this shape, so it's
/// excluded automatically.
private func colorEscapeMatches(_ s: String) -> [[Int]] {
    guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[38;2;(\\d+);(\\d+);(\\d+)m") else { return [] }
    let ns = s as NSString
    let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    return matches.map { m in
        (1...3).map { Int(ns.substring(with: m.range(at: $0))) ?? -1 }
    }
}
