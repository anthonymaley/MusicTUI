import XCTest
@testable import music

/// S8 (score step C3, item 1): the chosen row is track k of the copy by
/// POSITION, confirmed by title, artist and length; never shifted, never
/// searched.
final class DiscoverSubscriptionStartTests: XCTestCase {

    // MARK: - Harness

    private func hexID(_ n: Int) -> String { String(format: "%016X", n) }
    private func ids(_ count: Int) -> [String] { (1...max(count, 1)).prefix(count).map(hexID) }

    /// Five rows, "Song 1"... by "Artist", each 200 000 ms.
    private let rows = dfhRows(Array(repeating: .milliseconds(200_000), count: 5))

    private func track(_ title: String = "Song 3", artist: String = "Artist",
                       ms: Int? = 200_000) -> DiscoverCopyTrack {
        DiscoverCopyTrack(title: title, artist: artist, durationMS: ms)
    }

    private func row(title: String, artist: String? = "Artist", length: RowLength = .milliseconds(200_000)) -> [DiscoverItem] {
        [DiscoverItem(id: "1", name: title, subtitle: artist, url: nil, artworkURL: nil,
                      detail: .song, length: length)]
    }

    /// One row against one copy track: does the title (or artist) pair pass?
    private func titleResult(_ shown: String, _ copy: String) -> DiscoverStart {
        discoverSubscriptionStart(rows: row(title: shown), selected: 0, copyIDs: ids(1),
                                  trackK: track(copy))
    }

    private func artistResult(_ shown: String, _ copy: String) -> DiscoverStart {
        discoverSubscriptionStart(rows: row(title: "Song", artist: shown), selected: 0, copyIDs: ids(1),
                                  trackK: track("Song", artist: copy))
    }

    private var passes: DiscoverStart { .start(k: 1, path: ids(1)) }

    // MARK: - The match

