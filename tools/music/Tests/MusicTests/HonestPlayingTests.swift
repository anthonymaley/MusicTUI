// tools/music/Tests/MusicTests/HonestPlayingTests.swift
import XCTest
@testable import music

/// Honest "Playing" (2026-11-01): a person-started queue play whose script
/// exits cleanly is confirmed by reading Music's player state and the current
/// track's persistent ID; a play Music accepted but did not start says so,
/// keeps its queue, and holds the poller's auto-advance.
///
/// Every confirmation here runs on `ConfirmRig`: a fake clock that the
/// injected sleep advances, a scheduler the test drains by hand, and scripted
/// readings. No fixed sleeps. Every AppleScript goes to `FakeMusicInterpreter`
/// (a temp shell script), never osascript: nothing reaches a player, the
/// socket, the keychain or ~/.config/music.
final class HonestPlayingTests: XCTestCase {

    private let old = "00000000000000A1"
    private let new = "00000000000000B2"

    // MARK: - The rig

    /// A deterministic confirmer: readings in order (the last repeats), a fake
    /// clock, jobs run only when the test says so.
    final class ConfirmRig {
        private let lock = NSLock()
        private var clockValue = Date(timeIntervalSince1970: 1_000)
        private var jobs: [() -> Void] = []
        private var postsValue: [String] = []
        private var readingsValue: [PlayerIdentityReading?]
        private var readCount = 0
        var fenceValue = PlayConfirmFence.still
        /// Called with the 1-based read number, before the reading is returned.
        var onRead: ((Int) -> Void)?
        private(set) var confirmer: PlayConfirmer!
        let started: Date

        init(_ readings: [PlayerIdentityReading?], status: StatusStore? = nil) {
            readingsValue = readings
            started = clockValue
            confirmer = PlayConfirmer(
                read: { [unowned self] in self.nextReading() },
                post: { [unowned self] text in
                    self.lock.lock(); self.postsValue.append(text); self.lock.unlock()
                    status?.post(text, error: true, untilStateChange: true)
                },
                fence: { [unowned self] in self.fenceValue },
                timing: PlayConfirmer.Timing(interval: 0.25, window: 1.5),
                now: { [unowned self] in self.lock.lock(); defer { self.lock.unlock() }; return self.clockValue },
                sleep: { [unowned self] d in self.lock.lock(); self.clockValue += d; self.lock.unlock() },
                schedule: { [unowned self] job in self.lock.lock(); self.jobs.append(job); self.lock.unlock() })
        }

        var posts: [String] { lock.lock(); defer { lock.unlock() }; return postsValue }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
        var pendingJobs: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
        var elapsed: TimeInterval { lock.lock(); defer { lock.unlock() }; return clockValue.timeIntervalSince(started) }
        func setReadings(_ r: [PlayerIdentityReading?]) { lock.lock(); readingsValue = r; lock.unlock() }

        private func nextReading() -> PlayerIdentityReading? {
            lock.lock()
            readCount += 1
            let n = readCount
            let r = readingsValue.isEmpty ? nil : (readingsValue.count > 1 ? readingsValue.removeFirst() : readingsValue[0])
            lock.unlock()
            onRead?(n)
            return r
        }

        /// Runs every scheduled job, including ones scheduled while running.
        func runJobs() {
            while true {
                lock.lock()
                guard !jobs.isEmpty else { lock.unlock(); return }
                let job = jobs.removeFirst()
                lock.unlock()
                job()
            }
        }
    }

    private func reading(_ state: String, _ pid: String?) -> PlayerIdentityReading {
        PlayerIdentityReading(state: state, persistentID: pid)
    }

    /// A fake `osascript`: logs every script, answers the poll from a file,
    /// and answers play scripts (`play track`, `play item`) with a reply file,
    /// or fails them while the fail flag exists.
    final class FakeMusicInterpreter {
        let backend: AppleScriptBackend
        private let logPath: String
        private let pollPath: String
        private let replyPath: String
        private let failPath: String
        private static let separator = "----8<----"

