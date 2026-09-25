// tools/music/Tests/MusicTests/CLIBridgeRadioTests.swift
//
// Slice 3 Part 2, P7: `music radio search`, `radio add` and `radio play`
// executed through their real command paths (`runRadioSearch`, `runRadioAdd`,
// `runRadioPlay`) in both modes. The Bridge wire is scripted and records each
// request with whether the output lock was held; the mode store, lock, cache
// and favourites file are temp; the external-call tripwire is armed; the
// opener counts; nothing sleeps. No real Music.app, network, Bridge, `open`
// or ~/.config/music.
import ArgumentParser
import XCTest
@testable import music

/// Counts every URL a Music.app radio play would hand to `open`, and whether
/// the output lock was held at that moment.
final class CLIRadioCountingOpener: Opener {
    private(set) var urls: [String] = []
    private(set) var lockedDuringOpen: [Bool] = []
    var lockPath: String?
    func open(_ url: String) throws {
        urls.append(url)
        if let lockPath { lockedDuringOpen.append(!OutputLockTestSupport.isFree(lockPath)) }
    }
}

/// Station replies a scripted Bridge sends (D5's `<station>` shape).
enum CLIBridgeRadioReplies {
    static func station(_ id: String, _ name: String, slug: String? = nil, live: Bool = false) -> String {
        let s = slug ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
        return #"{"id":"\#(id)","name":"\#(name)","url":"https://music.apple.com/us/station/\#(s)/\#(id)","is_live":\#(live),"artwork_url":null}"#
    }
    static func search(_ stations: [String]) -> String {
        #"{"ok":true,"op":"slice.searchStations","stations":[\#(stations.joined(separator: ","))]}"#
    }
    static func lookup(_ station: String?) -> String {
        #"{"ok":true,"op":"slice.station","station":\#(station ?? "null")}"#
    }
    static let played = #"{"ok":true,"op":"slice.playStation"}"#
}

