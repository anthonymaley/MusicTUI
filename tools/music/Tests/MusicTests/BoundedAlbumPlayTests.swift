import XCTest
@testable import music

final class BoundedAlbumPlayTests: XCTestCase {

    private func rows(_ n: Int) -> [LibraryAlbumRow] {
        (1...n).map {
            LibraryAlbumRow(index: $0, name: "T\($0)", artist: "A",
                            albumArtist: "A", cloudStatus: "subscription",
                            disc: 1, track: $0)
        }
    }

    /// Pull the ids passed to `--ids` out of a watcher argument list, the same
    /// way `watcherArguments` builds them: sorted, comma joined.
    private func idsArgument(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--ids"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Happy path: build, capture ids, play, spawn. No shuffle write anywhere.
    ///
    /// `containerTrackIDsScript` contains BOTH "count of tracks" and
    /// "persistent ID of every track" (it counts before it reads), so the
    /// mock must key on the unambiguous "set ids to persistent ID" — a
    /// substring unique to the ids script — checked before the count check,
    /// or the count branch swallows the ids call and the watcher gets a
    /// bogus one-element id set with nobody noticing.
    func testPlaysAndSpawnsWatcherWithoutTouchingShuffle() {
        var scripts: [String] = []
        var spawned = false
        var launchedArgs: [String]?
        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") {
                                           return "A\u{1F}B\u{1F}C"
                                       }
                                       if s.contains("count of tracks") { return "3" }
                                       return ""
                                   },
                                   launch: { _, args in
                                       spawned = true
                                       launchedArgs = args
                                       return true
                                   })
        XCTAssertEqual(out, .playing)
        XCTAssertTrue(spawned)
        XCTAssertTrue(scripts.contains { $0.contains("play playlist") })
        XCTAssertFalse(scripts.contains { $0.contains("shuffle enabled") },
                       "the user's shuffle setting must never be written")
        // Positive proof the ids reaching the watcher are the ones parsed
        // from the CONTAINER's read, not something else (e.g. the bogus
        // count-string collision above).
        XCTAssertEqual(idsArgument(launchedArgs ?? []), "A,B,C")
    }

    func testNoPlayableTracksPlaysNothing() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: [], uuid: "U",
                                   run: { s in scripts.append(s); return "" },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .notFound)
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    func testMatchedButNonePlayable() {
        let unplayable = [LibraryAlbumRow(index: 1, name: "T1", artist: "A",
                                          albumArtist: "A", cloudStatus: "removed",
                                          disc: 1, track: 1)]
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: unplayable, uuid: "U",
                                   run: { s in scripts.append(s); return "" },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .nonePlayable(matched: 1))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    /// Fail closed: a seed mismatch must not play. The build's own rollback
    /// already deleted the container successfully, so the caller can say so.
    func testSeedMismatchDeletesAndDoesNotPlay() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .buildFailed(containerRemoved: true))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
        XCTAssertTrue(scripts.contains { $0.contains("every user playlist whose name is") })
    }

    /// When the build fails AND its own rollback delete also fails, the caller
    /// must be told the container may still exist, not that it was removed.
    func testBuildFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .buildFailed(containerRemoved: false))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    func testPlayFailureDeletesTheContainer() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B" }
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("play playlist") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playFailed(containerRemoved: true))
        XCTAssertTrue(scripts.last!.contains("every user playlist whose name is"))
    }

    /// Play fails, and the rollback delete for that failure ALSO fails: the
    /// caller must be told the container was not removed, not the opposite.
    func testPlayFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B" }
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("play playlist") { return nil }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playFailed(containerRemoved: false))
    }

    /// Playback is ALREADY running when the watcher is spawned, so this rollback
    /// must also stop the audio it started.
    func testWatcherLaunchFailurePausesAndDeletes() {
        var scripts: [String] = []
        var launchedArgs: [String]?
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B" }
                                       if s.contains("count of tracks") { return "2" }
                                       return ""
                                   },
                                   launch: { _, args in launchedArgs = args; return false })
        XCTAssertEqual(out, .watcherFailed(containerRemoved: true))
        XCTAssertTrue(scripts.contains { $0.trimmingCharacters(in: .whitespaces) == "pause" },
                      "must pause the audio it started")
        XCTAssertTrue(scripts.last!.contains("every user playlist whose name is"))
        // The launcher is invoked (and its args built from the parsed
        // container ids) even though it reports failure here.
        XCTAssertEqual(idsArgument(launchedArgs ?? []), "A,B")
    }

    /// Watcher spawn fails, and the rollback delete for that failure ALSO
    /// fails: playback stays paused (already handled) but the caller must be
    /// told the container was not removed.
    func testWatcherFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        var launchedArgs: [String]?
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B" }
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, args in launchedArgs = args; return false })
        XCTAssertEqual(out, .watcherFailed(containerRemoved: false))
        XCTAssertTrue(scripts.contains { $0.trimmingCharacters(in: .whitespaces) == "pause" })
        XCTAssertEqual(idsArgument(launchedArgs ?? []), "A,B")
    }

    // MARK: - §16.1: the next-invocation stale sweep

    /// The sweep must run BEFORE the container is built — it is the whole
    /// point of "next invocation recovery": a crashed watcher's orphan from a
    /// PREVIOUS play is collected before THIS play creates its own container.
    func testSweepsStaleAlbumContainersBeforeBuildingANewOne() {
        var scripts: [String] = []
        _ = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U",
                             run: { s in
                                 scripts.append(s)
                                 if s.contains("set ids to persistent ID") { return "A\u{1F}B\u{1F}C" }
                                 if s.contains("count of tracks") { return "3" }
                                 return ""
                             },
                             launch: { _, _ in true })
        XCTAssertEqual(scripts.first, albumStaleSweepScript(),
                       "the stale sweep must be the very first script run, before any container is built")
        XCTAssertFalse(scripts.first?.contains("make new playlist") ?? true)
    }

    /// The sweep's own result must never gate this play: even if the sweep
    /// script itself fails outright (e.g. a genuine AppleScript error), the
    /// play must still proceed and succeed.
    func testASweepFailureDoesNotBlockThisPlayFromStarting() {
        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U",
                                   run: { s in
                                       if s == albumStaleSweepScript() { return nil }
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B\u{1F}C" }
                                       if s.contains("count of tracks") { return "3" }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playing)
    }

    // MARK: - §16.6: bounded album resolution

    /// The broad-query regression at the `playBoundedAlbum` level: rows
    /// spanning more than one distinct album must never be built into one
    /// container. Nothing is played.
    func testAmbiguousAlbumMatchPlaysNothing() {
        let spanning = [
            LibraryAlbumRow(index: 1, name: "T1", artist: "A", albumArtist: "A",
                            cloudStatus: "subscription", disc: 1, track: 1, album: "Live in NYC"),
            LibraryAlbumRow(index: 2, name: "T2", artist: "B", albumArtist: "B",
                            cloudStatus: "subscription", disc: 1, track: 1, album: "Live from Tokyo"),
        ]
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "live", rows: spanning, uuid: "U",
                                   run: { s in scripts.append(s); return "" },
                                   launch: { _, _ in true })
        guard case .ambiguous(let albums) = out else {
            return XCTFail("expected .ambiguous, got \(out)")
        }
        XCTAssertEqual(Set(albums), Set(["Live in NYC", "Live from Tokyo"]))
        XCTAssertFalse(scripts.contains { $0.contains("make new playlist") },
                       "an ambiguous match must never build a container")
    }

    // MARK: - §17.1: the chosen album must actually reach the container

    /// The core §17.1 defect: `decideAlbumPlay` groups rows and picks one
    /// album, but the unique-exact-match branch (`exact.count == 1`) is
    /// reachable even when `groups.count > 1` — the common real-library shape
    /// of `--album "Kid A"` also matching *Kid A Mnesia*. The seeded
    /// container must contain ONLY the exact match's own track indices, never
    /// the other album's, even though both rows arrive in the same fetch.
    func testExactMatchSeedsOnlyItsOwnAlbumEvenWhenAnotherAlbumSharesTheQuery() {
        let rows = [
            // "Kid A Mnesia" rows interleaved BEFORE and AFTER "Kid A" in
            // fetch order, so a flat/full-rows seed would visibly mix them.
            LibraryAlbumRow(index: 90, name: "KAM1", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 1, album: "Kid A Mnesia"),
            LibraryAlbumRow(index: 10, name: "KA1", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 1, album: "Kid A"),
            LibraryAlbumRow(index: 91, name: "KAM2", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 2, album: "Kid A Mnesia"),
            LibraryAlbumRow(index: 11, name: "KA2", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 2, album: "Kid A"),
            LibraryAlbumRow(index: 12, name: "KA3", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 3, album: "Kid A"),
            LibraryAlbumRow(index: 92, name: "KAM3", artist: "Radiohead", albumArtist: "Radiohead",
                            cloudStatus: "subscription", disc: 1, track: 3, album: "Kid A Mnesia"),
        ]
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "Kid A", rows: rows, uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("set ids to persistent ID") { return "A\u{1F}B\u{1F}C" }
                                       if s.contains("count of tracks") { return "3" }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playing)
        guard let buildScript = scripts.first(where: { $0.contains("duplicate track") }) else {
            return XCTFail("no build script was ever sent")
        }
        for line in buildScript.split(separator: "\n") where line.contains("duplicate track") {
            XCTAssertTrue(line.contains("of playlist \"Library\""),
                          "each seed line must duplicate from Library: \(line)")
        }
        let duplicatedIndices = Set(buildScript
            .matches(of: try! Regex("duplicate track (\\d+) of playlist \"Library\""))
            .compactMap { Int($0[1].substring ?? "") })
        XCTAssertEqual(duplicatedIndices, [10, 11, 12],
                       "only 'Kid A's own indices may be duplicated into the container")
        XCTAssertTrue(duplicatedIndices.isDisjoint(with: [90, 91, 92]),
                      "'Kid A Mnesia's tracks must never be duplicated into 'Kid A's container")
    }

    // MARK: - "Also fix while in these files": manifest left behind on watcher failure

    /// A large album (manifest path, since ids exceed the inline limit) whose
    /// watcher fails to spawn must not leave its manifest behind, even though
    /// `spawnAlbumWatcher` already tries to clean it up itself — this is the
    /// caller-level belt-and-braces cleanup named in the task brief.
    func testWatcherLaunchFailureForALargeAlbumRemovesTheManifest() {
        let bigIDs = (1...(albumWatcherInlineIDLimit + 10)).map { "ID\($0)" }
        let bigRows = bigIDs.enumerated().map { i, _ in
            LibraryAlbumRow(index: i + 1, name: "T\(i)", artist: "A", albumArtist: "A",
                            cloudStatus: "subscription", disc: 1, track: i + 1)
        }
        let uuid = "TEST-\(UUID().uuidString)"
        let manifestPath = albumManifestPath(uuid: uuid)!
        defer { removeAlbumManifest(path: manifestPath) }

        let out = playBoundedAlbum(title: "Big Album", rows: bigRows, uuid: uuid,
                                   run: { s in
                                       if s.contains("set ids to persistent ID") {
                                           return bigIDs.joined(separator: "\u{1F}")
                                       }
                                       if s.contains("count of tracks") { return "\(bigIDs.count)" }
                                       return ""
                                   },
                                   launch: { _, _ in false })

        guard case .watcherFailed = out else {
            return XCTFail("expected .watcherFailed, got \(out)")
        }
        XCTAssertNil(readAlbumManifest(path: manifestPath),
                     "a large album's manifest must not survive a watcher launch failure")
    }
}