    func testAMatchStartsAtCursorPlusOneWithTheExactPath() {
        let result = discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(5), trackK: track())
        XCTAssertEqual(result, .start(k: 3, path: [hexID(1), hexID(2), hexID(3)]))
    }

    func testKEqualsOneAndKEqualsN() {
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 0, copyIDs: ids(5), trackK: track("Song 1")),
                       .start(k: 1, path: [hexID(1)]))
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 4, copyIDs: ids(5), trackK: track("Song 5")),
                       .start(k: 5, path: ids(5)))
    }

    // MARK: - Range and count

    func testSelectionOutsideTheRowsRefuses() {
        for selected in [-1, 5] {
            XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: selected, copyIDs: ids(5), trackK: track()),
                           .refuse(.selectionOutOfRange))
        }
        XCTAssertEqual(discoverSubscriptionStart(rows: [], selected: 0, copyIDs: [], trackK: track()),
                       .refuse(.selectionOutOfRange))
    }

    func testACountOffByOneEitherWayRefuses() {
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(4), trackK: track()),
                       .refuse(.countDiffers(rows: 5, copy: 4)))
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(6), trackK: track()),
                       .refuse(.countDiffers(rows: 5, copy: 6)))
    }

    // MARK: - Title and artist: CH3 and nothing else

    func testCaseDifferencesPassForTitleAndArtist() {
        XCTAssertEqual(titleResult("In The Middle", "In the Middle"), passes)
        XCTAssertEqual(artistResult("In The Middle", "In the Middle"), passes)
        XCTAssertEqual(titleResult("I", "i"), passes)
        XCTAssertEqual(artistResult("I", "i"), passes)
    }

    /// The locale-independent pin: under a Turkish locale 'İ' and 'ı' would
    /// fold to 'i'. Here they never do.
    func testDottedAndDotlessIDoNotFoldToI() {
        XCTAssertEqual(titleResult("İ", "i"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("ı", "i"), .refuse(.titleDiffers))
        XCTAssertEqual(artistResult("İ", "i"), .refuse(.artistDiffers))
        XCTAssertEqual(artistResult("ı", "i"), .refuse(.artistDiffers))
    }

    func testPunctuationAccentFeatAndSuffixDifferencesRefuse() {
        XCTAssertEqual(titleResult("In the Middle!", "In the Middle"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("In thé Middle", "In the Middle"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("In the Middle (feat. Someone)", "In the Middle"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("In the Middle - Remastered", "In the Middle"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("In the Middle", "In the Middle (Live)"), .refuse(.titleDiffers))
        XCTAssertEqual(titleResult("Middle", "In the Middle"), .refuse(.titleDiffers), "never a substring match")
        XCTAssertEqual(artistResult("Artist", "Artist & Friend"), .refuse(.artistDiffers))
        XCTAssertEqual(artistResult("Beyoncé", "Beyonce"), .refuse(.artistDiffers))
    }

    func testWhitespaceOnlyDifferencesPass() {
        XCTAssertEqual(titleResult("  In  the\tMiddle ", "In the Middle"), passes)
        XCTAssertEqual(titleResult("In\u{00A0}the Middle", "In the Middle"), passes)
        XCTAssertEqual(artistResult("The  Artist\n", " The Artist"), passes)
    }

    func testNFCAndNFDFormsOfTheSameTextPass() {
        let nfc = "Caf\u{00E9}"
        let nfd = "Cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        XCTAssertEqual(titleResult(nfc, nfd), passes)
        XCTAssertEqual(artistResult(nfd, nfc), passes)
    }

    func testAMissingArtistOnTheRowMatchesOnlyAnEmptyArtist() {
        let noArtist = row(title: "Song", artist: nil)
        XCTAssertEqual(discoverSubscriptionStart(rows: noArtist, selected: 0, copyIDs: ids(1),
                                                 trackK: track("Song", artist: "")), passes)
        XCTAssertEqual(discoverSubscriptionStart(rows: noArtist, selected: 0, copyIDs: ids(1),
                                                 trackK: track("Song", artist: "Artist")), .refuse(.artistDiffers))
    }

    func testNormalisationIsExactlyCH3() {
        XCTAssertEqual(discoverNormalizedForMatch("  In  The\tMiddle "), "in the middle")
        XCTAssertEqual(discoverNormalizedForMatch("Straße"), discoverNormalizedForMatch("STRASSE"))
        XCTAssertNotEqual(discoverNormalizedForMatch("İ"), "i")
        XCTAssertNotEqual(discoverNormalizedForMatch("ı"), "i")
        XCTAssertNotEqual(discoverNormalizedForMatch("In thé Middle"), discoverNormalizedForMatch("In the Middle"))
        XCTAssertEqual(discoverNormalizedForMatch("Don't, Stop!"), "don't, stop!")
    }

    // MARK: - Length

    func testALengthUnderOneSecondApartPassesAndOneSecondRefuses() {
        for ms in [200_999, 199_001] {
            XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(5), trackK: track(ms: ms)),
                           .start(k: 3, path: Array(ids(5).prefix(3))), "\(ms)")
        }
        for ms in [201_000, 199_000] {
            XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(5), trackK: track(ms: ms)),
                           .refuse(.lengthDiffers(deltaMS: 1000)), "\(ms)")
        }
    }

    func testALengthMissingOnEitherSideRefuses() {
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(5), trackK: track(ms: nil)),
                       .refuse(.copyLengthMissing))
        for length in [RowLength.null, .absent, .malformed] {
            XCTAssertEqual(discoverSubscriptionStart(rows: row(title: "Song", length: length), selected: 0,
                                                     copyIDs: ids(1), trackK: track("Song")),
                           .refuse(.rowLengthMissing), "\(length)")
        }
    }

    // MARK: - Position is fixed

    /// A song was inserted above the chosen one in Apple's copy, so the song
    /// he chose now sits one position down. The count is made equal on purpose
    /// (one dropped from the end): track k is a different song, and the answer
    /// is a refusal, never the shifted row.
    func testTheMatchingSongOnePositionAwayRefuses() {
        // He chose row 3 ("Song 3"). In the copy, track 3 is "Song 2" and track 4 is "Song 3".
        let result = discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: ids(5), trackK: track("Song 2"))
        XCTAssertEqual(result, .refuse(.titleDiffers))
    }

    // MARK: - IDs

    func testAMalformedIDWithinThePathRefusesAtItsPosition() {
        for bad in ["", "ABC", "000000000000000g", "000000000000000a", "00000000000000001", "ÀÀÀÀÀÀÀÀ"] {
            var copy = ids(5)
            copy[1] = bad
            XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: copy, trackK: track()),
                           .refuse(.malformedID(position: 2)), bad)
        }
    }

    func testARepeatedIDWithinThePathRefusesAtTheRepeat() {
        var copy = ids(5)
        copy[2] = copy[0]
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: copy, trackK: track()),
                       .refuse(.repeatedID(position: 3)))
    }

    func testAMalformedOrRepeatedIDBeyondKDoesNotMatter() {
        var malformed = ids(5)
        malformed[4] = "nope"
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: malformed, trackK: track()),
                       .start(k: 3, path: Array(ids(5).prefix(3))))
        var repeated = ids(5)
        repeated[3] = repeated[0]
        XCTAssertEqual(discoverSubscriptionStart(rows: rows, selected: 2, copyIDs: repeated, trackK: track()),
                       .start(k: 3, path: Array(ids(5).prefix(3))))
    }
}