        init() {
            let dir = FileManager.default.temporaryDirectory
            let id = UUID().uuidString
            logPath = dir.appendingPathComponent("honest-playing-log-\(id).txt").path
            pollPath = dir.appendingPathComponent("honest-playing-poll-\(id).txt").path
            replyPath = dir.appendingPathComponent("honest-playing-reply-\(id).txt").path
            failPath = dir.appendingPathComponent("honest-playing-fail-\(id)").path
            let scriptPath = dir.appendingPathComponent("honest-playing-fake-\(id).sh").path
            let script = """
                #!/bin/sh
                printf '%s\\n%s\\n' "$2" '\(Self.separator)' >> "\(logPath)"
                case "$2" in
                  *"player position"*) [ -f "\(pollPath)" ] && cat "\(pollPath)" ;;
                  *"play track"*|*"play item"*)
                    if [ -f "\(failPath)" ]; then echo "Music got an error." >&2; exit 1; fi
                    [ -f "\(replyPath)" ] && cat "\(replyPath)" ;;
                esac
                exit 0
                """
            try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            backend = AppleScriptBackend(executable: scriptPath)
        }

        func poll(_ text: String) { try? text.write(toFile: pollPath, atomically: true, encoding: .utf8) }
        func reply(_ text: String) { try? text.write(toFile: replyPath, atomically: true, encoding: .utf8) }
        func failPlays(_ fail: Bool) {
            if fail { FileManager.default.createFile(atPath: failPath, contents: Data()) }
            else { try? FileManager.default.removeItem(atPath: failPath) }
        }
        var scripts: [String] {
            guard let raw = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return raw.components(separatedBy: "\n\(Self.separator)\n").filter { !$0.isEmpty }
        }
        var playScripts: [String] { scripts.filter { $0.contains("play track") || $0.contains("play item") } }
    }