final class CLIBridgeRadioTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias Q = CLIBridgeRadioReplies

    private let ready = CLIBridgeReplies.status()
    private let appleMusic1URL = "https://music.apple.com/us/station/apple-music-1/ra.978194965"

    private func favourites(_ h: H, _ stations: [Station] = []) throws -> StationStore {
        let path = h.directory + "/stations.json"
        XCTAssertTrue(isUnderTemporaryDirectory(path))
        let store = StationStore(path: path)
        for s in stations { try store.add(s) }
        return StationStore(path: path)   // a fresh reader, as a new process would be
    }

    private func fav(_ id: String, _ name: String) -> Station {
        Station(id: id, name: name, url: "https://music.apple.com/us/station/x/\(id)", isLive: nil, artworkURL: nil)
    }

    /// Runs `body` with the tripwire armed; returns its error and every
    /// AppleScript/REST call that reached a funnel.
    private func tripwired(_ body: () throws -> Void) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire { do { try body() } catch { thrown = error } }.calls
        return (thrown, calls)
    }

    private func bridgeRadioPlay(_ h: H, _ query: [String], stations: StationStore,
                                 opener: CLIRadioCountingOpener = CLIRadioCountingOpener())
        -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runRadioPlay(query: query, env: h.env, opener: opener, stations: stations)
        }
    }

    // MARK: - radio search

    func testBridgeRadioSearchSendsOneSearchAndPrintsTheShippedLines() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.searchStations": [Q.search([Q.station("ra.1", "Jazz FM", live: true),
                                                               Q.station("ra.2", "Smooth Jazz")])]])
        let (error, calls) = tripwired {
            try runRadioSearch(term: ["smooth", "jazz"], env: h.env, musicApp: { _ in XCTFail("Music.app search ran") })
        }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no token read reaches REST, no AppleScript")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.searchStations"])
        let body = try XCTUnwrap(h.seen.bodies("slice.searchStations").first)
        XCTAssertEqual(body["term"] as? String, "smooth jazz")
        XCTAssertEqual(body["limit"] as? Int, 25)
        XCTAssertEqual(Set(body.keys), ["op", "term", "limit"])
        XCTAssertEqual(h.seen.locked("slice.searchStations"), [false], "a read takes no output lock")
        XCTAssertEqual(h.io.out, [
            "Jazz FM  [LIVE]\n  https://music.apple.com/us/station/jazz-fm/ra.1",
            "Smooth Jazz\n  https://music.apple.com/us/station/smooth-jazz/ra.2",
        ])
    }

    func testBridgeRadioSearchWithNoHitsPrintsTheShippedSentence() {
        let h = H(.source, ["slice.status": [ready], "slice.searchStations": [Q.search([])]])
        let (error, calls) = tripwired { try runRadioSearch(term: ["zzz"], env: h.env, musicApp: { _ in XCTFail() }) }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, ["No stations found. Station search is shallow — pasting the URL always works."])
    }

    func testBridgeRadioSearchRefusalPrintsBridgesWordsAndExits1() {
        let h = H(.source, ["slice.status": [ready],
                            "slice.searchStations": [CLIBridgeReplies.refused("catalogue unavailable")]])
        let (error, _) = tripwired { try runRadioSearch(term: ["jazz"], env: h.env, musicApp: { _ in XCTFail() }) }
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Bridge refused: catalogue unavailable"])
    }

    func testMusicAppRadioSearchRunsTheShippedBodyAndNoWire() {
        let h = H(.musicApp)
        var got: [[String]] = []
        let (error, calls) = tripwired { try runRadioSearch(term: ["jazz", "fm"], env: h.env, musicApp: { got.append($0) }) }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(got, [["jazz", "fm"]])
        XCTAssertEqual(h.wire.requestCount, 0)
    }

    // MARK: - radio add

    func testBridgeRadioAddLooksUpByIdAndSavesTheEnrichedFavourite() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.station": [Q.lookup(Q.station("ra.978194965", "Apple Music 1", live: true))]])
        let stations = try favourites(h)
        var lookups = 0
        let (error, calls) = tripwired {
            try runRadioAdd(url: appleMusic1URL, env: h.env, stations: stations,
                            musicAppLookup: { _ in lookups += 1; return nil })
        }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(lookups, 0, "Music.app's lookup (developer key, REST) never runs on Bridge")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.station"])
        let body = try XCTUnwrap(h.seen.bodies("slice.station").first)
        XCTAssertEqual(body["id"] as? String, "ra.978194965")
        XCTAssertEqual(h.seen.locked("slice.station"), [false])
        let saved = try favourites(h).favorites()
        XCTAssertEqual(saved.map(\.name), ["Apple Music 1"])
        XCTAssertEqual(saved.first?.isLive, true)
        XCTAssertEqual(h.io.out, ["★ Apple Music 1"])
    }

    func testBridgeRadioAddKeepsTheSlugNameWhenBridgeAnswersNull() throws {
        let h = H(.source, ["slice.status": [ready], "slice.station": [Q.lookup(nil)]])
        let stations = try favourites(h)
        let (error, _) = tripwired {
            try runRadioAdd(url: "https://music.apple.com/gb/station/bbc-radio-1/ra.1616345645", env: h.env,
                            stations: stations, musicAppLookup: { _ in XCTFail(); return nil })
        }
        XCTAssertNil(error)
        XCTAssertEqual(try favourites(h).favorites().map(\.name), ["Bbc Radio 1"])
        XCTAssertEqual(try favourites(h).favorites().map(\.id), ["ra.1616345645"])
        XCTAssertEqual(h.io.out, ["★ Bbc Radio 1"])
    }

    /// Enrichment degrades in both modes: a Bridge refusal, or Bridge not
    /// being ready, saves the slug-named favourite and prints only `★`.
    func testBridgeRadioAddDegradesOnAFailedOrRefusedLookup() throws {
        for replies in [["slice.status": [ready], "slice.station": [CLIBridgeReplies.refused("no")]],
                        ["slice.status": [CLIBridgeReplies.status(authorization: "denied")]]] {
            let h = H(.source, replies)
            let stations = try favourites(h)
            let (error, calls) = tripwired {
                try runRadioAdd(url: appleMusic1URL, env: h.env, stations: stations,
                                musicAppLookup: { _ in XCTFail(); return nil })
            }
            XCTAssertNil(error)
            XCTAssertEqual(calls, [])
            XCTAssertEqual(try favourites(h).favorites().map(\.name), ["Apple Music 1"])
            XCTAssertEqual(h.io.out, ["★ Apple Music 1"], "nothing of the lookup's failure is printed")
        }
    }

    func testMusicAppRadioAddUsesTheShippedLookupAndNoWire() throws {
        let h = H(.musicApp)
        let stations = try favourites(h)
        var looked: [String] = []
        let (error, calls) = tripwired {
            try runRadioAdd(url: appleMusic1URL, env: h.env, stations: stations,
                            musicAppLookup: { looked.append($0); return Station(id: $0, name: "Apple Music 1 (REST)",
                                                                                 url: "u", isLive: true, artworkURL: nil) })
        }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(looked, ["ra.978194965"])
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(try favourites(h).favorites().map(\.name), ["Apple Music 1 (REST)"])
        XCTAssertEqual(h.io.out, ["★ Apple Music 1 (REST)"])
    }

    func testRadioAddRejectsANonStationURLBeforeAnyLookup() throws {
        for mode in [PlaybackMode.source, .musicApp] {
            let h = H(mode, ["slice.status": [ready]])
            let stations = try favourites(h)
            let (error, _) = tripwired {
                try runRadioAdd(url: "https://music.apple.com/us/album/x/123", env: h.env, stations: stations,
                                musicAppLookup: { _ in XCTFail(); return nil })
            }
            XCTAssertEqual((error as? ValidationError)?.message, "Not an Apple Music station URL.")
            XCTAssertEqual(h.wire.requestCount, 0)
            XCTAssertEqual(try favourites(h).favorites(), [])
        }
    }

    // MARK: - radio play, Bridge

    func testBridgeRadioPlayOfAStationURLSendsOnePlayStationUnderTheLock() throws {
        let h = H(.source, ["slice.status": [ready], "slice.playStation": [Q.played]])
        let opener = CLIRadioCountingOpener()
        let (error, calls) = bridgeRadioPlay(h, [appleMusic1URL], stations: try favourites(h), opener: opener)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(opener.urls, [], "Bridge never opens a URL")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.playStation"])
        let body = try XCTUnwrap(h.seen.bodies("slice.playStation").first)
        XCTAssertEqual(body["id"] as? String, "ra.978194965")
        XCTAssertEqual(body["name"] as? String, "Apple Music 1")
        XCTAssertEqual(h.seen.locked("slice.playStation"), [true], "the play holds the output lock")
        XCTAssertEqual(h.io.out, ["▶ Apple Music 1"])
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    func testAnExactFavouriteNameBeatsASubstringMatch() throws {
        let h = H(.source, ["slice.status": [ready], "slice.playStation": [Q.played]])
        let stations = try favourites(h, [fav("ra.2", "Jazz Classics"), fav("ra.1", "Jazz"), fav("ra.3", "Smooth Jazz")])
        let (error, _) = bridgeRadioPlay(h, ["JAZZ"], stations: stations)
        XCTAssertNil(error)
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.playStation"], "a favourite needs no search")
        XCTAssertEqual(h.seen.bodies("slice.playStation").first?["id"] as? String, "ra.1")
        XCTAssertEqual(h.io.out, ["▶ Jazz"])
    }

    func testAUniqueSubstringFavouritePlays() throws {
        let h = H(.source, ["slice.status": [ready], "slice.playStation": [Q.played]])
        let stations = try favourites(h, [fav("ra.1", "Jazz FM"), fav("ra.2", "BBC Radio 6 Music")])
        let (error, _) = bridgeRadioPlay(h, ["radio", "6"], stations: stations)
        XCTAssertNil(error)
        XCTAssertEqual(h.seen.bodies("slice.playStation").first?["id"] as? String, "ra.2")
        XCTAssertEqual(h.io.out, ["▶ BBC Radio 6 Music"])
    }

    func testTwoSubstringFavouritesRefuseWithAListAndPlayNothing() throws {
        let h = H(.source, ["slice.status": [ready]])
        let stations = try favourites(h, [fav("ra.1", "Jazz FM"), fav("ra.2", "Smooth Jazz"), fav("ra.3", "Rock")])
        let (error, calls) = bridgeRadioPlay(h, ["jazz"], stations: stations)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, ["'jazz' matches 2 favourite stations: Jazz FM; Smooth Jazz. Use the exact name or the station URL."])
        XCTAssertEqual(h.seen.ops, ["slice.status"], "readiness only: no search, no play")
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    func testBridgeSearchWithOneHitPlaysIt() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.searchStations": [Q.search([Q.station("ra.9", "Radio Paradise")])],
                            "slice.playStation": [Q.played]])
        let stations = try favourites(h, [fav("ra.1", "Jazz FM")])
        let (error, calls) = bridgeRadioPlay(h, ["paradise"], stations: stations)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.searchStations", "slice.playStation"])
        XCTAssertEqual(h.seen.bodies("slice.searchStations").first?["term"] as? String, "paradise")
        XCTAssertEqual(h.seen.locked("slice.searchStations"), [false], "the search runs outside the lock")
        XCTAssertEqual(h.seen.locked("slice.playStation"), [true])
        let body = try XCTUnwrap(h.seen.bodies("slice.playStation").first)
        XCTAssertEqual(body["id"] as? String, "ra.9")
        XCTAssertEqual(body["name"] as? String, "Radio Paradise")
        XCTAssertEqual(h.io.out, ["▶ Radio Paradise"])
    }

    func testBridgeSearchWithTwoHitsRefusesWithAListAndPlaysNothing() {
        let h = H(.source, ["slice.status": [ready],
                            "slice.searchStations": [Q.search([Q.station("ra.1", "Jazz FM"), Q.station("ra.2", "Jazz 24")])]])
        let (error, calls) = bridgeRadioPlay(h, ["jazz"], stations: (try? favourites(h))!)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, ["'jazz' matches 2 stations: Jazz FM; Jazz 24. Paste the station URL, or favourite one."])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.searchStations"])
    }

    func testAnAmbiguousListNamesFiveThenCountsTheRest() {
        let hits = (1...7).map { Q.station("ra.\($0)", "Jazz \($0)") }
        let h = H(.source, ["slice.status": [ready], "slice.searchStations": [Q.search(hits)]])
        let (error, _) = bridgeRadioPlay(h, ["jazz"], stations: (try? favourites(h))!)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["'jazz' matches 7 stations: Jazz 1; Jazz 2; Jazz 3; Jazz 4; Jazz 5; and 2 more. Paste the station URL, or favourite one."])
        let six = (1...6).map { fav("ra.\($0)", "Jazz \($0)") }
        XCTAssertEqual(bridgeAmbiguousFavouritesRefusal(query: "jazz", matches: six),
                       "'jazz' matches 6 favourite stations: Jazz 1; Jazz 2; Jazz 3; Jazz 4; Jazz 5; and 1 more. Use the exact name or the station URL.")
    }

    func testBridgeSearchWithNoHitsPrintsTheShippedNotFoundSentence() {
        let h = H(.source, ["slice.status": [ready], "slice.searchStations": [Q.search([])]])
        let (error, _) = bridgeRadioPlay(h, ["nothing", "here"], stations: (try? favourites(h))!)
        XCTAssertNil(error, "the shipped body returns after the sentence")
        XCTAssertEqual(h.io.err, ["✗ No station found for “nothing here”. Try pasting the station URL."])
        XCTAssertEqual(h.io.out, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.searchStations"])
    }

    /// A switch that commits after the command routed on Bridge: the mode is
    /// revalidated under the lock and the play refuses, sending nothing.
    func testASwitchCommittingFirstRefusesAndSendsNoPlayStation() throws {
        let h = H(.source, ["slice.status": [ready], "slice.playStation": [Q.played]])
        XCTAssertTrue(h.store.set(.musicApp), "another process switched Output")
        let (error, calls) = bridgeRadioPlay(h, [appleMusic1URL], stations: try favourites(h))
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, [OutputLock.cliModeChangedMessage(now: .musicApp)])
        XCTAssertEqual(h.seen.bodies("slice.playStation").count, 0)
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    /// Ruling 17: a station Apple does not carry is refused in Bridge's words.
    func testBridgesRefusalOfThePlayIsPrintedVerbatim() {
        let refusal = CLIBridgeReplies.refused("Apple Music doesn't carry BBC Radio 1")
        let h = H(.source, ["slice.status": [ready], "slice.playStation": [refusal]])
        let (error, _) = bridgeRadioPlay(h, ["https://music.apple.com/gb/station/bbc-radio-1/ra.1616345645"],
                                         stations: (try? favourites(h))!)
        XCTAssertEqual(error as? ExitCode, .failure)
        var expected = ""
        do { try SourceAppControl(path: "/nonexistent", transport: { _, _ in refusal }).playStation(id: "x", named: "y") }
        catch { expected = cliErrorMessage(error) }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(h.io.out, [expected])
        XCTAssertEqual(h.seen.bodies("slice.playStation").first?["name"] as? String, "Bbc Radio 1")
    }

    func testBridgeRefusesANonStationURLBeforeAnyStationRequest() {
        let h = H(.source, ["slice.status": [ready]])
        let (error, _) = bridgeRadioPlay(h, ["https://music.apple.com/us/album/x/123"], stations: (try? favourites(h))!)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Not an Apple Music station URL."])
        XCTAssertEqual(h.seen.ops, ["slice.status"])
    }

    // MARK: - radio play, Music.app (shipped)

    func testMusicAppRadioPlayOfAURLOpensItUnderTheLockAndSendsNothing() throws {
        let h = H(.musicApp)
        let opener = CLIRadioCountingOpener()
        opener.lockPath = h.lockPath
        let stations = try favourites(h)
        var result: (error: Error?, calls: [ExternalCall]) = (nil, [])
        let printed = captureStdout { result = self.bridgeRadioPlay(h, [self.appleMusic1URL], stations: stations, opener: opener) }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, [])
        XCTAssertEqual(opener.urls, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertEqual(opener.lockedDuringOpen, [true], "Part 1's lock is held for the Music.app play")
        XCTAssertEqual(printed.output, "▶ Apple Music 1\n")
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    /// D8 changes Bridge only: with Music.app selected the FIRST containing
    /// favourite still plays, as shipped.
    func testMusicAppRadioPlayKeepsTheShippedFirstMatch() throws {
        let h = H(.musicApp)
        let opener = CLIRadioCountingOpener()
        let stations = try favourites(h, [
            Station(id: "ra.1", name: "Jazz FM", url: "https://music.apple.com/us/station/jazz-fm/ra.1", isLive: nil, artworkURL: nil),
            Station(id: "ra.2", name: "Smooth Jazz", url: "https://music.apple.com/us/station/smooth-jazz/ra.2", isLive: nil, artworkURL: nil),
        ])
        var result: (error: Error?, calls: [ExternalCall]) = (nil, [])
        let printed = captureStdout { result = self.bridgeRadioPlay(h, ["jazz"], stations: stations, opener: opener) }
        XCTAssertNil(result.error)
        XCTAssertEqual(opener.urls, ["music://music.apple.com/us/station/jazz-fm/ra.1"])
        XCTAssertEqual(printed.output, "▶ Jazz FM\n")
        XCTAssertEqual(h.wire.requestCount, 0)
    }
}
