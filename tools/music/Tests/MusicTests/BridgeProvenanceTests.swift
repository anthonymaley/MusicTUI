import XCTest
@testable import music

/// Score S3 (D2, D3): a cached row becomes a Bridge reference only by its
/// origin, never by the shape of its id; Music.app never plays a Bridge row by
/// identity; library management refuses Bridge rows whole. Plus the tripwire
/// that makes "0 AppleScript/REST calls" a count.
final class BridgeProvenanceTests: XCTestCase {

    // MARK: - bridgeRef(forCachedRow:index:)

    func testBridgeRowQueuesItsBridgeIDWithStartRequired() {
        let row = SongResult.row(2, .bridgeLibrary, bridgeID: "12345")
        XCTAssertEqual(bridgeRef(forCachedRow: row, index: 2),
                       .queue(.libraryQueue(ids: ["12345"], startRequired: true)))
    }

    func testBridgeRowWithNoIdIsRefused() {
        for id in [nil, ""] as [String?] {
            let row = SongResult.row(4, .bridgeLibrary, bridgeID: id)
            XCTAssertEqual(bridgeRef(forCachedRow: row, index: 4),
                           .refuse("Result 4 has no Bridge id; run the search again."))
        }
    }

    func testMusicAppAndCatalogueRowsAreRefusedByOriginNotIdShape() {
        // D10 (Part 2, P6) replaces Part 1's `search --library` hint.
        let expected = "Result 3 came from a Music.app or catalogue listing, so Bridge can't play it by its own id. With Bridge selected, run: music search \"T3\"  then  music play N"
        // A catalogue row whose id looks like a library id is still catalogue.
        XCTAssertEqual(bridgeRef(forCachedRow: .row(3, .catalog, catalogId: "i.abc123"), index: 3), .refuse(expected))
        XCTAssertEqual(bridgeRef(forCachedRow: .row(3, .catalog), index: 3), .refuse(expected))
        XCTAssertEqual(bridgeRef(forCachedRow: .row(3, .library, catalogId: "ABCDEF0123456789"), index: 3), .refuse(expected))
    }

    func testLegacyRowDecodesAsCatalogueAndIsRefusedAsABridgeRef() throws {
        let json = #"[{"index":1,"title":"T1","artist":"A","album":"AA","catalogId":"i.xyz"}]"#
        let row = try JSONDecoder().decode([SongResult].self, from: Data(json.utf8))[0]
        XCTAssertEqual(row.origin, .catalog)
        guard case .refuse = bridgeRef(forCachedRow: row, index: 1) else {
            return XCTFail("a legacy row must never become a Bridge ref")
        }
    }

    // MARK: - musicAppIndexRoute(forCachedRow:index:)