    private func queue(_ count: Int, at index: Int, playlist: String = "Mix") -> AppQueue {
        AppQueue(playlistName: playlist,
                 tracks: (1...count).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) },
                 currentIndex: index)
    }

    // MARK: - The wording and the read

    func testTheWarningWordingIsTheAgreedSentence() {
        XCTAssertEqual(playNotStartedWarning("Moon Safari"),
                       "Play was requested, but Music hasn't started 'Moon Safari' yet. If nothing plays, quitting and reopening Music fixed this before.")
    }

    func testTheConfirmationReadParsesStateAndIdentity() {
        let fs = String(asFieldSep)
        XCTAssertEqual(parsePlayerIdentityReading("playing\(fs)\(new)\n"), reading("playing", new))
        XCTAssertEqual(parsePlayerIdentityReading("paused\(fs)\n"), reading("paused", nil),
                       "no current track: the state still answers")
        XCTAssertNil(parsePlayerIdentityReading(""), "an empty answer is unreadable")
        XCTAssertNil(parsePlayerIdentityReading("garbage"), "an answer without the separator is unreadable")
    }

    func testTheConfirmationReadAsksStateAndIdentityInOneScriptThatSurvivesNoCurrentTrack() {
        XCTAssertTrue(playerIdentityReadScript.contains("player state as text"))
        XCTAssertTrue(playerIdentityReadScript.contains("persistent ID of current track"))
        XCTAssertTrue(playerIdentityReadScript.contains("try"), "the identity read is wrapped")
    }

    // MARK: - The confirmation window

    func testMusicStillPlayingThePreviousTrackPostsTheWarning() {
        let rig = ConfirmRig([reading("playing", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")])
        XCTAssertGreaterThan(rig.reads, 1, "a few reads, not one")
        XCTAssertLessThanOrEqual(rig.elapsed, 1.5 + 1e-6, "the window is about 1.5 s")
    }

    func testMusicStillPausedPostsTheWarning() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")])

        // Paused on the requested track is still not playing.
        let onIt = ConfirmRig([reading("paused", new)])
        let t2 = onIt.confirmer.request()
        onIt.confirmer.confirm(t2, expected: new, title: "Song")
        onIt.runJobs()
        XCTAssertEqual(onIt.posts, [playNotStartedWarning("Song")])
    }

    func testASlowStartConfirmedOnALaterReadPostsNothing() {
        let rig = ConfirmRig([reading("paused", old), reading("stopped", nil), reading("playing", new)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertEqual(rig.reads, 3, "stops reading once confirmed")
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance, "a confirmed play holds nothing")
    }

    func testAnUnreadablePlayerPostsTheWarningWithoutCrashing() {
        let rig = ConfirmRig([nil])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")])

        // A play whose own identity could not be read cannot be confirmed either.
        let blind = ConfirmRig([reading("playing", new)])
        let t2 = blind.confirmer.request()
        blind.confirmer.confirm(t2, expected: nil, title: "Song")
        blind.runJobs()
        XCTAssertEqual(blind.posts, [playNotStartedWarning("Song")])
    }

    func testAConfirmedPlayPostsNothingAfterOneRead() {
        let rig = ConfirmRig([reading("playing", new.lowercased())])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        XCTAssertEqual(rig.reads, 0, "confirm returns before reading: the reads never sit on the caller")
        XCTAssertEqual(rig.pendingJobs, 1)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertEqual(rig.reads, 1)
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance)
    }

    func testASecondPlayBeforeTheFirstConfirmsLeavesNoStaleWarning() {
        // Both requested before either window ran; Music starts the second.
        let rig = ConfirmRig([reading("playing", new)])
        let first = rig.confirmer.request()
        rig.confirmer.confirm(first, expected: old, title: "First")
        let second = rig.confirmer.request()
        rig.confirmer.confirm(second, expected: new, title: "Second")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [], "the first request's late result is dropped")

        // The second arrives mid-way through the first's window, and Music
        // starts neither: only the second may speak.
        let stuck = ConfirmRig([reading("paused", "00000000000000C3")])
        let a = stuck.confirmer.request()
        stuck.onRead = { n in
            if n == 2 {
                let b = stuck.confirmer.request()
                stuck.confirmer.confirm(b, expected: self.new, title: "Second")
            }
        }
        stuck.confirmer.confirm(a, expected: old, title: "First")
        stuck.runJobs()
        XCTAssertEqual(stuck.posts, [playNotStartedWarning("Second")])
    }

    func testAPauseOrSkipSinceTheRequestDropsItsResult() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.confirmer.invalidate()
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance, "a superseded request holds nothing")
    }

    func testAnOutputOrSourceSwitchSinceTheRequestDropsItsResult() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.fenceValue = PlayConfirmFence(epoch: 1, dataEpoch: 0, playSerial: 0)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance)

        // Another admitted play (the routing play serial) drops it too.
        let played = ConfirmRig([reading("paused", old)])
        let t2 = played.confirmer.request()
        played.confirmer.confirm(t2, expected: new, title: "Song")
        played.fenceValue = PlayConfirmFence(epoch: 0, dataEpoch: 0, playSerial: 1)
        played.runJobs()
        XCTAssertEqual(played.posts, [])
    }

    func testTheHoldLastsUntilTheRequestedTrackIsSeen() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance, "held from the request, before the script returns")
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance, "an unconfirmed play keeps holding")
        rig.confirmer.observe(currentPersistentID: old)
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance, "the previous track releases nothing")
        rig.confirmer.observe(currentPersistentID: nil)
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance)
        rig.confirmer.observe(currentPersistentID: new)
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance, "seen: the hold goes")
    }

    func testAnAbandonedRequestHoldsNothingAndLeavesANewerOneHeld() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.abandon(t)
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance)

        let a = rig.confirmer.request()
        _ = rig.confirmer.request()
        rig.confirmer.abandon(a)
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance, "a stale abandon releases nothing newer")
    }

    // MARK: - The action queue supersedes

    func testAPauseOnTheActionQueueSupersedesAPendingConfirmation() {
        let rig = ConfirmRig([reading("paused", old)])
        let status = StatusStore()
        let actions = ActionRunner(status: status, onSuperseding: { rig.confirmer.invalidate() })
        actions.run("Play") {
            let t = rig.confirmer.request()
            rig.confirmer.confirm(t, expected: self.new, title: "Song")
        }
        actions.run("Pause") {}
        actions.waitUntilIdle()
        rig.runJobs()
        XCTAssertEqual(rig.posts, [], "the pause came after the play: its result is dropped")

        // Space, Skip and Back supersede the same way; a volume change does not.
        for label in ["Play/pause", "Skip", "Back"] {
            let r = ConfirmRig([reading("paused", old)])
            let a = ActionRunner(status: StatusStore(), onSuperseding: { r.confirmer.invalidate() })
            a.run("Play") { let t = r.confirmer.request(); r.confirmer.confirm(t, expected: self.new, title: "Song") }
            a.run(label) {}
            a.waitUntilIdle()
            r.runJobs()
            XCTAssertEqual(r.posts, [], "\(label) did not supersede")
        }
        let v = ConfirmRig([reading("paused", old)])
        let av = ActionRunner(status: StatusStore(), onSuperseding: { v.confirmer.invalidate() })
        av.run("Play") { let t = v.confirmer.request(); v.confirmer.confirm(t, expected: self.new, title: "Song") }
        av.run("Volume") {}
        av.waitUntilIdle()
        v.runJobs()
        XCTAssertEqual(v.posts, [playNotStartedWarning("Song")], "a volume change is not a new request")
    }

    // MARK: - The play itself

    func testAPositionPlayReadsTheRequestedIdentityInTheSamePlayScript() {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let rig = ConfirmRig([reading("playing", new)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: "Mix",
                                              position: 3, title: "T3"))
        XCTAssertEqual(fake.playScripts.count, 1, "one script plays and identifies")
        let script = fake.playScripts.first ?? ""
        XCTAssertTrue(script.contains("play track 3 of playlist \"Mix\""))
        XCTAssertTrue(script.contains("persistent ID of track 3 of playlist \"Mix\""),
                      "the expected identity comes from the play script itself")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])

        // The same play, with Music on another track: the warning.
        let fake2 = FakeMusicInterpreter()
        fake2.reply(new + "\n")
        let stuck = ConfirmRig([reading("playing", old)])
        let store2 = AppQueueStore()
        store2.confirmer = stuck.confirmer
        store2.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: fake2.backend, appQueue: store2, playlist: "Mix",
                                              position: 3, title: "T3"))
        stuck.runJobs()
        XCTAssertEqual(stuck.posts, [playNotStartedWarning("T3")])
        XCTAssertEqual(store2.read()?.currentIndex, 3, "the queue is kept")
    }

    func testAPersistentIDPlayExpectsItsOwnEntryIdentity() {
        let fake = FakeMusicInterpreter()
        let entry = persistentIDQueueEntry(persistentID: new, name: "Song", artist: "A", album: nil)!
        let rig = ConfirmRig([reading("playing", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        XCTAssertTrue(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: persistentIDQueueSource,
                                              position: entry.index, title: "Song"))
        XCTAssertTrue(fake.playScripts.first?.contains("persistent ID is \"\(new)\"") ?? false)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")], "another track is playing")

        let ok = ConfirmRig([reading("playing", new)])
        let store2 = AppQueueStore()
        store2.confirmer = ok.confirmer
        XCTAssertTrue(playRequestedQueueTrack(backend: FakeMusicInterpreter().backend, appQueue: store2,
                                              playlist: persistentIDQueueSource, position: entry.index, title: "Song"))
        ok.runJobs()
        XCTAssertEqual(ok.posts, [])
    }

    func testAPlayScriptErrorKeepsTodaysBehaviourAndReadsNothing() {
        let fake = FakeMusicInterpreter()
        fake.failPlays(true)
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        XCTAssertFalse(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: "Mix",
                                               position: 2, title: "T2"))
        rig.runJobs()
        XCTAssertEqual(rig.reads, 0)
        XCTAssertEqual(rig.posts, [])
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance, "an errored play holds nothing")
    }

    // MARK: - Global next and previous

    func testANextMusicDoesNotStartWarnsByTrackNameAndKeepsTheStep() throws {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(3, at: 1))
        try musicTUISkip(1, backend: fake.backend, appQueue: store)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("T2")])
        XCTAssertEqual(store.read()?.currentIndex, 2, "no rollback for a play Music accepted")
    }

    func testANextWhoseScriptErrorsStillRollsBackAndSaysSo() {
        let fake = FakeMusicInterpreter()
        fake.failPlays(true)
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(3, at: 1))
        XCTAssertThrowsError(try musicTUISkip(1, backend: fake.backend, appQueue: store)) { error in
            XCTAssertEqual((error as? ActionError)?.message, "Couldn't play that track.")
        }
        XCTAssertEqual(store.read()?.currentIndex, 1, "rolled back, as today")
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertEqual(rig.reads, 0)
    }

    func testAConfirmedNextChangesNothing() throws {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let rig = ConfirmRig([reading("playing", new)])
        let status = StatusStore()
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(3, at: 1))
        try musicTUISkip(1, backend: fake.backend, appQueue: store)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
        XCTAssertNil(status.current(), "nothing posted")
    }

    // MARK: - The SpanDAC library hand-off

    private func handoffQueue() -> AppQueue {
        let entry = persistentIDQueueEntry(persistentID: new, name: "La Femme d'Argent", artist: "Air", album: "Moon Safari")!
        return AppQueue(playlistName: persistentIDQueueSource, tracks: [entry], currentIndex: 1, displayName: "Moon Safari")
    }

    func testAHandoffMusicDoesNotStartReplacesThePlayingLineAndKeepsTheQueue() throws {
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let player = AppQueueHandoffPlayer(store: store,
                                           playFirst: requestedHandoffPlayFirst(backend: FakeMusicInterpreter().backend,
                                                                                appQueue: store))
        XCTAssertNoThrow(try player.play(handoffQueue()), "unconfirmed is not a failed play")
        // The scene posts its line once the hand-off returns, as today.
        status.post(LibraryProvenance.playingOnMusicTUI("Moon Safari"))
        rig.runJobs()
        XCTAssertEqual(status.current()?.text, playNotStartedWarning("Moon Safari"))
        XCTAssertEqual(status.current()?.isError, true)
        XCTAssertNotNil(store.read(), "the queue is kept, never cleared")
    }

    func testAConfirmedHandoffKeepsTodaysPlayingLine() throws {
        let status = StatusStore()
        let rig = ConfirmRig([reading("playing", new)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let player = AppQueueHandoffPlayer(store: store,
                                           playFirst: requestedHandoffPlayFirst(backend: FakeMusicInterpreter().backend,
                                                                                appQueue: store))
        try player.play(handoffQueue())
        status.post(LibraryProvenance.playingOnMusicTUI("Moon Safari"))
        rig.runJobs()
        XCTAssertEqual(status.current()?.text, "Playing 'Moon Safari' on MusicTUI.")
        XCTAssertEqual(rig.reads, 1)
    }

    func testAHandoffWhosePlayScriptErrorsStillClearsAndRefusesAsToday() {
        let fake = FakeMusicInterpreter()
        fake.failPlays(true)
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let player = AppQueueHandoffPlayer(store: store,
                                           playFirst: requestedHandoffPlayFirst(backend: fake.backend, appQueue: store))
        XCTAssertThrowsError(try player.play(handoffQueue())) { error in
            XCTAssertEqual((error as? ActionError)?.message, "Couldn't play 'Moon Safari'.")
        }
        XCTAssertNil(store.read())
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])
    }

    // MARK: - A Library album play (scene)

    func testALibraryAlbumPlayMusicDoesNotStartWarnsByTheAlbumTitle() {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.musicApp)
        let routing = RoutingCoordinator(store: modeStore, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) })
        let sources = LibraryDataSources(onAlbums: { _ in true }, onSongs: { _ in true }, onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        let actions = ActionRunner(status: status)
        let tracks = (1...3).map { TrackListEntry(index: 40 + $0, name: "T\($0)", artist: "Air", isCurrent: false) }
        let scene = LibraryScene(backend: fake.backend, routing: routing, sources: sources, appQueue: store,
                                 status: status, actions: actions,
                                 resolveAlbum: { _, _, _ in AlbumResolution(tracks: tracks, matched: 3) },
                                 resultCache: temporaryResultCache().cache)
        scene.playAlbum(title: "Moon Safari", artist: "Air", shuffle: false)
        actions.waitUntilIdle()
        XCTAssertTrue(fake.playScripts.first?.contains("persistent ID of track 41 of playlist \"Library\"") ?? false)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Moon Safari")])
        XCTAssertEqual(store.read()?.currentIndex, 1, "the queue is kept")
    }

    // MARK: - The poller holds auto-advance

    private func pollLine(_ track: String, duration: Int, position: Int, state: String) -> String {
        let fs = String(asFieldSep)
        return [track, "A", "Album", String(duration), String(position), state].joined(separator: fs) + "\n"
    }

    private func poller(_ fake: FakeMusicInterpreter, _ store: AppQueueStore) -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: fake.backend, appQueue: store,
                       queueStore: QueueStore(path: NSTemporaryDirectory() + "honest-q-\(UUID().uuidString).json"))
    }

    func testThePreviousTrackEndingWhileAPlayIsUnconfirmedDoesNotAdvanceTheNewQueue() {
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let p = poller(fake, store)
        // The old track, near its end.
        fake.poll(pollLine("Old", duration: 200, position: 198, state: "playing"))
        p.tick()
        // The person plays track 1 of a new queue; Music accepts and stays put.
        store.set(queue(3, at: 1))
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "T1")
        // The old track runs out.
        fake.poll("STOPPED\n")
        p.tick()
        p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 1, "the new queue was advanced off the old track's end")
        XCTAssertEqual(fake.playScripts, [], "the poller played something while the play was unconfirmed")
        XCTAssertNotNil(store.read(), "the queue is kept")
    }

    func testOnceTheRequestedTrackIsSeenTheQueueAdvancesAsBefore() {
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("playing", new)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let p = poller(fake, store)
        store.set(queue(3, at: 1))
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "T1")
        rig.runJobs()   // confirmed
        fake.poll(pollLine("T1", duration: 200, position: 198, state: "playing"))
        p.tick()
        fake.poll("STOPPED\n")
        p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 2, "a confirmed play advances at its natural end, as today")
        XCTAssertEqual(fake.playScripts.count, 1)
    }

    func testThePollerReleasesTheHoldWhenItSeesTheRequestedTrack() {
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let p = poller(fake, store)
        store.set(queue(3, at: 1))
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "T1")
        rig.runJobs()   // unconfirmed in the window
        XCTAssertTrue(rig.confirmer.holdsAutoAdvance)
        // Music starts the requested track late; the poller looks while holding.
        rig.setReadings([reading("playing", new)])
        fake.poll(pollLine("T1", duration: 200, position: 3, state: "playing"))
        p.tick()
        XCTAssertFalse(rig.confirmer.holdsAutoAdvance, "the poller saw the requested track")
        // And now its natural end advances, as today.
        fake.poll(pollLine("T1", duration: 200, position: 198, state: "playing"))
        p.tick()
        fake.poll("STOPPED\n")
        p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 2)
    }

    func testThePollerReadsNothingExtraWhenNothingIsHeld() {
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("playing", new)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let p = poller(fake, store)
        fake.poll(pollLine("T1", duration: 200, position: 3, state: "playing"))
        p.tick()
        p.tick()
        XCTAssertEqual(rig.reads, 0, "no confirmation read without a request")
    }
}
