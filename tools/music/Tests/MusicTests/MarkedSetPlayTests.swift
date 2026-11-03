// tools/music/Tests/MusicTests/MarkedSetPlayTests.swift
import XCTest
@testable import music

/// Combined play, step 5: `p` / `s` with marks play the marked set through
/// `refuseOpenDataPlayBeforeReading` and `routing.perform(.libraryPlay, ...)`,
/// as ONE identity-addressed queue whose first entry is confirmed by identity.
/// Marks from one data source refuse on the other before any read (the
/// SpanDAC route itself is `MarkedSetSpanDACPlayTests`). Nothing is ever
/// written to Music.
///
/// Every AppleScript goes to a fake interpreter (a temp shell script); the
/// mode file and caches are temp files; the confirmer is
/// `HonestPlayingTests.ConfirmRig` (fake clock, hand-run jobs). Nothing
/// reaches Music, osascript, the SpanDAC socket, the keychain or
/// ~/.config/music, and nothing waits on a fixed sleep.
final class MarkedSetPlayTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)
    private let fs = "\u{1F}"

    private func musicAppRouting() -> RoutingCoordinator {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.musicApp)
        return RoutingCoordinator(store: modeStore, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) })
    }

    private func entry(_ pid: String, _ name: String) -> TrackListEntry {
        persistentIDQueueEntry(persistentID: pid, name: name, artist: "Art", album: nil)!
    }

    /// The marked "Chill" playlist's own persistent ID, as the rail read it.
    private static let chillID = "00000000000000F1"

    /// Readers over canned data that count every read. Playlists are keyed by
    /// their persistent ID, the only key a marked playlist is read by.
    private final class CountingReaders {
        private let lock = NSLock()
        private var n = 0
        var albums: [String: AlbumResolution] = [:]
        var playlists: [String: [TrackListEntry]] = [:]
        var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
        private func bump() { lock.lock(); n += 1; lock.unlock() }
        var readers: MarkedSetReaders {
            MarkedSetReaders(
                album: { title, _ in self.bump(); return self.albums[title] ?? .readFailure },
                playlist: { pid in
                    self.bump()
                    return self.playlists[pid].map { .tracks($0) } ?? .missing
                })
        }
    }

    private func readers() -> CountingReaders {
        let r = CountingReaders()
        r.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                           entry("00000000000000A2", "Sexy Boy")], matched: 2)
        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop")]
        return r
    }

    private func libraryScene(backend: AppleScriptBackend, store: AppQueueStore, status: StatusStore,
                              actions: ActionRunner, marks: MarkedSetStore,
                              readers: MarkedSetReaders?) -> LibraryScene {
        let albums = [LibraryAlbum(id: "al0", name: "Moon Safari", artist: "Air", trackCount: 2)]
        let sources = LibraryDataSources(onAlbums: { page in _ = page(albums); return true },
                                         onSongs: { _ in true }, onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        let scene = LibraryScene(backend: backend, routing: musicAppRouting(), sources: sources, appQueue: store,
                                 status: status, actions: actions,
                                 resolveAlbum: { _, _, _ in
                                     XCTFail("a marked play never resolves the highlighted album by position")
                                     return .readFailure
                                 },
                                 resultCache: temporaryResultCache().cache,
                                 screenWidth: { 160 },
                                 marks: marks, markedSetReaders: readers)
        goToSubView(scene, .albums)
        XCTAssertTrue(settleScene(scene) { scene.render(frame: self.frame, snapshot: self.idle).contains("Moon Safari") },
                      "the albums never loaded")
        return scene
    }

    private func playlistsScene(backend: AppleScriptBackend, store: AppQueueStore, status: StatusStore,
                                actions: ActionRunner, marks: MarkedSetStore,
                                readers: MarkedSetReaders?) -> PlaylistsScene {
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Chill"]
        let s = PlaylistsScene(backend: backend, routing: musicAppRouting(),
                               playlists: ["Chill"], playlistIDs: [Self.chillID], sources: spy.sources(),
                               appQueue: store, status: status, actions: actions,
                               metaCache: temporaryPlaylistMetaCache().cache,
                               loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                               makeSources: { spy.makeSources($0) },
                               warmUpSleep: { _ in },
                               screenWidth: { 160 },
                               marks: marks, markedSetReaders: readers)
        _ = s.tick(snapshot: idle)
        return s
    }

    // MARK: - Marks from the other data source refuse before reading

    func testMarkedPlayRefusesBeforeReadingAcrossDataSources() {
        // Marks made on SpanDAC data, with MusicTUI's own data now (no SpanDAC
        // provider): refused, nothing read, nothing run.
        let counter = AppleScriptCallCounter()
        let r = readers()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let store = AppQueueStore()
        let marks = MarkedSetStore()
        marks.toggle(.playlist(id: "pl1", name: "Chill"), source: .bridge)
        playMarkedSet(marks.snapshot, shuffle: false, backend: counter.backend, appQueue: store,
                      routing: musicAppRouting(), actions: actions, status: status, spanDACData: { false },
                      readers: r.readers)
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, LibraryProvenance.musicAppSelectedBridgeList)
        XCTAssertEqual(r.reads, 0)
        XCTAssertEqual(counter.callCount, 0)
        XCTAssertNil(store.read())

        // Marks made on MusicTUI's own data, played after a switch to SpanDAC
        // data: refused as a list from before the switch, nothing read.
        let r2 = readers()
        let status2 = StatusStore()
        let actions2 = ActionRunner(status: status2)
        let marks2 = MarkedSetStore()
        marks2.toggle(.album(title: "Moon Safari", artist: "Air"), source: .musicApp)
        playMarkedSet(marks2.snapshot, shuffle: true, backend: counter.backend, appQueue: store,
                      routing: musicAppRouting(), actions: actions2, status: status2, spanDACData: { true },
                      readers: r2.readers)
        actions2.waitUntilIdle()
        XCTAssertEqual(status2.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
        XCTAssertEqual(r2.reads, 0)
        XCTAssertEqual(counter.callCount, 0)
        XCTAssertNil(store.read())

        // Through the Playlists rail's `p`: the same refusal, before any read.
        let r3 = readers()
        let status3 = StatusStore()
        let actions3 = ActionRunner(status: status3)
        let marks3 = MarkedSetStore()
        marks3.toggle(.playlist(id: "pl1", name: "Chill"), source: .bridge)
        let s = playlistsScene(backend: counter.backend, store: store, status: status3, actions: actions3,
                               marks: marks3, readers: r3.readers)
        let before = counter.callCount
        XCTAssertEqual(s.handle(.char("p")), .push(.nowPlaying))
        actions3.waitUntilIdle()
        XCTAssertEqual(status3.current()?.text, LibraryProvenance.musicAppSelectedBridgeList)
        XCTAssertEqual(r3.reads, 0)
        XCTAssertEqual(counter.callCount, before, "the marked play ran no AppleScript")
        XCTAssertNil(store.read())
    }

    // MARK: - The first entry, confirmed by identity

    func testMarkedPlayConfirmsFirstEntryByIdentity() {
        let fake = HonestPlayingTests.FakeMusicInterpreter()
        let status = StatusStore()
        let rig = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "playing", persistentID: "00000000000000A1", requestedID: nil)],
            status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        let r = readers()
        let lib = libraryScene(backend: fake.backend, store: store, status: status, actions: actions, marks: marks,
                               readers: r.readers)
        let pls = playlistsScene(backend: fake.backend, store: store, status: status, actions: actions, marks: marks,
                                 readers: r.readers)
        XCTAssertEqual(lib.handle(.char("m")), .redraw)
        XCTAssertEqual(pls.handle(.char("m")), .redraw)
        XCTAssertEqual(lib.handle(.char("p")), .push(.nowPlaying), "p with marks plays the set, from either rail")
        actions.waitUntilIdle()
        rig.runJobs()
        let q = store.read()
        XCTAssertEqual(q?.playlistName, persistentIDQueueSource)
        XCTAssertEqual(q?.contextLabel, "1 album and 1 playlist")
        XCTAssertEqual(q?.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["00000000000000A1", "00000000000000A2", "00000000000000B1"], "mark order")
        XCTAssertEqual(rig.targets.first, .persistentID("00000000000000A1"))
        XCTAssertEqual(fake.playScripts.count, 1, fake.playScripts.joined(separator: "\n---\n"))
        XCTAssertTrue(fake.playScripts.first?.contains("persistent ID is \"00000000000000A1\"") ?? false)
        XCTAssertEqual(rig.posts, [], "Music confirmed the requested track")
        XCTAssertEqual(marks.count, 2, "a play leaves the marks; Esc clears them")

        // `s` from the Playlists rail: the same set, shuffled together, and
        // a warning naming the set when Music does not confirm.
        let paused = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "paused", persistentID: "0000000000000099", requestedID: nil)],
            status: status)
        store.confirmer = paused.confirmer
        XCTAssertEqual(pls.handle(.char("s")), .push(.nowPlaying))
        actions.waitUntilIdle()
        paused.runJobs()
        let shuffled = store.read()
        XCTAssertEqual(shuffled?.tracks.map(\.index).sorted(), q?.tracks.map(\.index).sorted())
        XCTAssertEqual(paused.targets.first, shuffled.map { RequestedTrack.persistentID(persistentIDOfQueueEntry($0.tracks[0].index)) })
        XCTAssertEqual(paused.posts, [playNotStartedWarning("1 album and 1 playlist")])
    }

    // MARK: - A partly available album keeps its skipped count

    private func partialReaders() -> CountingReaders {
        let r = readers()
        r.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                           entry("00000000000000A2", "Sexy Boy")], matched: 3)
        return r
    }

    private let partialNotice = "3 of 4 are queued \u{2014} the rest aren't available yet."
    private let partialLine = "Playing 3 of 4 \u{2014} the rest aren't available yet."

    func testAPartlyAvailableMarkedAlbumSaysSoThroughEitherRail() {
        // Confirmed at once, from the Playlists rail: the play posts the line.
        let fake = HonestPlayingTests.FakeMusicInterpreter()
        let status = StatusStore()
        let rig = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "playing", persistentID: "00000000000000A1", requestedID: nil)],
            status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        let r = partialReaders()
        let lib = libraryScene(backend: fake.backend, store: store, status: status, actions: actions, marks: marks,
                               readers: r.readers)
        let pls = playlistsScene(backend: fake.backend, store: store, status: status, actions: actions, marks: marks,
                                 readers: r.readers)
        _ = lib.handle(.char("m"))
        _ = pls.handle(.char("m"))
        XCTAssertEqual(pls.handle(.char("p")), .push(.nowPlaying))
        actions.waitUntilIdle()
        rig.runJobs()
        XCTAssertEqual(store.read()?.tracks.count, 3)
        XCTAssertEqual(rig.posts, [], "Music confirmed the requested track")
        XCTAssertEqual(status.current()?.text, partialLine, "the skipped song was dropped silently")

        // Not confirmed, from the Library rail: the warning carries the notice.
        let status2 = StatusStore()
        let paused = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "paused", persistentID: "0000000000000099", requestedID: nil)],
            status: status2)
        let store2 = AppQueueStore()
        store2.confirmer = paused.confirmer
        let actions2 = ActionRunner(status: status2)
        let marks2 = MarkedSetStore()
        let lib2 = libraryScene(backend: fake.backend, store: store2, status: status2, actions: actions2,
                                marks: marks2, readers: partialReaders().readers)
        let pls2 = playlistsScene(backend: fake.backend, store: store2, status: status2, actions: actions2,
                                  marks: marks2, readers: partialReaders().readers)
        _ = lib2.handle(.char("m"))
        _ = pls2.handle(.char("m"))
        XCTAssertEqual(lib2.handle(.char("p")), .push(.nowPlaying))
        actions2.waitUntilIdle()
        paused.runJobs()
        XCTAssertEqual(paused.posts, [playNotStartedWarning("1 album and 1 playlist") + " " + partialNotice],
                       "the warning erased the skipped count")
    }

    func testALateConfirmationRestoresTheMarkedSetsAvailabilityLine() {
        let fake = HonestPlayingTests.FakeMusicInterpreter()
        let status = StatusStore()
        let rig = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "paused", persistentID: "0000000000000099", requestedID: nil)],
            status: status)
        // Music starts the set late, after the warning showed.
        rig.onRead = { n in
            if n == 9 {
                rig.setReadings([PlayerIdentityReading(state: "playing", persistentID: "00000000000000A1",
                                                       requestedID: "00000000000000A1")])
            }
        }
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        marks.toggle(.album(title: "Moon Safari", artist: "Air"), source: .musicApp)
        marks.toggle(.playlist(id: Self.chillID, name: "Chill"), source: .musicApp)
        playMarkedSet(marks.snapshot, shuffle: false, backend: fake.backend, appQueue: store,
                      routing: musicAppRouting(), actions: actions, status: status, spanDACData: { false },
                      readers: partialReaders().readers)
        actions.waitUntilIdle()
        rig.runJobs()
        XCTAssertEqual(rig.posts.first, playNotStartedWarning("1 album and 1 playlist") + " " + partialNotice)
        XCTAssertEqual(status.current()?.text, partialLine,
                       "the late confirmation took the availability line away with the warning")
    }

    func testAFullyAvailableMarkedSetPostsNoAvailabilityLine() {
        let fake = HonestPlayingTests.FakeMusicInterpreter()
        let status = StatusStore()
        let rig = HonestPlayingTests.ConfirmRig(
            [PlayerIdentityReading(state: "paused", persistentID: "0000000000000099", requestedID: nil)],
            status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        marks.toggle(.album(title: "Moon Safari", artist: "Air"), source: .musicApp)
        playMarkedSet(marks.snapshot, shuffle: false, backend: fake.backend, appQueue: store,
                      routing: musicAppRouting(), actions: actions, status: status, spanDACData: { false },
                      readers: readers().readers)
        actions.waitUntilIdle()
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Moon Safari")], "no notice when nothing was skipped")
    }

    // MARK: - Nothing is ever written

    /// A fake `osascript` for the LIVE readers: answers each playlist's
    /// identity read by the persistent ID the script addresses (an ID it does
    /// not hold answers `playlistMissingReply`, as the real script does), the
    /// album's identity read and the play, and logs every script it is handed.
    /// The album read is matched first: its strict clause says `artist is`,
    /// and it too reads `persistent ID of every track of playlist "Library"`.
    private final class ReadOnlyMusic {
        let backend: AppleScriptBackend
        private let logPath: String
        private static let separator = "----8<----"

        init(playlistReplies: [String: String], albumReply: String) {
            let dir = FileManager.default.temporaryDirectory
            let id = UUID().uuidString
            logPath = dir.appendingPathComponent("marked-log-\(id).txt").path
            let albumPath = dir.appendingPathComponent("marked-album-\(id).txt").path
            try? albumReply.write(toFile: albumPath, atomically: true, encoding: .utf8)
            var byID = ""
            for (pid, reply) in playlistReplies {
                let path = dir.appendingPathComponent("marked-playlist-\(pid)-\(id).txt").path
                try? reply.write(toFile: path, atomically: true, encoding: .utf8)
                byID += "  *\"playlist whose persistent ID is \\\"\(pid)\\\"\"*) cat \"\(path)\" ;;\n"
            }
            let scriptPath = dir.appendingPathComponent("marked-fake-\(id).sh").path
            let script = """
                #!/bin/sh
                printf '%s\\n%s\\n' "$2" '\(Self.separator)' >> "\(logPath)"
                case "$2" in
                  *"play item"*) exit 0 ;;
                  *"artist is"*) cat "\(albumPath)" ;;
                \(byID)  *"playlist whose persistent ID is"*) printf '\(playlistMissingReply)\\n' ;;
                esac
                exit 0
                """
            try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            backend = AppleScriptBackend(executable: scriptPath)
        }

        var scripts: [String] {
            guard let raw = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return raw.components(separatedBy: "\n\(Self.separator)\n").filter { !$0.isEmpty }
        }
    }

    private func playlistReply(_ rows: [[String]]) -> String {
        "\(rows.count)\n" + rows.map { $0.joined(separator: fs) + "\n" }.joined()
    }

    private var albumReply: String {
        [["1", "La Femme d'Argent", "Air", "Air", "subscription", "1", "1", "Moon Safari",
          "00000000000000A1"].joined(separator: fs),
         ["2", "Sexy Boy", "Air", "Air", "subscription", "1", "2", "Moon Safari",
          "00000000000000A2"].joined(separator: fs)].joined(separator: "\n") + "\n"
    }

    func testNoPlaylistWriteScriptIsEverSent() {
        let chill = playlistReply([["00000000000000B1", "Teardrop", "Massive Attack", "Mezzanine"],
                                   ["00000000000000B2", "Angel", "Massive Attack", "Mezzanine"]])
        let music = ReadOnlyMusic(playlistReplies: [Self.chillID: chill], albumReply: albumReply)
        let status = StatusStore()
        let store = AppQueueStore()
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        // The LIVE readers (nil injects nothing): the scripts a real play sends.
        let lib = libraryScene(backend: music.backend, store: store, status: status, actions: actions, marks: marks,
                               readers: nil)
        let pls = playlistsScene(backend: music.backend, store: store, status: status, actions: actions, marks: marks,
                                 readers: nil)
        _ = lib.handle(.char("m"))
        _ = pls.handle(.char("m"))
        _ = pls.handle(.char("p"))
        actions.waitUntilIdle()
        _ = lib.handle(.char("s"))
        actions.waitUntilIdle()

        XCTAssertEqual(store.read()?.tracks.count, 4, "the set played: \(status.current()?.text ?? "")")
        let scripts = music.scripts
        XCTAssertTrue(scripts.contains { $0.contains("first playlist whose persistent ID is \"\(Self.chillID)\"") },
                      "the track read is addressed by the ID the mark captured")
        XCTAssertFalse(scripts.contains { $0.contains("whose name is") }, "no name check or name lookup ran")
        XCTAssertFalse(scripts.contains { $0.contains("of playlist \"Chill\"") }, "no read addressed by name")
        XCTAssertEqual(scripts.filter { $0.contains("play item") }.count, 2, "one play per keypress")
        for script in scripts {
            let lower = script.lowercased()
            for word in ["make new", "duplicate", "delete"] {
                XCTAssertFalse(lower.contains(word), "a write reached Music (\(word)):\n\(script)")
            }
        }
    }

    // MARK: - A marked playlist is read by the ID its mark captured

    /// "Chill" (F1) is marked from the rail, then renamed, and another
    /// playlist (F2) takes the name "Chill" before `p`. Through the LIVE
    /// readers, the play reads F1 by its ID and plays F1's tracks; nothing
    /// addresses F2 or the name.
    func testARenamedMarkedPlaylistPlaysTheOriginalNeverTheOneThatTookItsName() {
        let otherID = "00000000000000F2"
        let original = playlistReply([["00000000000000B1", "Teardrop", "Massive Attack", "Mezzanine"]])
        let namesake = playlistReply([["00000000000000D1", "Not This", "Someone", "Else"]])
        let music = ReadOnlyMusic(playlistReplies: [Self.chillID: original, otherID: namesake],
                                  albumReply: albumReply)
        let status = StatusStore()
        let store = AppQueueStore()
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        let pls = playlistsScene(backend: music.backend, store: store, status: status, actions: actions, marks: marks,
                                 readers: nil)
        _ = pls.handle(.char("m"))
        XCTAssertEqual(marks.items, [.playlist(id: Self.chillID, name: "Chill")])
        _ = pls.handle(.char("p"))
        actions.waitUntilIdle()

        XCTAssertEqual(store.read()?.tracks.map { persistentIDOfQueueEntry($0.index) }, ["00000000000000B1"],
                       "the original played: \(status.current()?.text ?? "")")
        let scripts = music.scripts
        XCTAssertFalse(scripts.contains { $0.contains(otherID) }, "the playlist that took the name was read")
        XCTAssertFalse(scripts.contains { $0.contains("whose name is") }, "the name was looked up again")
        XCTAssertEqual(scripts.filter { $0.contains("whose persistent ID is \"\(Self.chillID)\"") }.count, 1)
    }

    /// The marked ID is gone at play time: the play refuses with the message
    /// naming it, reads no other playlist, plays nothing and sets no queue.
    func testAMarkedPlaylistGoneAtPlayTimeRefusesAndPlaysNothing() {
        let otherID = "00000000000000F2"
        let namesake = playlistReply([["00000000000000D1", "Not This", "Someone", "Else"]])
        let music = ReadOnlyMusic(playlistReplies: [otherID: namesake], albumReply: albumReply)
        let status = StatusStore()
        let store = AppQueueStore()
        let actions = ActionRunner(status: status)
        let marks = MarkedSetStore()
        let pls = playlistsScene(backend: music.backend, store: store, status: status, actions: actions, marks: marks,
                                 readers: nil)
        _ = pls.handle(.char("m"))
        _ = pls.handle(.char("p"))
        actions.waitUntilIdle()

        XCTAssertEqual(status.current()?.text, "'Chill' is no longer in your playlists, so nothing played.")
        XCTAssertNil(store.read(), "a queue was set")
        let scripts = music.scripts
        XCTAssertEqual(scripts.filter { $0.contains("play item") }.count, 0, "something played")
        XCTAssertFalse(scripts.contains { $0.contains(otherID) }, "another playlist was read in its place")
        XCTAssertFalse(scripts.contains { $0.contains("whose name is") })
    }
}