    func testMusicAppRefusesBridgeRowsAndReResolvesTheRest() {
        let refusal = "Result 5 came from Bridge's library, which Music.app can't play by identity. Search again with Output set to Music.app, or switch Output to Bridge."
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .bridgeLibrary, bridgeID: "9"), index: 5), .refuse(refusal))
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .bridgeLibrary), index: 5), .refuse(refusal))
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .catalog), index: 5), .reResolveByTitle)
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .library), index: 5), .reResolveByTitle)
    }

    /// D10: Music.app refuses a Bridge catalogue row in its own words, with or
    /// without its id; it is never re-resolved by title.
    func testMusicAppRefusesBridgeCatalogueRows() {
        let refusal = "Result 5 came from Bridge's catalogue search, which Music.app can't play by identity. Search again with Output set to Music.app, or switch Output to Bridge."
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .bridgeCatalog, bridgeID: "1440"), index: 5), .refuse(refusal))
        XCTAssertEqual(musicAppIndexRoute(forCachedRow: .row(5, .bridgeCatalog), index: 5), .refuse(refusal))
    }

    // MARK: - bridge_catalog (Part 2, D6)

    /// D6: a `.bridgeCatalog` row queues its Bridge id as a CATALOGUE id
    /// (`slice.queue {"ids"}`), never as a library id. The origin decides.
    func testBridgeCatalogueRowQueuesItsIdAsACatalogueId() {
        XCTAssertEqual(bridgeRef(forCachedRow: .row(2, .bridgeCatalog, bridgeID: "1440857781"), index: 2),
                       .queue(.catalogueQueue(ids: ["1440857781"])))
        // An id spelled like a library id is still catalogue.
        XCTAssertEqual(bridgeRef(forCachedRow: .row(2, .bridgeCatalog, bridgeID: "i.abc123"), index: 2),
                       .queue(.catalogueQueue(ids: ["i.abc123"])))
        // A Bridge LIBRARY row whose id looks like a catalogue id stays a library queue.
        XCTAssertEqual(bridgeRef(forCachedRow: .row(2, .bridgeLibrary, bridgeID: "1440857781"), index: 2),
                       .queue(.libraryQueue(ids: ["1440857781"], startRequired: true)))
    }

    func testBridgeCatalogueRowWithNoIdIsRefused() {
        for id in [nil, ""] as [String?] {
            XCTAssertEqual(bridgeRef(forCachedRow: .row(4, .bridgeCatalog, bridgeID: id), index: 4),
                           .refuse("Result 4 has no Bridge id; run the search again."))
        }
    }

    /// D6: a `.catalog` row with a real-looking catalogue id stays refused on
    /// Bridge (`.catalog` also carries library and album ids).
    func testACatalogRowWithANumericIdIsStillRefusedOnBridge() {
        guard case .refuse = bridgeRef(forCachedRow: .row(1, .catalog, catalogId: "1440857781"), index: 1) else {
            return XCTFail("a .catalog row must never become a Bridge ref")
        }
    }

    func testBridgeCatalogueRowRoundTripsAndShippedRowsKeepTheirBytes() throws {
        let row = SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                             catalogId: "", origin: .bridgeCatalog, bridgeID: "1440")
        let data = try JSONEncoder().encode([row])
        XCTAssertEqual(try JSONDecoder().decode([SongResult].self, from: data), [row])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""origin":"bridge_catalog""#), text)
        XCTAssertTrue(text.contains(#""bridge_id":"1440""#), text)
        let shipped = String(decoding: try JSONEncoder().encode([SongResult.row(1, .catalog)]), as: UTF8.self)
        XCTAssertFalse(shipped.contains("bridge_id"), shipped)
        XCTAssertFalse(shipped.contains("bridge_catalog"), shipped)
    }

    // MARK: - bridgeRowsRefusal(_:)

    func testBridgeRowsRefusalNamesEveryBridgeRowAndNothingElse() {
        XCTAssertNil(bridgeRowsRefusal([]))
        XCTAssertNil(bridgeRowsRefusal([.row(1, .catalog), .row(2, .library)]))
        XCTAssertEqual(bridgeRowsRefusal([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "7")]),
                       "Result(s) 2 came from Bridge. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.")
        XCTAssertEqual(bridgeRowsRefusal([.row(3, .bridgeLibrary), .row(1, .catalog), .row(5, .bridgeLibrary, bridgeID: "x")]),
                       "Result(s) 3, 5 came from Bridge. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.")
        // D10, Q3's default: a Bridge CATALOGUE row is refused the same way (P6A is out).
        XCTAssertEqual(bridgeRowsRefusal([.row(1, .catalog), .row(2, .bridgeCatalog, bridgeID: "1440"),
                                          .row(3, .bridgeLibrary, bridgeID: "b")]),
                       "Result(s) 2, 3 came from Bridge. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.")
    }

    // MARK: - The existing origin helpers, now exhaustive

    func testAddIndexRouteSendsBridgeRowsToTheRefusalCase() {
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "", hasTargets: false), .bridgeRow)
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "", hasTargets: true), .bridgeRow)
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "id", hasTargets: true), .bridgeRow)
        for targets in [false, true] {
            XCTAssertEqual(addIndexRoute(origin: .bridgeCatalog, catalogId: "", hasTargets: targets), .bridgeRow)
            XCTAssertEqual(addIndexRoute(origin: .bridgeCatalog, catalogId: "1440", hasTargets: targets), .bridgeRow)
        }
    }

    func testBridgeRowsAreNeitherCatalogueNorLibraryRows() {
        let p = partitionByOrigin([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "2"), .row(3, .library)])
        XCTAssertEqual(p.catalog.map(\.index), [1])
        XCTAssertEqual(p.library.map(\.index), [3])
        XCTAssertFalse(allLibraryRows([.row(1, .bridgeLibrary, bridgeID: "1")]))
        XCTAssertFalse(allLibraryRows([.row(1, .library), .row(2, .bridgeLibrary, bridgeID: "2")]))
        let c = partitionByOrigin([.row(1, .catalog), .row(2, .bridgeCatalog, bridgeID: "2"), .row(3, .library)])
        XCTAssertEqual(c.catalog.map(\.index), [1], "a Bridge catalogue row is not a REST catalogue row")
        XCTAssertEqual(c.library.map(\.index), [3])
        XCTAssertFalse(allLibraryRows([.row(1, .bridgeCatalog, bridgeID: "1")]))
        XCTAssertFalse(allLibraryRows([.row(1, .library), .row(2, .bridgeCatalog, bridgeID: "2")]))
    }

    // MARK: - The tripwire

    func testTripwireUnarmedIsInert() {
        XCTAssertFalse(ExternalCallTripwire.shared.isArmed)
        XCTAssertNoThrow(try ExternalCallTripwire.shared.check(.appleScript(script: "x")))
        XCTAssertEqual(ExternalCallTripwire.shared.recorded, [])
    }

    /// Armed, the AppleScript funnel records the script and throws before any
    /// process. The executable does not exist, so if the guard were missing the
    /// call would fail differently and record nothing.
    func testArmedTripwireStopsAppleScriptBeforeAnyProcess() {
        var backend = AppleScriptBackend()
        backend.executable = "/nonexistent/tripwire-osascript"
        let (thrown, calls) = withTripwire { () -> Error? in
            do { _ = try syncRun { try await backend.run("return 1") }; return nil } catch { return error }
        }
        XCTAssertTrue(thrown is ExternalCallBlocked, "\(String(describing: thrown))")
        XCTAssertEqual(calls, [.appleScript(script: "return 1")])
    }

    func testArmedTripwireStopsRESTBeforeAnyConnection() {
        let api = RESTAPIBackend(developerToken: "dev", userToken: "user", storefront: "us")
        let (thrown, calls) = withTripwire { () -> [Error] in
            var errors: [Error] = []
            do { _ = try syncRun { try await api.get("/v1/test-get") } } catch { errors.append(error) }
            do { _ = try syncRun { try await api.post("/v1/test-post") } } catch { errors.append(error) }
            return errors
        }
        XCTAssertEqual(thrown.count, 2)
        XCTAssertTrue(thrown.allSatisfy { $0 is ExternalCallBlocked })
        XCTAssertEqual(calls, [.http(method: "GET", path: "/v1/test-get"),
                               .http(method: "POST", path: "/v1/test-post")])
        XCTAssertFalse(ExternalCallTripwire.shared.isArmed, "withTripwire disarms")
    }

    /// Structural: the guard is the first statement of each funnel, so nothing
    /// (not even a Process or a URLRequest) is built before it.
    func testGuardIsTheFirstStatementOfEachFunnel() throws {
        let backends = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Backends")
        let funnels: [(file: String, signature: String, guardLine: String)] = [
            ("AppleScriptBackend.swift",
             "func run(_ script: String, timeout: TimeInterval = 45) async throws -> String {\n",
             "try ExternalCallTripwire.shared.check(.appleScript(script: script))"),
            ("RESTAPIBackend.swift",
             "func get(_ path: String) async throws -> (Data, Int) {\n",
             "try ExternalCallTripwire.shared.check(.http(method: \"GET\", path: path))"),
            ("RESTAPIBackend.swift",
             "func post(_ path: String, body: Data? = nil) async throws -> (Data, Int) {\n",
             "try ExternalCallTripwire.shared.check(.http(method: \"POST\", path: path))"),
        ]
        for funnel in funnels {
            let source = try String(contentsOf: backends.appendingPathComponent(funnel.file), encoding: .utf8)
            guard let decl = source.range(of: funnel.signature) else {
                XCTFail("\(funnel.signature) not found in \(funnel.file)"); continue
            }
            let firstLine = source[decl.upperBound...].prefix { $0 != "\n" }
                .trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(firstLine, funnel.guardLine, "\(funnel.file): the tripwire must come first")
        }
    }
}
