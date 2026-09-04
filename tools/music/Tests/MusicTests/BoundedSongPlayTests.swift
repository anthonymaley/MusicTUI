import XCTest
@testable import music

/// Bounded single-song play.
///
/// The gate these tests exist for (Anthony, 2026-09-03): confirmation must
/// check the created container's single track IDENTITY, not merely that it
/// holds one track, "otherwise the wrong duplicated row could satisfy the seed
/// gate". `buildContainer`'s own check is a COUNT check, so a container holding
/// one wrong track passes it; only `playBoundedSong`'s confirm hook catches
/// that, and `testWrongTrackInContainerIsRefusedEvenThoughTheCountIsOne` is the
/// test that would fail if the confirm hook were reduced to a count.
final class BoundedSongPlayTests: XCTestCase {

    private let pid = "E066CAFFC631255C"

    private func row(_ index: Int, _ status: String = "subscribed") -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: "Sueno Latino (Winter Version)",
                        artist: "Sueno Latino", albumArtist: "Sueno Latino",
                        cloudStatus: status)
    }

    /// Every failure path below asserts this too: there is no fallback to
    /// `play track N of playlist "Library"`, the unbounded form this work
    /// exists to remove.
    private func assertNeverLibraryRooted(_ scripts: [String],
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(scripts.contains { $0.contains("play track") && $0.contains("playlist \"Library\"") },
                       "song play must never fall back to the library-rooted form",
                       file: file, line: line)
    }

    // MARK: - Identity, the gate a count check cannot hold

    func testWrongTrackInContainerIsRefusedEvenThoughTheCountIsOne() {
        var scripts: [String] = []
        var spawned = false
        let out = playBoundedSong(
            title: "Sueno Latino (Winter Version)", rows: [row(12384)],
            readIdentifier: { _ in self.pid }, uuid: "U",
            run: { s in
                scripts.append(s)
                // One track, so the seed count check passes. A DIFFERENT track.
                if s.contains("set ids to persistent ID") { return "AAAAAAAAAAAAAAAA" }
                if s.contains("count of tracks") { return "1" }
                return ""
            },
            launch: { _, _ in spawned = true; return true })

        XCTAssertEqual(out, .containerIdentityMismatch(expected: pid))
        XCTAssertFalse(spawned, "nothing may be handed to the watcher")
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") },
                       "a container whose identity is unconfirmed must not play")
        XCTAssertTrue(scripts.contains { $0.contains("delete") }, "it must be rolled back")
        assertNeverLibraryRooted(scripts)
    }

    func testConfirmedIdentityPlaysAndSpawnsTheWatcher() {
        var scripts: [String] = []
        var spawned = false
        let out = playBoundedSong(
            title: "Sueno Latino (Winter Version)", rows: [row(12384)],
            readIdentifier: { _ in self.pid }, uuid: "U",
            run: { s in
                scripts.append(s)
                if s.contains("set ids to persistent ID") { return self.pid }
                if s.contains("count of tracks") { return "1" }
                return ""
            },
            launch: { _, _ in spawned = true; return true })

        XCTAssertEqual(out, .playing)
        XCTAssertTrue(spawned)
        XCTAssertTrue(scripts.contains { $0.contains("play playlist") })
        assertNeverLibraryRooted(scripts)
    }

    // MARK: - The two unreadable states stay distinct

    func testUnreadableSourceIdentifierFailsClosedBeforeAnythingIsBuilt() {
        var scripts: [String] = []
        let out = playBoundedSong(
            title: "X", rows: [row(12384)],
            readIdentifier: { _ in nil }, uuid: "U",
            run: { s in scripts.append(s); return "" },
            launch: { _, _ in XCTFail("nothing may be launched"); return false })

        XCTAssertEqual(out, .identifierUnreadable)
        XCTAssertFalse(scripts.contains { $0.contains("make new playlist") },
                       "no container may be built without an identifier to confirm it by")
        assertNeverLibraryRooted(scripts)
    }

    func testUnreadableContainerReadIsItsOwnStateNotAnIdentityMismatch() {
        var scripts: [String] = []
        let out = playBoundedSong(
            title: "X", rows: [row(12384)],
            readIdentifier: { _ in self.pid }, uuid: "U",
            run: { s in
                scripts.append(s)
                if s.contains("set ids to persistent ID") { return nil }  // AppleScript failed
                if s.contains("count of tracks") { return "1" }
                return ""
            },
            launch: { _, _ in XCTFail("nothing may be launched"); return false })

        XCTAssertEqual(out, .containerReadFailed)
        XCTAssertNotEqual(out, .containerIdentityMismatch(expected: pid),
                          "a failed read is not a mismatch; the messages differ")
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
        assertNeverLibraryRooted(scripts)
    }

    // MARK: - Resolution failures

    func testNoRowsIsNotFoundAndBuildsNothing() {
        var scripts: [String] = []
        let out = playBoundedSong(
            title: "X", rows: [],
            readIdentifier: { _ in self.pid }, uuid: "U",
            run: { s in scripts.append(s); return "" },
            launch: { _, _ in XCTFail("nothing may be launched"); return false })

        XCTAssertEqual(out, .notFound)
        XCTAssertFalse(scripts.contains { $0.contains("make new playlist") })
        assertNeverLibraryRooted(scripts)
    }

    func testMatchedButUnplayableRowsReportNonePlayable() {
        var scripts: [String] = []
        let out = playBoundedSong(
            title: "X", rows: [row(1, "prerelease"), row(2, "prerelease")],
            readIdentifier: { _ in self.pid }, uuid: "U",
            run: { s in scripts.append(s); return "" },
            launch: { _, _ in XCTFail("nothing may be launched"); return false })

        XCTAssertEqual(out, .nonePlayable(matched: 2))
        assertNeverLibraryRooted(scripts)
    }

    // MARK: - Seeding

    func testTheSongSeedAddressesItsRowByIdentifierNeverByIndex() {
        let s = songContainerBuildScript(name: "__album__ U — Song", persistentID: pid)
        XCTAssertTrue(s.contains("whose persistent ID is \"\(pid)\""))
        XCTAssertFalse(s.contains("duplicate track "),
                       "an index seed is the fragile handle this path exists to avoid")
    }

    // MARK: - Messages

    func testEachFailureStateHasItsOwnMessage() {
        let messages = [
            songOutcomeMessage(.notFound, title: "X"),
            songOutcomeMessage(.nonePlayable(matched: 2), title: "X"),
            songOutcomeMessage(.identifierUnreadable, title: "X"),
            songOutcomeMessage(.containerReadFailed, title: "X"),
            songOutcomeMessage(.containerIdentityMismatch(expected: pid), title: "X"),
        ].map { $0 ?? "" }
        XCTAssertNil(songOutcomeMessage(.playing, title: "X"),
                     "playback started, so there is nothing to say")
        XCTAssertEqual(Set(messages).count, messages.count,
                       "each failure state must be distinguishable in a bug report")
        XCTAssertFalse(messages.contains { $0.lowercased().contains("album") },
                       "a song path must not speak in albums")
    }
}
