// tools/music/Tests/MusicTests/MusicTUIHandoffTests.swift
//
// Score: data route and output, step 7 (C-HANDOFF). A SpanDAC LIBRARY row
// plays on the MusicTUI output by the persistent ID SpanDAC reported for it,
// verified against Apple's Music app by identity before anything plays.
//
// Nothing here plays or reads a real library. The verification reads are a
// fake (or a recording script runner), the queue player is a recorder, and
// the external-call tripwire is armed around every hand-off, so a path that
// reached a real AppleScript would be recorded and blocked. The one test that
// drives the live script builders does so THROUGH the armed tripwire, which
// records the script and throws before any process runs. Every store and
// cache is under NSTemporaryDirectory().
import XCTest
@testable import music

/// The verification read, scripted per persistent ID; counts every read.
final class FakePersistentIDLibrary: PersistentIDTrackReading {
    var hits: [String: [HandoffTrackHit]]
    var failure: Error?
    private(set) var reads: [[String]] = []
    init(_ hits: [String: [HandoffTrackHit]] = [:]) { self.hits = hits }
    func tracks(persistentIDs: [String]) throws -> [String: [HandoffTrackHit]] {
        reads.append(persistentIDs)
        if let failure { throw failure }
        return hits.filter { persistentIDs.contains($0.key) }
    }
}

/// Records every queue the hand-off asked to play; plays nothing.
final class RecordingHandoffQueuePlayer: HandoffQueuePlaying {
    private(set) var queues: [AppQueue] = []
    func play(_ queue: AppQueue) throws { queues.append(queue) }
}

final class MusicTUIHandoffTests: XCTestCase {

    // Three aliases whose hex form `PersistentIDAliasTests` pins.
    private let a1 = "596357614188841472", h1 = "0846B01728D34A00"
    private let a2 = "-2898457328848859944", h2 = "D7C69C6A85560CD8"
    private let a3 = "854956139719541203", h3 = "0BDD6A144E85C1D3"

    private func song(_ id: String, _ title: String, _ alias: String?, artist: String = "Massive Attack",
                      album: String? = "Mezzanine") -> MusicRow {
        MusicRow(id: id, title: title, artist: artist, album: album, kind: .song, alias: alias)
    }
    private func inLibrary(_ pid: String, _ name: String, db: String, at index: Int) -> HandoffTrackHit {
        HandoffTrackHit(persistentID: pid, inLibrary: true, databaseID: db, libraryIndex: index, name: name)
    }
    private func inPlaylist(_ pid: String, _ name: String, db: String) -> HandoffTrackHit {
        HandoffTrackHit(persistentID: pid, inLibrary: false, databaseID: db, libraryIndex: nil, name: name)
    }

    private func mezzanineHits() -> [String: [HandoffTrackHit]] {
        [h1: [inLibrary(h1, "Angel", db: "101", at: 11)],
         h2: [inLibrary(h2, "Risingson", db: "102", at: 12)],
         h3: [inLibrary(h3, "Teardrop", db: "103", at: 13)]]
    }

    private func handoff(_ library: PersistentIDTrackReading, _ player: HandoffQueuePlaying,
                         selfCheck: LibraryAliasSelfCheck = LibraryAliasSelfCheck(),
                         stamp: @escaping () -> MusicTUIHandoffStamp? = { MusicTUIHandoffStamp(epoch: 3, dataEpoch: 1) })
        -> PersistentIDHandoff {
        PersistentIDHandoff(library: library, player: player, selfCheck: selfCheck, currentStamp: stamp)
    }

