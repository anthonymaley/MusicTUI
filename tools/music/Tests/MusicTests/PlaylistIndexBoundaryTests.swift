import ArgumentParser
import XCTest
@testable import music

/// Score S3: `playlist create NAME N…` and `playlist add P N…` run their real
/// bodies against a temp cache, counting auth reads, with the tripwire armed.
/// Any Bridge row refuses the whole command before tokens, AppleScript or REST.
final class PlaylistIndexBoundaryTests: XCTestCase {
    private var h: BoundaryHarness!

    override func setUp() {
        h = BoundaryHarness()
    }

    override func tearDown() {
        h = nil
    }

    private func create(_ args: [String]) throws -> (output: String, error: Error?, calls: [ExternalCall]) {
        let cmd = try PlaylistCreate.parse(args)
        let deps = h.deps
        let (captured, calls) = withTripwire { captureStdout { try cmd.execute(deps: deps) } }
        return (captured.output, captured.error, calls)
    }

    private func add(_ args: [String]) throws -> (output: String, error: Error?, calls: [ExternalCall]) {
        let cmd = try PlaylistAdd.parse(args)
        let deps = h.deps
        let (captured, calls) = withTripwire { captureStdout { try cmd.execute(deps: deps) } }
        return (captured.output, captured.error, calls)
    }

    private let refusal = "Result(s) 2, 3 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app."

    private func writeMixed() throws {
        try h.cache.writeSongs([
            .row(1, .catalog, catalogId: "cat1"),
            .row(2, .bridgeLibrary, bridgeID: "b2"),
            .row(3, .bridgeLibrary),
            .row(4, .library, catalogId: "pid4"),
        ])
    }

    // MARK: - playlist create

    func testCreateWithMixedOriginsRefusesWholeWithTokens() throws {
        try writeMixed()
        h.tokens = ("dev", "user")
        let r = try create(["Mix", "1", "2", "3", "4"])
        XCTAssertEqual(r.output, refusal + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.songReads, 1)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [], "neither a REST nor an AppleScript playlist is created")
    }

    func testCreateWithMixedOriginsRefusesWholeWithoutTokens() throws {
        try writeMixed()
        let r = try create(["Mix", "4", "2", "3"])
        XCTAssertEqual(r.output, refusal + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    func testCreateWithOnlyLibraryAndBridgeRowsRefusesWhole() throws {
        try writeMixed()
        let r = try create(["Mix", "4", "2"])
        XCTAssertEqual(r.output, "Result(s) 2 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.\n")
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [], "no AppleScript make/duplicate")
    }

    func testCreateRefusalUnderJSONIsOneDocument() throws {
        try writeMixed()
        let r = try create(["Mix", "2", "3", "--json"])
        let doc = try JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
        XCTAssertEqual(doc?["ok"] as? Bool, false)
        XCTAssertEqual(doc?["error"] as? String, refusal)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    /// Not over-broad: no Bridge rows and no tokens reaches the shipped message.
    func testCreateWithNoBridgeRowsAndNoTokensReachesNeedsAuthToSeed() throws {
        try writeMixed()
        let r = try create(["Mix", "1"])
        XCTAssertEqual(r.output, """
            Adding tracks to a new playlist needs a Music User Token. Run: music auth setup
            Creating an empty playlist needs no token: music playlist create "Mix"
            Tracks from a library search need no token: music search "query" --library, then music playlist create "Mix" 1 2

            """)
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 1)
        XCTAssertEqual(r.calls, [])
    }

    /// Tokens are read after the lookup, and the shipped REST create follows.
    func testCreateWithCatalogueRowAndTokensReachesTheShippedRESTCreate() throws {
        try writeMixed()
        h.tokens = ("dev", "user")
        let r = try create(["Mix", "1"])
        XCTAssertEqual(h.songReads, 1)
        XCTAssertEqual(h.authReads, 1)
        XCTAssertEqual(r.calls, [.http(method: "POST", path: "/v1/me/library/playlists")])
        XCTAssertTrue(r.error is ExternalCallBlocked, "\(String(describing: r.error))")
    }

    // MARK: - playlist add

    func testAddWithMixedOriginsRefusesWholeWithTokens() throws {
        try writeMixed()
        h.tokens = ("dev", "user")
        let r = try add(["Mix", "1", "2", "3", "4"])
        XCTAssertEqual(r.output, refusal + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.songReads, 1)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    func testAddWithLibraryAndBridgeRowsRefusesWholeWithoutTokens() throws {
        try writeMixed()
        let r = try add(["Mix", "4", "3", "2"])
        XCTAssertEqual(r.output, "Result(s) 3, 2 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app.\n",
                       "Bridge rows are named in the order they were typed")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [], "no AppleScript duplicate")
    }

    /// Not over-broad: no Bridge rows and no tokens reaches the shipped message.
    func testAddWithCatalogueRowAndNoTokensReachesNeedsAuthForIndices() throws {
        try writeMixed()
        let r = try add(["Mix", "1"])
        XCTAssertEqual(r.output, """
            Adding by result index needs a Music User Token. Run: music auth setup
            Adding a track you already own needs no token: music playlist add "Mix" "Song Title"
            Indices from a library search need no token: music search "query" --library, then music playlist add "Mix" 1 2

            """)
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 1)
        XCTAssertEqual(r.calls, [])
    }

    /// A title (not indices) never reads the cache and is not refused.
    func testAddByTitleDoesNotReadTheCache() throws {
        try writeMixed()
        let r = try add(["Mix", "Teardrop"])
        XCTAssertEqual(h.songReads, 0)
        XCTAssertEqual(h.authReads, 1)
        XCTAssertEqual(r.calls.count, 1, "the shipped keyless library duplicate")
        guard case .appleScript? = r.calls.first else { return XCTFail("expected AppleScript") }
    }
}
