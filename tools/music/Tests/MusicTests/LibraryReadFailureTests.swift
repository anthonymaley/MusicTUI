import XCTest
@testable import music

/// A library read that did not answer is a different outcome from one that
/// matched nothing (2026-09-23: a 296-track Radiohead read timed out and the
/// footer said "Couldn't load 'Radiohead'.", which reads as "not in your
/// library"). No AppleScript runs here: the resolvers are injected.
final class LibraryReadFailureTests: XCTestCase {

    // MARK: - Message selection

    func testReadFailureSaysMusicDidNotAnswer() {
        XCTAssertEqual(emptyResolutionMessage(.readFailure, name: "Radiohead",
                                              unavailable: "unavailable", notFound: "notFound"),
                       "Music didn't answer while reading 'Radiohead'. Try again.")
    }

    func testMatchedButUnplayableKeepsItsMessage() {
        let res = AlbumResolution(tracks: [], matched: 3)
        XCTAssertEqual(emptyResolutionMessage(res, name: "X", unavailable: "unavailable", notFound: "notFound"),
                       "unavailable")
    }

    func testNothingMatchedKeepsItsMessage() {
        let res = AlbumResolution(tracks: [], matched: 0)
        XCTAssertEqual(emptyResolutionMessage(res, name: "X", unavailable: "unavailable", notFound: "notFound"),
                       "notFound")
    }

    /// The flag defaults off, so every existing `AlbumResolution(tracks:matched:)`
    /// is a successful read, and Equatable still tells the two empties apart.
    func testReadFailedDefaultsOffAndIsPartOfEquality() {
        XCTAssertFalse(AlbumResolution(tracks: [], matched: 0).readFailed)
        XCTAssertNotEqual(AlbumResolution(tracks: [], matched: 0), .readFailure)
    }

    // MARK: - The bulk script's empty guard

    /// A bulk property get of an empty `whose` set raises -1728 instead of
    /// returning {} (probed live 2026-09-23), so the count guard must run before
    /// the first bulk get or every "no match" becomes a read failure and the
    /// strict-then-loose fallbacks stop falling back.
    func testEmptyGuardPrecedesTheFirstBulkGet() throws {
        let script = libraryAlbumRowsScript(whereClause: "artist is \"A\"")
        let guardRange = try XCTUnwrap(script.range(of: "if (count of (every track of playlist \"Library\" whose artist is \"A\")) is 0 then return \"\""))
        let firstGet = try XCTUnwrap(script.range(of: "(index of every track of playlist \"Library\" whose artist is \"A\")"))
        XCTAssertLessThan(guardRange.lowerBound, firstGet.lowerBound)
    }

    /// Equal column lengths cannot catch a same-count change (a replace or
    /// reorder mid-read), so the matching set's database IDs are read before the
    /// first column and after the last, including after any per-column
    /// fallback, and compared before any row is assembled.
    func testTheIdSetIsReadAroundEveryColumnAndComparedBeforeAssembly() throws {
        let script = libraryAlbumRowsScript(whereClause: "artist is \"A\"")
        func at(_ needle: String) throws -> String.Index {
            try XCTUnwrap(script.range(of: needle), "missing: \(needle)").lowerBound
        }
        let hits = "every track of playlist \"Library\" whose artist is \"A\""
        let countGuard = try at("if (count of (\(hits))) is 0 then return \"\"")
        let before = try at("set idsBefore to (database ID of \(hits))")
        let firstColumn = try at("set ixs to (index of \(hits))")
        let lastFallback = try XCTUnwrap(script.range(of: "set end of als to al")).lowerBound
        let after = try at("set idsAfter to (database ID of \(hits))")
        let compare = try at("if idsAfter is not idsBefore then error")
        let assembly = try at("repeat with i from 1 to n")
        XCTAssertLessThan(countGuard, before)
        XCTAssertLessThan(before, firstColumn)
        XCTAssertLessThan(lastFallback, after)
        XCTAssertLessThan(after, compare)
        XCTAssertLessThan(compare, assembly)
        XCTAssertFalse(script.contains("& (item i of idsBefore)"), "the ids are not part of the output line")
    }

    // MARK: - Call sites (Music.app mode)

    private func scene(status: StatusStore, resolved: AlbumResolution) -> LibraryScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.musicApp)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: { _, _ in "" }) })
        let sources = LibraryDataSources(onAlbums: { _ in true }, onSongs: { _ in true },
                                         onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        return LibraryScene(backend: AppleScriptBackend(), routing: routing,
                            sources: sources, appQueue: AppQueueStore(),
                            status: status, actions: ActionRunner(status: status),
                            resolveAlbum: { _, _, _ in resolved },
                            resolveArtist: { _, _ in resolved },
                            // Never the real ~/.config/music/artist-tiers.json (C2 isolation).
                            resultCache: temporaryResultCache().cache)
    }

    private func settledText(_ status: StatusStore, seconds: Double = 2.0) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = status.current()?.text { return text }
            usleep(10_000)
        }
        return status.current()?.text
    }

    func testArtistReadFailureReachesTheFooter() {
        let status = StatusStore()
        scene(status: status, resolved: .readFailure).playArtist(name: "Radiohead", shuffle: false)
        XCTAssertEqual(settledText(status), "Music didn't answer while reading 'Radiohead'. Try again.")
        XCTAssertEqual(status.current()?.isError, true)
    }

    func testArtistNotFoundIsUnchanged() {
        let status = StatusStore()
        scene(status: status, resolved: AlbumResolution(tracks: [], matched: 0))
            .playArtist(name: "Radiohead", shuffle: false)
        XCTAssertEqual(settledText(status), "Couldn't load 'Radiohead'.")
    }

    func testAlbumReadFailureReachesTheFooter() {
        let status = StatusStore()
        scene(status: status, resolved: .readFailure)
            .playAlbum(title: "In Rainbows", artist: "Radiohead", shuffle: false)
        XCTAssertEqual(settledText(status), "Music didn't answer while reading 'In Rainbows'. Try again.")
    }
}
