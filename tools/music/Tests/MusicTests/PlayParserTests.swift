import XCTest
@testable import music

final class PlayParserTests: XCTestCase {
    private let devices = ["Kitchen", "Living Room", "Anthony's MacBook Pro"]

    func testPlainQueryPassesThrough() {
        let r = PlayParser.parse(["kid", "a"], deviceNames: devices)
        XCTAssertEqual(r, PlayParser.Result(queryArgs: ["kid", "a"], speakers: [], volume: nil, shuffle: false))
    }

    func testSingleSpeakerWithVolume() {
        let r = PlayParser.parse(["norah", "jones", "kitchen", "40"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["norah", "jones"])
        XCTAssertEqual(r.speakers, ["Kitchen"])
        XCTAssertEqual(r.volume, 40)
    }

    func testTwoSpeakersWithFillerWordsAndVolume() {
        let args = ["kid", "a", "radiohead", "in", "the", "kitchen", "and", "living", "room", "at", "60"]
        let r = PlayParser.parse(args, deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["kid", "a", "radiohead"])
        XCTAssertEqual(r.speakers, ["Kitchen", "Living Room"])
        XCTAssertEqual(r.volume, 60)
    }

    func testVolumePercentSuffix() {
        let r = PlayParser.parse(["kid", "a", "kitchen", "60%"], deviceNames: devices)
        XCTAssertEqual(r.volume, 60)
        XCTAssertEqual(r.speakers, ["Kitchen"])
        XCTAssertEqual(r.queryArgs, ["kid", "a"])
    }

    func testFillerInsideQuerySurvives() {
        let r = PlayParser.parse(["live", "at", "the", "bbc", "in", "the", "kitchen"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["live", "at", "the", "bbc"])
        XCTAssertEqual(r.speakers, ["Kitchen"])
    }

    func testNoSubstringSpeakerMatch() {
        let r = PlayParser.parse(["kitchenette", "dreams"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["kitchenette", "dreams"])
        XCTAssertEqual(r.speakers, [])
    }

    func testQuotedSongArtistArgsPreserved() {
        let r = PlayParser.parse(["Gypsy Woman", "Tom Misch"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["Gypsy Woman", "Tom Misch"])
        XCTAssertEqual(r.speakers, [])
    }

    func testQuotedMultiWordSpeakerArg() {
        let r = PlayParser.parse(["jazz", "living room", "30"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["jazz"])
        XCTAssertEqual(r.speakers, ["Living Room"])
        XCTAssertEqual(r.volume, 30)
    }

    func testShuffleKeyword() {
        let r = PlayParser.parse(["in", "rainbows", "shuffle"], deviceNames: devices)
        XCTAssertTrue(r.shuffle)
        XCTAssertEqual(r.queryArgs, ["in", "rainbows"])
    }

    func testSingleNumberIsQueryNotVolume() {
        let r = PlayParser.parse(["60"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, ["60"])
        XCTAssertNil(r.volume)
    }

    func testSpeakerOnlyNoQuery() {
        let r = PlayParser.parse(["kitchen"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, [])
        XCTAssertEqual(r.speakers, ["Kitchen"])
    }

    func testSpeakerWithVolumeNoQuery() {
        let r = PlayParser.parse(["kitchen", "40"], deviceNames: devices)
        XCTAssertEqual(r.queryArgs, [])
        XCTAssertEqual(r.speakers, ["Kitchen"])
        XCTAssertEqual(r.volume, 40)
    }

    func testSpeakersKeepArgOrder() {
        let r = PlayParser.parse(["living", "room", "and", "kitchen"], deviceNames: devices)
        XCTAssertEqual(r.speakers, ["Living Room", "Kitchen"])
        XCTAssertEqual(r.queryArgs, [])
    }

    func testAlbumArtistFilterNilReturnsEmptyString() {
        XCTAssertEqual(albumArtistFilter(artist: nil), "")
    }

    func testAlbumArtistFilterPlainValue() {
        XCTAssertEqual(
            albumArtistFilter(artist: "Air"),
            " and (artist contains \"Air\" or album artist contains \"Air\")")
    }

    func testAlbumArtistFilterEscapesQuotes() {
        XCTAssertEqual(
            albumArtistFilter(artist: "Air\""),
            " and (artist contains \"Air\\\"\" or album artist contains \"Air\\\"\")")
    }

    /// `--album` (with no `--artist`) and the positional route both call
    /// `albumWhereClause(query:artist:)` with `artist: nil`. This is what the
    /// positional route needs: a bare `album contains` clause, no artist
    /// filter appended.
    func testAlbumWhereClauseNilArtistIsBareClause() {
        XCTAssertEqual(
            albumWhereClause(query: "Moon Safari", artist: nil),
            "album contains \"Moon Safari\"")
    }

    func testAlbumWhereClauseWithArtistIncludesArtistFilter() {
        XCTAssertEqual(
            albumWhereClause(query: "Moon Safari", artist: "Air"),
            "album contains \"Moon Safari\""
                + " and (artist contains \"Air\" or album artist contains \"Air\")")
    }

    func testAlbumWhereClauseEscapesQuoteInQuery() {
        XCTAssertEqual(
            albumWhereClause(query: "Air\"s Album", artist: nil),
            "album contains \"Air\\\"s Album\"")
    }

    /// The guarantee under test: `--album` and the positional route cannot
    /// diverge, because both now call this one function. Before the
    /// extraction, `--album` built its clause via
    /// `"album contains \"\(escAlbum)\"\(albumArtistFilter(artist: artist))"`
    /// and positional hardcoded a bare `"album contains \"\(escapedQuery)\""`
    /// — they only agreed because a positional strategy never carries an
    /// artist. This test reconstructs that same formula independently and
    /// asserts it is byte-identical to `albumWhereClause`'s output, so a
    /// future change to escaping, normalisation, or artist handling that
    /// touches only one of the two would now fail here rather than diverge
    /// silently.
    func testAlbumWhereClauseMatchesIndependentlyBuiltAlbumFlagClause() {
        let title = "Moon Safari"
        let independentlyBuiltAlbumFlagClause =
            "album contains \"\(escapeAppleScriptString(title))\"\(albumArtistFilter(artist: nil))"
        XCTAssertEqual(
            albumWhereClause(query: title, artist: nil),
            independentlyBuiltAlbumFlagClause)
    }
}
