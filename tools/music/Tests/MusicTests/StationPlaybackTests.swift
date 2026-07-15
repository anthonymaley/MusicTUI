import XCTest
@testable import music

final class StationPlaybackTests: XCTestCase {
    func testRewritesHttpsToMusicScheme() {
        XCTAssertEqual(
            stationPlayURL("https://music.apple.com/us/station/apple-music-1/ra.978194965"),
            "music://music.apple.com/us/station/apple-music-1/ra.978194965")
    }

    func testAlreadyMusicSchemePassesThrough() {
        XCTAssertEqual(
            stationPlayURL("music://music.apple.com/us/station/x/ra.1"),
            "music://music.apple.com/us/station/x/ra.1")
    }

    /// A pasted ALBUM url must be rejected — music:// would silently play an
    /// album, which looks like a bug in radio.
    func testRejectsNonStationPaths() {
        XCTAssertNil(stationPlayURL("https://music.apple.com/us/album/humanz/1234"))
        XCTAssertNil(stationPlayURL("https://music.apple.com/us/playlist/chill/pl.1"))
    }

    func testRejectsForeignHosts() {
        XCTAssertNil(stationPlayURL("https://example.com/us/station/x/ra.1"))
        XCTAssertNil(stationPlayURL("https://evil.com/station/x/ra.1"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(stationPlayURL(""))
        XCTAssertNil(stationPlayURL("not a url"))
    }

    func testParsesSlugAndID() {
        let p = parseStationURL("https://music.apple.com/us/station/bbc-radio-1/ra.1460912634")
        XCTAssertEqual(p?.id, "ra.1460912634")
        XCTAssertEqual(p?.slug, "bbc-radio-1")
    }

    /// The API cannot resolve BBC Radio 1 — the slug is the only name we get.
    func testDisplayNameFromSlug() {
        XCTAssertEqual(displayNameFromSlug("bbc-radio-1"), "Bbc Radio 1")
        XCTAssertEqual(displayNameFromSlug("apple-music-chill"), "Apple Music Chill")
        XCTAssertEqual(displayNameFromSlug("apple-m%C3%BAsica-uno"), "Apple Música Uno")
    }

    func testPlayStationUsesTheOpenerSeam() throws {
        final class SpyOpener: Opener {
            var opened: [String] = []
            func open(_ url: String) throws { opened.append(url) }
        }
        let spy = SpyOpener()
        let s = Station(id: "ra.1", name: "X", url: "https://music.apple.com/us/station/x/ra.1",
                        isLive: nil, artworkURL: nil)
        try playStation(s, via: spy)
        XCTAssertEqual(spy.opened, ["music://music.apple.com/us/station/x/ra.1"])
    }

    func testPlayStationThrowsOnBadURL() {
        final class SpyOpener: Opener {
            var opened: [String] = []
            func open(_ url: String) throws { opened.append(url) }
        }
        let spy = SpyOpener()
        let s = Station(id: "x", name: "X", url: "https://example.com/nope",
                        isLive: nil, artworkURL: nil)
        XCTAssertThrowsError(try playStation(s, via: spy))
        XCTAssertTrue(spy.opened.isEmpty)
    }
}
