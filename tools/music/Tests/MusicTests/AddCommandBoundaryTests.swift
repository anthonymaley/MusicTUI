import ArgumentParser
import XCTest
@testable import music

/// Score S3: `music add N` runs its real body (`Add.execute`) against a temp
/// cache, counting auth reads, with the tripwire armed. The Bridge-row guard is
/// proven here: without it the body reaches the token read or the tripwire.
final class AddCommandBoundaryTests: XCTestCase {
    private var h: BoundaryHarness!

    override func setUp() {
        h = BoundaryHarness()
    }

    override func tearDown() {
        h = nil
    }

    private func run(_ args: [String]) throws -> (output: String, error: Error?, calls: [ExternalCall]) {
        let add = try Add.parse(args)
        let deps = h.deps
        let (captured, calls) = withTripwire { captureStdout { try add.execute(deps: deps) } }
        return (captured.output, captured.error, calls)
    }

    private let refusal2 = "Result(s) 2 came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app."

    func testBridgeRowIsRefusedBeforeAnyTokenOrExternalCall() throws {
        try h.cache.writeSongs([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "12345")])
        h.tokens = ("dev", "user")
        let r = try run(["2"])
        XCTAssertEqual(r.output, refusal2 + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.songReads, 1)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    func testBridgeRowWithTargetsIsRefusedBeforeAnyTokenOrExternalCall() throws {
        try h.cache.writeSongs([.row(1, .catalog), .row(2, .bridgeLibrary, bridgeID: "12345")])
        h.tokens = ("dev", "user")
        let r = try run(["2", "--to", "Mix"])
        XCTAssertEqual(r.output, refusal2 + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [], "no AppleScript duplicate of a Bridge row")
    }

    func testBridgeRowWithNoIdIsRefusedTheSameWay() throws {
        try h.cache.writeSongs([.row(2, .bridgeLibrary)])
        let r = try run(["2", "--to", "Mix"])
        XCTAssertEqual(r.output, refusal2 + "\n")
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    func testBridgeRowRefusalUnderJSONIsOneDocument() throws {
        try h.cache.writeSongs([.row(2, .bridgeLibrary, bridgeID: "1")])
        let r = try run(["2", "--json"])
        let doc = try JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
        XCTAssertEqual(doc?["ok"] as? Bool, false)
        XCTAssertEqual(doc?["error"] as? String, refusal2)
        XCTAssertEqual((r.error as? ExitCode), .failure)
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }

    /// The shipped catalogue path, unchanged: one cache read (it used to be
    /// two), then tokens, then exactly one POST for the row that read returned.
    func testCatalogueRowReadsOnceAndPostsThatRowsId() throws {
        try h.cache.writeSongs([.row(1, .catalog, catalogId: "cat111"), .row(2, .catalog, catalogId: "cat222")])
        h.tokens = ("dev", "user")
        let r = try run(["2"])
        XCTAssertEqual(h.songReads, 1)
        XCTAssertEqual(h.authReads, 1)
        XCTAssertEqual(r.calls, [.http(method: "POST", path: "/v1/me/library?ids%5Bsongs%5D=cat222")])
        XCTAssertTrue(r.error is ExternalCallBlocked, "\(String(describing: r.error))")
        XCTAssertEqual(r.output, "Found: T2 — A2 [AL2]\n")
    }

    /// A library row with targets still goes to the AppleScript duplicate,
    /// token-free: the guard is not over-broad.
    func testLibraryRowWithTargetsStillDuplicatesWithoutTokens() throws {
        try h.cache.writeSongs([.row(1, .library, catalogId: "pid1")])
        let r = try run(["1", "--to", "Mix"])
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls.count, 1)
        guard case .appleScript(let script)? = r.calls.first else { return XCTFail("expected one AppleScript call") }
        XCTAssertTrue(script.contains("duplicate item 1 of results to playlist \"Mix\""), script)
        XCTAssertEqual((r.error as? ExitCode), .failure, "the blocked duplicate lands nowhere")
    }

    func testLibraryRowWithoutTargetsIsAlreadyInLibrary() throws {
        try h.cache.writeSongs([.row(1, .library)])
        let r = try run(["1"])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.output, "Already in your library: T1 by A1.\n")
        XCTAssertEqual(h.authReads, 0)
        XCTAssertEqual(r.calls, [])
    }
}
