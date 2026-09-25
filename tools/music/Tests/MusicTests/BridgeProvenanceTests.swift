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
        let expected = "Result 3 came from a Music.app or catalogue listing, so Bridge can't play it by its own id. With Bridge selected, run: music search --library \"T3\"  then  music play N"
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

    // MARK: - bridgeRowsRefusal(_:)

    func testBridgeRowsRefusalNamesEveryBridgeRowAndNothingElse() {
        XCTAssertNil(bridgeRowsRefusal([]))
        XCTAssertNil(bridgeRowsRefusal([.row(1, .catalog), .row(2, .library)]))
        XCTAssertEqual(bridgeRowsRefusal([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "7")]),
                       "Result(s) 2 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.")
        XCTAssertEqual(bridgeRowsRefusal([.row(3, .bridgeLibrary), .row(1, .catalog), .row(5, .bridgeLibrary, bridgeID: "x")]),
                       "Result(s) 3, 5 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.")
    }

    // MARK: - The existing origin helpers, now exhaustive

    func testAddIndexRouteSendsBridgeRowsToTheRefusalCase() {
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "", hasTargets: false), .bridgeRow)
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "", hasTargets: true), .bridgeRow)
        XCTAssertEqual(addIndexRoute(origin: .bridgeLibrary, catalogId: "id", hasTargets: true), .bridgeRow)
    }

    func testBridgeRowsAreNeitherCatalogueNorLibraryRows() {
        let p = partitionByOrigin([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "2"), .row(3, .library)])
        XCTAssertEqual(p.catalog.map(\.index), [1])
        XCTAssertEqual(p.library.map(\.index), [3])
        XCTAssertFalse(allLibraryRows([.row(1, .bridgeLibrary, bridgeID: "1")]))
        XCTAssertFalse(allLibraryRows([.row(1, .library), .row(2, .bridgeLibrary, bridgeID: "2")]))
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
