// tools/music/Tests/MusicTests/SourceAppStationSearchTests.swift
//
// The adapter that lets Radio's `/` search reach the MusicTUISource app over
// its disposable `slice.*` wire. These drive request shaping and reply decoding
// through an injected transport, with no socket: that is the half that can be
// silently wrong in a way a person sees as a broken search, and the socket half
// is verified live against the running app instead.
//
// TEMPORARY, with the adapter. When the public contract package replaces the
// slice wire, this file goes with it.
import XCTest
@testable import music

final class SourceAppStationSearchTests: XCTestCase {

    private func search(replying reply: String,
                        capture: ((String) -> Void)? = nil) -> SourceAppStationSearch {
        SourceAppStationSearch(path: "/unused") { _, line in
            capture?(line)
            return reply
        }
    }

    private let oneStation = """
    {"ok":true,"op":"slice.searchStations","stations":[\
    {"id":"ra.978194965","name":"Apple Music 1",\
    "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965",\
    "is_live":true,"artwork_url":"https://example.invalid/art/512x512sr.jpg"}]}
    """

    // MARK: request shaping

    func testAsksForStationsNotSongs() throws {
        var sent = ""
        _ = try search(replying: oneStation, capture: { sent = $0 }).searchStations(term: "jazz")

        let body = try XCTUnwrap(sent.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["op"] as? String, "slice.searchStations",
                       "the adapter must ask for stations; slice.search returns songs and albums")
        XCTAssertEqual(json["term"] as? String, "jazz")
        XCTAssertEqual(json["limit"] as? Int, 25)
    }

    // MARK: decoding

    func testDecodesAStationIntoTheShapeRadioAlreadyRenders() throws {
        let hits = try search(replying: oneStation).searchStations(term: "apple")
        XCTAssertEqual(hits.count, 1)
        let station = try XCTUnwrap(hits.first)
        XCTAssertEqual(station.id, "ra.978194965")
        XCTAssertEqual(station.name, "Apple Music 1")
        XCTAssertEqual(station.url, "https://music.apple.com/us/station/apple-music-1/ra.978194965")
        XCTAssertEqual(station.isLive, true)
        XCTAssertEqual(station.artworkURL, "https://example.invalid/art/512x512sr.jpg")
    }

    // A station is played by rewriting its share URL's scheme, so the URL is the
    // one field that cannot be absent. The app drops URL-less stations before
    // they reach the wire; this pins that the adapter never invents one.
    func testEveryDecodedStationCarriesAPlayableURL() throws {
        let hits = try search(replying: oneStation).searchStations(term: "apple")
        for station in hits {
            XCTAssertFalse(station.url.isEmpty, "a station with no URL cannot be played")
        }
    }

    func testEmptyStationsIsZeroHitsAndNotAnError() throws {
        let hits = try search(replying: #"{"ok":true,"op":"slice.searchStations","stations":[]}"#)
            .searchStations(term: "nothing")
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: failure mapping — the whole point of the step is that these are
    // reported rather than papered over with a REST fallback.

    func testUnauthorizedIsReportedAsSuch() {
        let reply = #"{"ok":false,"op":"slice.searchStations","error":{"kind":"unauthorized","detail":"no access"}}"#
        XCTAssertThrowsError(try search(replying: reply).searchStations(term: "x")) { error in
            XCTAssertEqual(error as? SourceAppError, .notAuthorized)
        }
    }

    func testOtherRefusalsCarryTheirDetail() {
        let reply = #"{"ok":false,"op":"slice.searchStations","error":{"kind":"bad_request","detail":"empty term"}}"#
        XCTAssertThrowsError(try search(replying: reply).searchStations(term: "x")) { error in
            XCTAssertEqual(error as? SourceAppError, .refused("empty term"))
        }
    }

    // An `ok` reply with no `stations` key is a broken peer, not an empty
    // result: an honest zero-hit reply carries an empty array. Reporting it as
    // "no stations found" would blame the catalogue for a wire defect.
    func testOkWithNoStationsKeyIsUnreadableNotEmpty() {
        XCTAssertThrowsError(
            try search(replying: #"{"ok":true,"op":"slice.searchStations"}"#).searchStations(term: "x")
        ) { error in
            XCTAssertEqual(error as? SourceAppError, .unreadable)
        }
    }

    func testGarbageReplyIsUnreadable() {
        XCTAssertThrowsError(try search(replying: "not json at all").searchStations(term: "x")) { error in
            XCTAssertEqual(error as? SourceAppError, .unreadable)
        }
    }

    func testTransportFailurePropagatesAsNotRunning() {
        let adapter = SourceAppStationSearch(path: "/unused") { _, _ in throw SourceAppError.notRunning }
        XCTAssertThrowsError(try adapter.searchStations(term: "x")) { error in
            XCTAssertEqual(error as? SourceAppError, .notRunning)
        }
    }

    // MARK: the messages a person actually reads

    func testEveryFailureSaysSomethingActionable() {
        XCTAssertEqual(SourceAppError.notRunning.message, "Bridge is not running")
        XCTAssertEqual(SourceAppError.notAuthorized.message, "Bridge has no Apple Music access")
        XCTAssertTrue(SourceAppError.refused("boom").message.contains("boom"))
        XCTAssertEqual(SourceAppError.unreadable.message, "Bridge sent an unreadable reply")
    }
}
