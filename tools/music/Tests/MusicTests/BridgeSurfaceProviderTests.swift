import XCTest
@testable import music

/// Slice 3, Part 2, P1: `BridgeMusicProvider` behind the five surfaces (D1, D2).
///
/// **D2, no visible change means the same words.** The members that replace an
/// existing `SourceAppClient` member (rails, tracks, station search, station
/// play, catalogue queue) must send the same bytes and throw the SAME
/// `SourceAppError` values the old member throws for the same reply, so every
/// sentence a scene shows today stays byte-identical when P3/P5 fold the scenes
/// onto the seam. The new reads throw `MusicProviderError` through `translate`.
///
/// Scripted transport only: no socket, no Bridge, no REST.
final class BridgeSurfaceProviderTests: XCTestCase {

    // MARK: - Harness

    private final class Wire {
        private(set) var lines: [String] = []
        private let answer: (String) throws -> String
        init(_ answer: @escaping (String) throws -> String) { self.answer = answer }
        convenience init(reply: String) { self.init { _ in reply } }
        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return try answer(line) }
        }
        /// The requests as JSON objects. Compared as objects, not bytes: the
        /// shipped encoders do not fix key order, so identical requests can
        /// differ byte for byte from one call to the next.
        var requests: [NSDictionary] {
            lines.map { line in
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                return (object as? NSDictionary) ?? ["unparseable": line]
            }
        }
    }

    private func provider(_ wire: Wire) -> BridgeMusicProvider {
        BridgeMusicProvider(control: SourceAppControl(path: "/unused", transport: wire.transport))
    }

    /// Either the value or the `SourceAppError`, so an old member and a new one
    /// can be compared outcome for outcome.
    private enum Outcome<T: Equatable>: Equatable {
        case value(T)
        case sourceError(SourceAppError)
        case otherError(String)
    }

    private func outcome<T: Equatable>(_ body: () throws -> T) -> Outcome<T> {
        do { return .value(try body()) }
        catch let error as SourceAppError { return .sourceError(error) }
        catch { return .otherError(String(describing: error)) }
    }

    private func refusal(_ op: String, _ kind: String, _ detail: String = "Bridge's words",
                         extra: String = "") -> String {
        #"{"ok":false,"op":"\#(op)","error":{"kind":"\#(kind)","detail":"\#(detail)"\#(extra)}}"#
    }

    /// Every failure class a reply or a transport can produce. Each old member
    /// and its replacement are driven through all of them.
    private func failureTable(op: String) -> [(String, (String) throws -> String)] {
        [
            ("unauthorized", { _ in self.refusal(op, "unauthorized") }),
            ("warming", { _ in self.refusal(op, "warming", "w", extra: #","retry_after":3"#) }),
            ("stale_generation", { _ in self.refusal(op, "stale_generation", "s") }),
            ("unknown_op", { _ in self.refusal(op, "unknown_op") }),
            ("unavailable", { _ in self.refusal(op, "unavailable") }),
            ("other refusal", { _ in self.refusal(op, "bad_request", "empty term") }),
            ("no detail", { _ in #"{"ok":false,"op":"\#(op)","error":{"kind":"bad_request"}}"# }),
            ("garbage", { _ in "not json" }),
            ("no ok", { _ in #"{"op":"\#(op)"}"# }),
            ("ok, no collection", { _ in #"{"ok":true,"op":"\#(op)"}"# }),
            ("not running", { _ in throw SourceAppError.notRunning }),
            ("timed out", { _ in throw SourceAppError.timedOut }),
            ("socket unusable", { _ in throw SourceAppError.socketUnavailable("permission denied") }),
        ]
    }

    // MARK: - D2: Discover rails

    private static let railsReply = """
    {"ok":true,"op":"slice.recommendations","rails":[
      {"title":"Recently Played","items":[
        {"id":"ra.978194965","kind":"station","name":"Apple Music 1","artwork_url":"https://a/1.jpg"},
        {"id":"1440857781","kind":"album","name":"Aja","subtitle":"Steely Dan"},
        {"id":"9","kind":"music-video","name":"V"}]},
      {"title":"Empty","items":[]},
      {"title":"Made for You","items":[{"id":"pl.u-def","kind":"playlist","name":"Chill Mix"}]}]}
    """

    func testDiscoverRailsMatchTheOldFeedOutcomeForOutcome() {
        var table = failureTable(op: "slice.recommendations")
        table.append(("golden", { _ in Self.railsReply }))
        table.append(("empty", { _ in #"{"ok":true,"op":"slice.recommendations","rails":[]}"# }))
        table.append(("rail without items", { _ in #"{"ok":true,"rails":[{"title":"R"}]}"# }))
        table.append(("item without name", { _ in #"{"ok":true,"rails":[{"title":"R","items":[{"id":"1","kind":"album"}]}]}"# }))
        for (name, answer) in table {
            let oldWire = Wire(answer), newWire = Wire(answer)
            let old = outcome { try BridgeDiscoverFeed(path: "/unused", transport: oldWire.transport).rails(limit: 30) }
            let new = outcome { try provider(newWire).discoverRails(limit: 30) }
            XCTAssertEqual(new, old, name)
            XCTAssertEqual(newWire.requests, oldWire.requests, "\(name): request bytes changed")
        }
    }

    // MARK: - D2: a container's tracks

    func testContainerTracksMatchTheOldFeedOutcomeForOutcome() {
        let items = [
            DiscoverItem(id: "pl.u-abc", name: "P", subtitle: nil, url: nil, artworkURL: nil,
                         detail: .playlist(description: nil)),
            DiscoverItem(id: "1440857781", name: "A", subtitle: nil, url: nil, artworkURL: nil,
                         detail: .album(trackCount: nil, year: nil, genre: nil)),
            DiscoverItem(id: "ra.1", name: "S", subtitle: nil, url: nil, artworkURL: nil,
                         detail: .station(isLive: false)),
            DiscoverItem(id: "1", name: "Song", subtitle: nil, url: nil, artworkURL: nil, detail: .song),
        ]
        var table = failureTable(op: "slice.containerTracks")
        table.append(("golden", { _ in """
            {"ok":true,"op":"slice.containerTracks","items":[
              {"id":"801","kind":"song","name":"S1","subtitle":"A"},{"id":"802","kind":"song","name":"S2"}]}
            """ }))
        for item in items {
            for (name, answer) in table {
                let oldWire = Wire(answer), newWire = Wire(answer)
                let old = outcome { try BridgeDiscoverFeed(path: "/unused", transport: oldWire.transport).tracks(for: item) }
                let new = outcome { try provider(newWire).containerTracks(for: item) }
                XCTAssertEqual(new, old, "\(item.kind) \(name)")
                XCTAssertEqual(newWire.requests, oldWire.requests, "\(item.kind) \(name): request bytes changed")
            }
        }
    }

    // MARK: - D2: station search

    func testStationSearchMatchesTheOldAdapterOutcomeForOutcome() {
        var table = failureTable(op: "slice.searchStations")
        table.append(("golden", { _ in """
            {"ok":true,"op":"slice.searchStations","stations":[{"id":"ra.978194965","name":"Apple Music 1",
             "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965","is_live":true,
             "artwork_url":"https://a/1.jpg"}]}
            """ }))
        table.append(("empty", { _ in #"{"ok":true,"op":"slice.searchStations","stations":[]}"# }))
        table.append(("no url", { _ in #"{"ok":true,"stations":[{"id":"ra.1","name":"N"}]}"# }))
        for (name, answer) in table {
            let oldWire = Wire(answer), newWire = Wire(answer)
            let old = outcome { try SourceAppStationSearch(path: "/unused", transport: oldWire.transport)
                .searchStations(term: "jazz") }
            let new = outcome { try provider(newWire).searchStations(term: "jazz", limit: 25) }
            XCTAssertEqual(new, old, name)
            XCTAssertEqual(newWire.requests, oldWire.requests, "\(name): request bytes changed")
        }
    }

    // MARK: - D2: station play

    func testStationPlayMatchesTheOldMemberAndIgnoresTheURL() {
        var table = failureTable(op: "slice.playStation")
        table.append(("ok", { _ in #"{"ok":true,"op":"slice.playStation"}"# }))
        for (name, answer) in table {
            let oldWire = Wire(answer), newWire = Wire(answer)
            let old = outcome { try SourceAppControl(path: "/unused", transport: oldWire.transport)
                .playStation(id: "ra.978194965", named: "Apple Music 1") ; return true }
            let new = outcome { try provider(newWire).playStation(
                id: "ra.978194965", name: "Apple Music 1",
                url: "https://music.apple.com/us/station/apple-music-1/ra.978194965"); return true }
            XCTAssertEqual(new, old, name)
            XCTAssertEqual(newWire.requests, oldWire.requests, "\(name): request bytes changed")
        }
    }

    // MARK: - D2: catalogue queue

    func testCatalogueQueueSendsTheOldBytesRethrowsUnchangedAndReportsSkips() {
        var table = failureTable(op: "slice.queue")
        table.append(("ok", { _ in #"{"ok":true,"op":"slice.queue"}"# }))
        for (name, answer) in table {
            let oldWire = Wire(answer), newWire = Wire(answer)
            let old = outcome { try SourceAppControl(path: "/unused", transport: oldWire.transport)
                .queue(catalogIDs: ["1440857789", "203709340"]); return 0 }
            let new = outcome { try provider(newWire).playCatalogue(ids: ["1440857789", "203709340"]) }
            XCTAssertEqual(new, old, name)
            XCTAssertEqual(newWire.requests, oldWire.requests, "\(name): request bytes changed")
        }
        let wire = Wire(reply: #"{"ok":true,"op":"slice.queue","skipped_unavailable":1}"#)
        XCTAssertEqual(try provider(wire).playCatalogue(ids: ["1", "2"]), 1)
    }

    // MARK: - New reads: decoded, then translated

    func testNewReadsDecodeThroughTheProvider() throws {
        let station = #"{"id":"ra.978194965","name":"Apple Music 1","url":"https://m/1","is_live":true,"artwork_url":null}"#
        let am1 = Station(id: "ra.978194965", name: "Apple Music 1", url: "https://m/1", isLive: true, artworkURL: nil)
        XCTAssertEqual(try provider(Wire(reply: #"{"ok":true,"stations":[\#(station)]}"#)).liveStations(), [am1])
        XCTAssertEqual(try provider(Wire(reply: #"{"ok":true,"stations":[\#(station)]}"#)).personalStations(), [am1])
        XCTAssertEqual(try provider(Wire(reply: #"{"ok":true,"station":\#(station)}"#)).station(id: "ra.978194965"), am1)
        XCTAssertNil(try provider(Wire(reply: #"{"ok":true,"station":null}"#)).station(id: "ra.1"))
        XCTAssertEqual(try provider(Wire(reply: """
            {"ok":true,"records":[{"kind":"song","id":"1","title":"Peg","subtitle":"Steely Dan","album":"Aja"}]}
            """)).searchCatalogue(term: "peg", limit: 10),
            [CatalogueRecord(kind: .song, catalogueID: "1", title: "Peg", artist: "Steely Dan", album: "Aja")])
        let item = #"{"type":"songs","id":"1","name":"Peg","catalog_id":"1"}"#
        let peg = HistoryItem(type: "songs", id: "1", name: "Peg", artist: nil, album: nil, catalogueID: "1")
        XCTAssertEqual(try provider(Wire(reply: #"{"ok":true,"items":[\#(item)]}"#)).recentTracks(limit: 10), [peg])
        XCTAssertEqual(try provider(Wire(reply: #"{"ok":true,"items":[\#(item)]}"#)).heavyRotation(limit: 10), [peg])
    }

    private struct NewRead {
        let op: String
        let sentence: String
        let call: (BridgeMusicProvider) throws -> Any
    }

    private let newReads: [NewRead] = [
        NewRead(op: "slice.search", sentence: "This Bridge build can't search the catalogue — update Bridge") {
            try $0.searchCatalogue(term: "x", limit: 10) },
        NewRead(op: "slice.liveStations", sentence: "This Bridge build can't list live stations — update Bridge") {
            try $0.liveStations() },
        NewRead(op: "slice.personalStations",
                sentence: "This Bridge build can't show your personal station — update Bridge") {
            try $0.personalStations() },
        NewRead(op: "slice.station", sentence: "This Bridge build can't look up a station — update Bridge") {
            try $0.station(id: "ra.1") as Any },
        NewRead(op: "slice.recentTracks",
                sentence: "This Bridge build can't show your listening history — update Bridge") {
            try $0.recentTracks(limit: 10) },
        NewRead(op: "slice.heavyRotation", sentence: "This Bridge build can't show heavy rotation — update Bridge") {
            try $0.heavyRotation(limit: 10) },
    ]

    /// An older Bridge's `unknown_op` names the capability that is missing.
    func testUnknownOpOnANewReadIsItsOwnUpdateBridgeSentence() {
        for read in newReads {
            let wire = Wire(reply: refusal(read.op, "unknown_op"))
            XCTAssertThrowsError(try read.call(provider(wire)), read.op) {
                XCTAssertEqual($0 as? MusicProviderError, .notImplemented(read.sentence))
                XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, read.sentence)
            }
        }
    }

    func testNewReadsTranslateRefusalsAsTheLibraryReadsDo() {
        for read in newReads {
            let cases: [(String, MusicProviderError)] = [
                (refusal(read.op, "unauthorized"), .unavailable("Bridge has not been granted Apple Music access")),
                (refusal(read.op, "warming", "w", extra: #","retry_after":2"#), .warming("w", retryAfter: 2)),
                (refusal(read.op, "stale_generation", "s"), .staleGeneration("s")),
                (refusal(read.op, "not_found", "Bridge's words"), .refused("Bridge's words")),
            ]
            for (reply, expected) in cases {
                XCTAssertThrowsError(try read.call(provider(Wire(reply: reply))), read.op) {
                    XCTAssertEqual($0 as? MusicProviderError, expected, read.op)
                }
            }
            XCTAssertThrowsError(try read.call(provider(Wire { _ in throw SourceAppError.notRunning })), read.op) {
                XCTAssertEqual($0 as? MusicProviderError, .unavailable("Bridge is not running"), read.op)
            }
        }
    }

    /// A Bridge-mode read failure is Bridge's words, never an empty list (D4).
    func testAMissingCollectionOnANewReadIsAFailureNotEmpty() {
        for read in newReads {
            XCTAssertThrowsError(try read.call(provider(Wire(reply: #"{"ok":true}"#))), read.op) {
                XCTAssertNotNil($0 as? MusicProviderError, read.op)
            }
        }
    }

    // MARK: - Availability

    func testBridgeIsAlwaysAvailableForDiscoverAndStations() {
        let p = provider(Wire(reply: "{}"))
        XCTAssertTrue(p.feedAvailable)
        XCTAssertTrue(p.catalogueAvailable)
    }

    /// The provider is reachable through each surface, not only concretely.
    func testTheProviderConformsToEverySurface() {
        let p: MusicDataProvider = provider(Wire(reply: "{}"))
        XCTAssertNotNil(p as DiscoverProviding)
        XCTAssertNotNil(p as StationProviding)
        XCTAssertNotNil(p as CataloguePlaying)
        XCTAssertNotNil(p as CatalogueSearching)
        XCTAssertNotNil(p as HistoryProviding)
    }

    // MARK: - Defaults on the seam, so every older fake compiles

    /// A `MusicDataProvider` written before Part 2: only the three original
    /// requirements.
    private struct BeforePart2: MusicDataProvider {
        func librarySongs(cursor: String?, limit: Int) throws -> MusicPage {
            MusicPage(rows: [], nextCursor: nil, total: 0, generation: 1)
        }
        func play(ids: [String]) throws -> BridgeNow.Queue { throw MusicProviderError.refused("unused") }
        func nowPlaying() throws -> SourceStatus { throw MusicProviderError.refused("unused") }
    }

    func testEverySurfaceDefaultsToNotImplementedWithItsSentence() {
        let p: MusicDataProvider = BeforePart2()
        let album = DiscoverItem(id: "1", name: "A", subtitle: nil, url: nil, artworkURL: nil,
                                 detail: .album(trackCount: nil, year: nil, genre: nil))
        let cases: [(String, () throws -> Any)] = [
            ("This Bridge build can't show Discover — update Bridge", { try p.discoverRails(limit: 30) }),
            ("This Bridge build can't list a Discover item's tracks — update Bridge",
             { try p.containerTracks(for: album) }),
            ("This Bridge build can't search stations — update Bridge",
             { try p.searchStations(term: "x", limit: 25) }),
            ("This Bridge build can't list live stations — update Bridge", { try p.liveStations() }),
            ("This Bridge build can't show your personal station — update Bridge", { try p.personalStations() }),
            ("This Bridge build can't look up a station — update Bridge", { try p.station(id: "ra.1") as Any }),
            ("This Bridge build can't play a station — update Bridge",
             { try p.playStation(id: "ra.1", name: "S", url: nil) }),
            ("This Bridge build can't play catalogue songs — update Bridge", { try p.playCatalogue(ids: ["1"]) }),
            ("This Bridge build can't search the catalogue — update Bridge",
             { try p.searchCatalogue(term: "x", limit: 10) }),
            ("This Bridge build can't show your listening history — update Bridge", { try p.recentTracks(limit: 10) }),
            ("This Bridge build can't show heavy rotation — update Bridge", { try p.heavyRotation(limit: 10) }),
        ]
        for (sentence, call) in cases {
            XCTAssertThrowsError(try call(), sentence) {
                XCTAssertEqual($0 as? MusicProviderError, .notImplemented(sentence))
            }
        }
        XCTAssertTrue(p.feedAvailable)
        XCTAssertTrue(p.catalogueAvailable)
    }
}