    /// Runs `body` with the tripwire armed; returns its error and the calls it recorded.
    private func tripwired(_ body: () throws -> Void) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire { do { try body() } catch { thrown = error } }.calls
        return (thrown, calls)
    }

    private func message(_ error: Error?) -> String? {
        (error as? ActionError)?.message ?? error.map { $0.localizedDescription }
    }

    // MARK: - Named tests (score step 7)

    func testAnAlbumWhoseTracksAllResolvePlaysByPersistentID() {
        let library = FakePersistentIDLibrary(mezzanineHits())
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", a2), song("l.3", "Teardrop", a3)]

        let r = tripwired {
            try handoff(library, player).playLibrary(rows: rows, startAt: 2, shuffle: false, title: "Mezzanine")
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [], "no real AppleScript: reads and play went to the fakes")
        XCTAssertEqual(library.reads, [[h1, h2, h3]], "one verification read, every track, before any play")
        XCTAssertEqual(player.queues.count, 1, "then exactly one queue")
        guard let q = player.queues.first else { return XCTFail("nothing was queued") }
        XCTAssertEqual(q.playlistName, persistentIDQueueSource)
        XCTAssertEqual(q.displayName, "Mezzanine")
        XCTAssertEqual(q.contextLabel, "Mezzanine")
        XCTAssertEqual(q.currentIndex, 2, "the whole album is queued, starting at the chosen track")
        XCTAssertEqual(q.tracks.map { persistentIDOfQueueEntry($0.index) }, [h1, h2, h3])
        XCTAssertEqual(q.tracks.map(\.name), ["Angel", "Risingson", "Teardrop"])
        XCTAssertEqual(q.tracks.map(\.artist), ["Massive Attack", "Massive Attack", "Massive Attack"])
    }

    func testAMissingAliasRefusesTheWholePlay() {
        let library = FakePersistentIDLibrary(mezzanineHits())
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", nil), song("l.3", "Teardrop", a3)]
        let r = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
        XCTAssertEqual(message(r.error), pickASpanDACOutput)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(library.reads, [], "refused before any read")
        XCTAssertEqual(player.queues, [], "no partial queue")
    }

    func testAnAliasResolvingToTwoTracksRefuses() {
        var hits = mezzanineHits()
        hits[h2] = [inLibrary(h2, "Risingson", db: "102", at: 12), inLibrary(h2, "Risingson", db: "902", at: 90)]
        let library = FakePersistentIDLibrary(hits)
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", a2), song("l.3", "Teardrop", a3)]
        let r = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
        XCTAssertEqual(message(r.error), pickASpanDACOutput)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(player.queues, [])
    }

    func testAnAliasResolvingToNoTrackRefuses() {
        var hits = mezzanineHits()
        hits[h3] = []
        let library = FakePersistentIDLibrary(hits)
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", a2), song("l.3", "Teardrop", a3)]
        let r = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
        XCTAssertEqual(message(r.error), pickASpanDACOutput)
        XCTAssertEqual(player.queues, [])

        // Absent from the read's answer altogether is the same refusal.
        hits.removeValue(forKey: h3)
        library.hits = hits
        let again = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
        XCTAssertEqual(message(again.error), pickASpanDACOutput)
        XCTAssertEqual(player.queues, [])
    }

    func testANameMismatchRefuses() {
        var hits = mezzanineHits()
        hits[h2] = [inLibrary(h2, "Risingson (Remix)", db: "102", at: 12)]
        let library = FakePersistentIDLibrary(hits)
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", a2), song("l.3", "Teardrop", a3)]
        let r = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
        XCTAssertEqual(message(r.error), pickASpanDACOutput)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(player.queues, [])
    }

    func testATrackOnlyInAUserPlaylistStillResolves() {
        // In two user playlists and not in the library playlist: one persistent
        // ID in several playlists is one track.
        let library = FakePersistentIDLibrary([
            h1: [inPlaylist(h1, "Angel", db: "501"), inPlaylist(h1, "Angel", db: "502")],
        ])
        let player = RecordingHandoffQueuePlayer()
        let r = tripwired {
            try handoff(library, player).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1, shuffle: false,
                                                     title: "Angel")
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(player.queues.map { $0.tracks.map { persistentIDOfQueueEntry($0.index) } }, [[h1]])

        // But two DIFFERENT names for one identity is not one track.
        library.hits = [h1: [inPlaylist(h1, "Angel", db: "501"), inPlaylist(h1, "Angel (Live)", db: "502")]]
        let mixed = tripwired {
            try handoff(library, player).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1, shuffle: false,
                                                     title: "Angel")
        }
        XCTAssertEqual(message(mixed.error), pickASpanDACOutput)
        XCTAssertEqual(player.queues.count, 1, "nothing more was queued")
    }

    func testAnUnparsableAliasRefuses() {
        let library = FakePersistentIDLibrary(mezzanineHits())
        let player = RecordingHandoffQueuePlayer()
        for bad in ["", "i.ZOQG3ubmB32M", "12.5", "0x2034218F875BE907", "99999999999999999999999"] {
            let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", bad)]
            let r = tripwired { try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine") }
            XCTAssertEqual(message(r.error), pickASpanDACOutput, bad)
        }
        XCTAssertEqual(library.reads, [], "an unparsable alias refuses before any read")
        XCTAssertEqual(player.queues, [])
    }

    func testArtistSongsPlayByPersistentID() {
        let library = FakePersistentIDLibrary([
            h1: [inLibrary(h1, "Angel", db: "101", at: 11)],
            h2: [inLibrary(h2, "Unfinished Sympathy", db: "201", at: 40)],
            h3: [inPlaylist(h3, "Teardrop", db: "103")],
        ])
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", a1),
                    song("l.8", "Unfinished Sympathy", a2, album: "Blue Lines"),
                    song("l.3", "Teardrop", a3)]
        let r = tripwired {
            try handoff(library, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Massive Attack")
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(library.reads, [[h1, h2, h3]])
        let q = player.queues.first
        XCTAssertEqual(q?.tracks.map { persistentIDOfQueueEntry($0.index) }, [h1, h2, h3], "SpanDAC's order, kept")
        XCTAssertEqual(q?.tracks.map(\.album), ["Mezzanine", "Blue Lines", "Mezzanine"])
        XCTAssertEqual(q?.currentIndex, 1)
        XCTAssertEqual(q?.displayName, "Massive Attack")

        // Shuffled: the same verified tracks, in some order, from the top.
        let shuffled = RecordingHandoffQueuePlayer()
        XCTAssertNoThrow(try handoff(library, shuffled).playLibrary(rows: rows, startAt: 3, shuffle: true,
                                                                   title: "Massive Attack"))
        XCTAssertEqual(shuffled.queues.first.map { Set($0.tracks.map { persistentIDOfQueueEntry($0.index) }) },
                       [h1, h2, h3])
        XCTAssertEqual(shuffled.queues.first?.currentIndex, 1)
    }

    func testNoAliasOnAnyRowSaysSoOnceAndRefuses() {
        let check = LibraryAliasSelfCheck()
        // The first SpanDAC library page this process saw: songs, and not
        // one carried a persistent ID. Albums on a page decide nothing.
        check.observe([MusicRow(id: "a.1", title: "Mezzanine", artist: "Massive Attack", album: nil, kind: .album,
                                trackCount: 11)])
        XCTAssertNil(check.refusal(), "a page with no song rows decides nothing")
        check.observe([song("l.1", "Angel", nil), song("l.2", "Risingson", nil)])

        let library = FakePersistentIDLibrary(mezzanineHits())
        let player = RecordingHandoffQueuePlayer()
        let rows = [song("l.1", "Angel", nil)]
        let first = tripwired {
            try handoff(library, player, selfCheck: check).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Angel")
        }
        XCTAssertEqual(message(first.error), spanDACReportsNoTrackIdentities, "said once")
        let second = tripwired {
            try handoff(library, player, selfCheck: check).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Angel")
        }
        XCTAssertEqual(message(second.error), pickASpanDACOutput, "then refused as any missing identity is")
        // Even a row that somehow carries one is refused while the check stands: never a guess.
        let third = tripwired {
            try handoff(library, player, selfCheck: check).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1,
                                                                       shuffle: false, title: "Angel")
        }
        XCTAssertEqual(message(third.error), pickASpanDACOutput)
        XCTAssertEqual(library.reads, [])
        XCTAssertEqual(player.queues, [])
        XCTAssertEqual(first.calls + second.calls + third.calls, [])

        // A process whose first song page DID carry identities never says it.
        let fine = LibraryAliasSelfCheck()
        fine.observe([song("l.1", "Angel", a1), song("l.2", "Risingson", nil)])
        fine.observe([song("l.9", "Dissolved Girl", nil)])
        XCTAssertNil(fine.refusal())
    }

    func testNoTitleSearchIsEverAttempted() {
        // The live script builders, end to end: the verification read goes to
        // a recording runner, and the play goes to the real AppleScript funnel
        // with the tripwire ARMED, which records the script and throws before
        // any process runs (so the play fails, and the queue is cleared).
        let lines = [
            [h1, "L", "101", "11", "Angel"],
            [h2, "P", "102", "0", "Risingson"],
            [h2, "P", "102", "0", "Risingson"],
        ].map { $0.joined(separator: String(asFieldSep)) }
        var readScripts: [String] = []
        let reader = AppleScriptPersistentIDReader(run: { script in
            readScripts.append(script)
            return lines.joined(separator: "\n") + "\n"
        })
        let store = AppQueueStore()
        let player = AppQueueHandoffPlayer(store: store, playFirst: { queue in
            playQueueTrack(backend: AppleScriptBackend(), playlist: queue.playlistName,
                           position: queue.currentSourcePosition)
        })
        let rows = [song("l.1", "Angel", a1), song("l.2", "Risingson", a2)]
        let r = tripwired {
            try handoff(reader, player).playLibrary(rows: rows, startAt: 1, shuffle: false, title: "Mezzanine")
        }
        XCTAssertEqual(message(r.error), "Couldn't play 'Mezzanine'.", "the blocked play is a stated failure")
        XCTAssertNil(store.read(), "a queue that never started is not left behind")

        XCTAssertEqual(readScripts.count, 1, "one verification read for the whole album")
        XCTAssertEqual(r.calls.count, 1, "one play attempt reached the funnel")
        let playScripts = r.calls.compactMap { call -> String? in
            if case .appleScript(let script) = call { return script }
            return nil
        }
        XCTAssertEqual(playScripts.count, 1)
        let all = readScripts + playScripts
        for script in all {
            XCTAssertFalse(script.contains("whose name"), script)
            XCTAssertFalse(script.contains("name is"), script)
            XCTAssertFalse(script.contains("name contains"), script)
            XCTAssertFalse(script.lowercased().contains("search"), script)
        }
        XCTAssertTrue(readScripts[0].contains("whose persistent ID is"))
        XCTAssertTrue(readScripts[0].contains("\"\(h1)\"") && readScripts[0].contains("\"\(h2)\""))
        XCTAssertTrue(playScripts[0].contains("whose persistent ID is \"\(h1)\""), playScripts[0])
        XCTAssertTrue(playScripts[0].contains("play "), playScripts[0])
    }

    func testCLINamedAlbumPlaysByPersistentIDOnMusicTUIOutput() throws {
        let tracks = "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":1,\"items\":["
            + "{\"id\":\"l.1\",\"title\":\"Angel\",\"artist\":\"Massive Attack\",\"album\":\"Mezzanine\",\"kind\":\"song\",\"alias\":\"\(a1)\"},"
            + "{\"id\":\"l.2\",\"title\":\"Risingson\",\"artist\":\"Massive Attack\",\"album\":\"Mezzanine\",\"kind\":\"song\",\"alias\":\"\(a2)\"}"
            + "]}"
        let h = CLIDataRouteHarness(
            output: .musicApp, data: .accepted,
            dataReplies: ["slice.status": [CLIHandoffReplies.readyWithoutADAC],
                          "slice.libraryAlbums": [CLIBridgeLibraryReplies.page(op: "slice.libraryAlbums", kind: "album",
                                                                               [("a.1", "Mezzanine", "Massive Attack", "")])],
                          "slice.libraryAlbumTracks": [tracks]],
            recordSeams: false)
        let library = FakePersistentIDLibrary([
            h1: [inLibrary(h1, "Angel", db: "101", at: 11)],
            h2: [inLibrary(h2, "Risingson", db: "102", at: 12)],
        ])
        let runner = CLIContainerRunner(ids: [h1, h2])
        var launches = 0
        var shown: [Bool] = []
        var env = h.env
        env.libraryPlay = PersistentIDCLILibraryPlay(library: library, run: runner.run,
                                                     launch: { _, _ in launches += 1; return true },
                                                     selfCheck: LibraryAliasSelfCheck(),
                                                     afterPlay: { shown.append($0) })

        let r = tripwired {
            try runPlay(args: [], playlist: nil, album: "Mezzanine", song: nil, artist: nil, json: false,
                        env: env, musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail("shipped body"); return [] },
                                                                 resolveIndexed: { _, _ in XCTFail("shipped body") }))
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [], "no real AppleScript, REST or launch")
        XCTAssertEqual(library.reads, [[h1, h2]], "every track verified by persistent ID")
        XCTAssertEqual(h.dataWire.requests.compactMap { $0["op"] as? String },
                       ["slice.status", "slice.libraryAlbums", "slice.libraryAlbumTracks"])
        XCTAssertEqual(h.outputClientsBuilt, 0, "nothing is sent to a SpanDAC output")
        // The bounded container is seeded from exactly the verified tracks,
        // confirmed by identity, then played; nothing else plays.
        XCTAssertEqual(runner.builds, [[11, 12]])
        XCTAssertEqual(runner.plays.count, 1)
        XCTAssertEqual(launches, 1, "the shipped cleanup watcher")
        XCTAssertEqual(shown, [false])
        // The shipped stale-container sweep finds its own temporary
        // containers by their prefix; nothing else looks anything up by name.
        XCTAssertEqual(runner.scripts.first, albumStaleSweepScript())
        for script in runner.scripts.dropFirst() {
            XCTAssertFalse(script.contains("whose name"), script)
        }
    }

    // MARK: - Further pins

    func testAStampThatMovedBeforeThePlayPlaysNothing() {
        let library = FakePersistentIDLibrary(mezzanineHits())
        let player = RecordingHandoffQueuePlayer()
        var reads = 0
        let moving: () -> MusicTUIHandoffStamp? = {
            reads += 1
            return MusicTUIHandoffStamp(epoch: 3, dataEpoch: reads == 1 ? 1 : 2)
        }
        let r = tripwired {
            try handoff(library, player, stamp: moving).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1,
                                                                    shuffle: false, title: "Angel")
        }
        XCTAssertEqual(message(r.error), sourceChangedNothingPlayed)
        XCTAssertEqual(player.queues, [])

        // No longer SpanDAC data on the MusicTUI output: refused before any read.
        let gone = FakePersistentIDLibrary(mezzanineHits())
        let r2 = tripwired {
            try handoff(gone, player, stamp: { nil }).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1,
                                                                  shuffle: false, title: "Angel")
        }
        XCTAssertEqual(message(r2.error), sourceChangedNothingPlayed)
        XCTAssertEqual(gone.reads, [])
        XCTAssertEqual(player.queues, [])
    }

    func testAFailedVerificationReadPlaysNothing() {
        let library = FakePersistentIDLibrary(mezzanineHits())
        library.failure = AppleScriptBackend.ScriptError.timeout("read")
        let player = RecordingHandoffQueuePlayer()
        let r = tripwired {
            try handoff(library, player).playLibrary(rows: [song("l.1", "Angel", a1)], startAt: 1, shuffle: false,
                                                     title: "Angel")
        }
        XCTAssertEqual(message(r.error), "Couldn't check 'Angel' in your library, so nothing was played.")
        XCTAssertEqual(player.queues, [])
    }

    func testLibrarySongRowsDecodeTheirAliasAndNoOtherRowDoes() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryAlbumTracks": ["{\"ok\":true,\"generation\":1,\"items\":["
                + "{\"id\":\"l.1\",\"title\":\"Angel\",\"artist\":\"Massive Attack\",\"kind\":\"song\",\"alias\":\"\(a1)\"},"
                + "{\"id\":\"l.2\",\"title\":\"Risingson\",\"artist\":\"Massive Attack\",\"kind\":\"song\"}]}"],
            "slice.libraryAlbums": ["{\"ok\":true,\"generation\":1,\"total\":1,\"next_cursor\":null,\"items\":["
                + "{\"id\":\"a.1\",\"title\":\"Mezzanine\",\"artist\":\"Massive Attack\",\"kind\":\"album\",\"track_count\":11,\"alias\":\"\(a1)\"}]}"],
        ])
        let control = SourceAppControl(path: "/nonexistent/handoff-decode.sock", transport: wire.transport)
        let tracks = try control.libraryAlbumTracks(albumID: "a.1").rows
        XCTAssertEqual(tracks.map(\.alias), [a1, nil])
        let albums = try control.libraryAlbums(cursor: nil, limit: 100).rows
        XCTAssertEqual(albums.map(\.alias), [nil], "an album never carries one, even if sent")
    }

    func testAPersistentIDQueueContinuesWithItsOwnTracksUnderItsTitle() {
        let entries = [persistentIDQueueEntry(persistentID: h1, name: "Angel", artist: "Massive Attack", album: "Mezzanine"),
                       persistentIDQueueEntry(persistentID: h2, name: "Risingson", artist: "Massive Attack", album: nil)]
            .compactMap { $0 }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { persistentIDOfQueueEntry($0.index) }, [h1, h2], "the entry carries the identity")
        XCTAssertNil(persistentIDQueueEntry(persistentID: "not hex", name: "x", artist: "y", album: nil))
        let queue = AppQueue(playlistName: persistentIDQueueSource, tracks: entries, currentIndex: 1,
                             displayName: "Mezzanine")
        // At queue end the continuation offers the queue's own tracks under
        // its title, never a playlist looked up by name.
        XCTAssertEqual(continuationSource(for: queue),
                       .bounded(label: "Mezzanine", source: persistentIDQueueSource, tracks: entries))
        // The play script addresses the track by persistent ID only.
        let script = persistentIDPlayScript(h2)
        XCTAssertTrue(script.contains("whose persistent ID is \"\(h2)\""), script)
        XCTAssertFalse(script.contains("whose name"), script)
        // Through the shipped entry point (the poller, next/previous, Now's
        // jump and shuffle all call it), with the tripwire recording.
        let calls = withTripwire {
            playQueueTrack(backend: AppleScriptBackend(), playlist: persistentIDQueueSource, position: entries[1].index)
        }.calls
        XCTAssertEqual(calls.count, 1)
        if case .appleScript(let sent)? = calls.first {
            XCTAssertTrue(sent.contains("whose persistent ID is \"\(h2)\""), sent)
        } else {
            XCTFail("expected one AppleScript call, got \(calls)")
        }
        // An ordinary playlist still plays by position, unchanged.
        let shipped = withTripwire {
            playQueueTrack(backend: AppleScriptBackend(), playlist: "Library", position: 12)
        }.calls
        XCTAssertEqual(shipped, [.appleScript(script: "tell application \"Music\"\n    play track 12 of playlist \"Library\"\nend tell")])
    }

    func testCLIPlayNOfALibraryRowFindsItsIdentityByID() throws {
        let songs = "{\"ok\":true,\"op\":\"slice.librarySongs\",\"generation\":1,\"total\":2,\"next_cursor\":null,\"items\":["
            + "{\"id\":\"l.7\",\"title\":\"Angel\",\"artist\":\"Other\",\"album\":\"\",\"kind\":\"song\",\"alias\":\"\(a2)\"},"
            + "{\"id\":\"l.1\",\"title\":\"Angel\",\"artist\":\"Massive Attack\",\"album\":\"Mezzanine\",\"kind\":\"song\",\"alias\":\"\(a1)\"}"
            + "]}"
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted,
                                    dataReplies: ["slice.status": [CLIHandoffReplies.readyWithoutADAC],
                                                  "slice.librarySongs": [songs]],
                                    recordSeams: false)
        try h.env.cache.writeSongs([SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                               catalogId: "", origin: .bridgeLibrary, bridgeID: "l.1")])
        let library = FakePersistentIDLibrary([h1: [inLibrary(h1, "Angel", db: "101", at: 11)],
                                               h2: [inLibrary(h2, "Angel", db: "707", at: 70)]])
        let runner = CLIContainerRunner(ids: [h1])
        var env = h.env
        env.libraryPlay = PersistentIDCLILibraryPlay(library: library, run: runner.run, launch: { _, _ in true },
                                                     selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
        let r = tripwired {
            try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: env,
                        musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail("shipped body"); return [] },
                                                       resolveIndexed: { _, _ in XCTFail("shipped body") }))
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(library.reads, [[h1]], "the cached row's own id, never the same-named row")
        XCTAssertEqual(runner.builds, [[11]])

        // A cached row SpanDAC no longer lists refuses, and plays nothing.
        try h.env.cache.writeSongs([SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                               catalogId: "", origin: .bridgeLibrary, bridgeID: "l.gone")])
        h.dataWire.script("slice.status", [CLIHandoffReplies.readyWithoutADAC])
        h.dataWire.script("slice.librarySongs", [songs])
        let gone = tripwired {
            try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: env,
                        musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail("shipped body"); return [] },
                                                       resolveIndexed: { _, _ in XCTFail("shipped body") }))
        }
        XCTAssertNotNil(gone.error)
        XCTAssertEqual(h.io.out.last, pickASpanDACOutput)
        XCTAssertEqual(runner.builds, [[11]], "nothing more was built or played")
    }
}

/// A status with no DAC on this Mac: a data read must not care.
enum CLIHandoffReplies {
    static let readyWithoutADAC =
        #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"output":{"dac":"not_connected"}}}"#
}

/// A fake `ScriptRunner` for the CLI's bounded container: answers the
/// shipped sweep, build, identity read-back, play and delete scripts, and
/// records what was built and played. Runs nothing.
final class CLIContainerRunner {
    let ids: [String]
    private(set) var scripts: [String] = []
    private(set) var builds: [[Int]] = []
    private(set) var plays: [String] = []
    init(ids: [String]) { self.ids = ids }

    var run: ScriptRunner {
        return { [self] script in
            scripts.append(script)
            if script.contains("make new playlist") {
                let indices = script.components(separatedBy: "\n").compactMap { line -> Int? in
                    guard let r = line.range(of: "duplicate track ") else { return nil }
                    return Int(line[r.upperBound...].prefix { $0.isNumber })
                }
                builds.append(indices)
                return String(indices.count)
            }
            if script.contains("persistent ID of every track") {
                return ids.joined(separator: String(asFieldSep))
            }
            if script.hasPrefix("play playlist") {
                plays.append(script)
                return ""
            }
            return ""
        }
    }
}
