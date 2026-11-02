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
        /// Clock time, from the start, of the first warning posted.
        private(set) var postedAfter: TimeInterval?
        /// Called with the 1-based read number, before the reading is returned.
        var onRead: ((Int) -> Void)?
        private(set) var confirmer: PlayConfirmer!
        let started: Date

        init(_ readings: [PlayerIdentityReading?], status: StatusStore? = nil) {
            readingsValue = readings
            started = clockValue
            confirmer = PlayConfirmer(
                read: { [unowned self] target in self.nextReading(target) },
                post: { [unowned self] text -> Int? in
                    self.lock.lock()
                    self.postsValue.append(text)
                    if self.postedAfter == nil { self.postedAfter = self.clockValue.timeIntervalSince(self.started) }
                    self.lock.unlock()
                    return status?.post(text, error: true, untilStateChange: true)
                },
                withdraw: { status?.withdraw($0, replacingWith: $1) },
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

        /// The track each read was asked for.
        var targets: [RequestedTrack] { lock.lock(); defer { lock.unlock() }; return targetsValue }
        private var targetsValue: [RequestedTrack] = []

        private func nextReading(_ target: RequestedTrack) -> PlayerIdentityReading? {
            lock.lock()
            targetsValue.append(target)
            readCount += 1
            let n = readCount
            let r = readingsValue.isEmpty ? nil : (readingsValue.count > 1 ? readingsValue.removeFirst() : readingsValue[0])
            lock.unlock()
            onRead?(n)
            return r
        }

        /// Runs the oldest scheduled job only.
        func runNextJob() {
            lock.lock()
            guard !jobs.isEmpty else { lock.unlock(); return }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
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

    /// `requested`: the requested track's identity, as a position play's
    /// confirmation read reports it.
    private func reading(_ state: String, _ pid: String?, requested: String? = nil) -> PlayerIdentityReading {
        PlayerIdentityReading(state: state, persistentID: pid, requestedID: requested)
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
        private let killPath: String
        private static let separator = "----8<----"

        init() {
            let dir = FileManager.default.temporaryDirectory
            let id = UUID().uuidString
            logPath = dir.appendingPathComponent("honest-playing-log-\(id).txt").path
            pollPath = dir.appendingPathComponent("honest-playing-poll-\(id).txt").path
            replyPath = dir.appendingPathComponent("honest-playing-reply-\(id).txt").path
            failPath = dir.appendingPathComponent("honest-playing-fail-\(id)").path
            killPath = dir.appendingPathComponent("honest-playing-kill-\(id)").path
            let scriptPath = dir.appendingPathComponent("honest-playing-fake-\(id).sh").path
            let script = """
                #!/bin/sh
                printf '%s\\n%s\\n' "$2" '\(Self.separator)' >> "\(logPath)"
                case "$2" in
                  *"player position"*) [ -f "\(pollPath)" ] && cat "\(pollPath)" ;;
                  *"persistent ID of track"*)
                    # A play whose identity phase the watchdog killed: the play
                    # ran (it is logged above), then the script ended in error.
                    if [ -f "\(failPath)" ]; then echo "Music got an error." >&2; exit 1; fi
                    if [ -f "\(killPath)" ]; then echo "killed by the watchdog" >&2; exit 1; fi
                    [ -f "\(replyPath)" ] && cat "\(replyPath)" ;;
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
        /// Any script carrying an identity read after its play ends in error,
        /// as when the backend's watchdog kills osascript mid-read.
        func killIdentityPhase() { FileManager.default.createFile(atPath: killPath, contents: Data()) }
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
        // Codex r1, UX: the evidence supports "could not confirm", not "hasn't started".
        XCTAssertEqual(playNotStartedWarning("Moon Safari"),
                       "Play was requested, but Music didn't confirm 'Moon Safari' started. If nothing plays, quitting and reopening Music fixed this before.")
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
        XCTAssertLessThanOrEqual(rig.postedAfter ?? 99, 1.5 + 1e-6, "the warning posts when the 1.5 s window closes")
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
        XCTAssertNil(rig.confirmer.currentTicket(), "confirmed: nothing left to confirm")
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
        XCTAssertNil(rig.confirmer.currentTicket())
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
        XCTAssertNil(rig.confirmer.currentTicket(), "a superseded request has nothing to confirm")
    }

    func testAnOutputOrSourceSwitchSinceTheRequestDropsItsResult() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.fenceValue = PlayConfirmFence(epoch: 1, dataEpoch: 0, playSerial: 0)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [])

        // Another admitted play (the routing play serial) drops it too.
        let played = ConfirmRig([reading("paused", old)])
        let t2 = played.confirmer.request()
        played.confirmer.confirm(t2, expected: new, title: "Song")
        played.fenceValue = PlayConfirmFence(epoch: 0, dataEpoch: 0, playSerial: 1)
        played.runJobs()
        XCTAssertEqual(played.posts, [])
    }

    func testOnlyAPlayingReadingOfTheRequestedTrackConfirmsLate() {
        // After the window: the previous track, an unreadable read and the
        // requested track paused confirm nothing; the requested track playing
        // does, and the late reads stop there.
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.onRead = { n in
            guard rig.posts.count == 1 else { return }
            switch n {
            case 8: rig.setReadings([self.reading("playing", self.old)])
            case 9: rig.setReadings([nil])
            case 10: rig.setReadings([self.reading("paused", self.new)])
            case 11: rig.setReadings([self.reading("playing", self.new)])
            default: break
            }
        }
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertNil(rig.confirmer.currentTicket(), "the late playing read confirmed it")
        XCTAssertEqual(rig.reads, 12, "seven in the window, five late, then no more")
    }

    func testLateReadsAreBoundedAndStopWhenSuperseded() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.reads, 7 + 15, "15 late reads at most, every 2 s for 30 s")
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")])

        let stopped = ConfirmRig([reading("paused", old)])
        let t2 = stopped.confirmer.request()
        stopped.onRead = { n in if n == 9 { stopped.confirmer.invalidate() } }
        stopped.confirmer.confirm(t2, expected: new, title: "Song")
        stopped.runJobs()
        XCTAssertEqual(stopped.reads, 9, "a superseded request reads no more")
    }

    func testAnAbandonedRequestHasNothingToConfirmAndLeavesANewerOne() {
        let rig = ConfirmRig([reading("paused", old)])
        let t = rig.confirmer.request()
        rig.confirmer.abandon(t)
        XCTAssertNil(rig.confirmer.currentTicket())

        let a = rig.confirmer.request()
        let b = rig.confirmer.request()
        rig.confirmer.abandon(a)
        XCTAssertEqual(rig.confirmer.currentTicket(), b, "a stale abandon drops nothing newer")
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

    func testAPositionPlayIsConfirmedByReadingTheRequestedTrackOffTheCallersThread() {
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("playing", new, requested: new)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: "Mix",
                                              position: 3, title: "T3"))
        XCTAssertEqual(fake.playScripts.count, 1)
        XCTAssertFalse(fake.playScripts.first?.contains("persistent ID") ?? true, "the play reads no identity")
        XCTAssertEqual(rig.reads, 0, "nothing is read on the caller's thread")
        rig.runJobs()
        XCTAssertEqual(rig.targets, [.position(playlist: "Mix", index: 3)],
                       "the confirmation read asks for the requested track itself")
        XCTAssertEqual(rig.posts, [])

        // Music on another track: the warning.
        let stuck = ConfirmRig([reading("playing", old, requested: new)])
        let store2 = AppQueueStore()
        store2.confirmer = stuck.confirmer
        store2.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: FakeMusicInterpreter().backend, appQueue: store2,
                                              playlist: "Mix", position: 3, title: "T3"))
        stuck.runJobs()
        XCTAssertEqual(stuck.posts, [playNotStartedWarning("T3")])
        XCTAssertEqual(store2.read()?.currentIndex, 3, "the queue is kept")

        // The requested track's identity unreadable: not confirmed, never a crash.
        let blind = ConfirmRig([reading("playing", new, requested: nil)])
        let store3 = AppQueueStore()
        store3.confirmer = blind.confirmer
        store3.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: FakeMusicInterpreter().backend, appQueue: store3,
                                              playlist: "Mix", position: 3, title: "T3"))
        blind.runJobs()
        XCTAssertEqual(blind.posts, [playNotStartedWarning("T3")])
    }

    func testThePositionConfirmationReadAsksForTheRequestedTrackWrapped() {
        let script = playerIdentityReadScript(for: .position(playlist: "Say \"Hi\"", index: 7))
        XCTAssertTrue(script.contains("persistent ID of track 7 of playlist \"Say \\\"Hi\\\"\""), script)
        XCTAssertTrue(script.contains("player state as text"))
        XCTAssertEqual(playerIdentityReadScript(for: .persistentID(new)), playerIdentityReadScript)
        let fs = String(asFieldSep)
        XCTAssertEqual(parsePlayerIdentityReading("playing\(fs)\(old)\(fs)\(new)\n"),
                       reading("playing", old, requested: new))
        XCTAssertEqual(parsePlayerIdentityReading("paused\(fs)\(fs)\n"), reading("paused", nil, requested: nil))
    }

    func testAPersistentIDPlayExpectsItsOwnEntryIdentity() {
        let fake = FakeMusicInterpreter()
        let entry = persistentIDQueueEntry(persistentID: new, name: "Song", artist: "A", album: nil)!
        let rig = ConfirmRig([reading("playing", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(AppQueue(playlistName: persistentIDQueueSource, tracks: [entry], currentIndex: 1))
        XCTAssertTrue(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: persistentIDQueueSource,
                                              position: entry.index, title: "Song"))
        XCTAssertTrue(fake.playScripts.first?.contains("persistent ID is \"\(new)\"") ?? false)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")], "another track is playing")

        let ok = ConfirmRig([reading("playing", new)])
        let store2 = AppQueueStore()
        store2.confirmer = ok.confirmer
        store2.set(AppQueue(playlistName: persistentIDQueueSource, tracks: [entry], currentIndex: 1))
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
        store.set(queue(3, at: 2))
        XCTAssertFalse(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: "Mix",
                                               position: 2, title: "T2"))
        rig.runJobs()
        XCTAssertEqual(rig.reads, 0)
        XCTAssertEqual(rig.posts, [])
        XCTAssertNil(rig.confirmer.currentTicket(), "an errored play has nothing to confirm")
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
        let rig = ConfirmRig([reading("playing", new, requested: new)])
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

    /// A hand-off that skipped a song as unavailable, through the real
    /// `PersistentIDHandoff` and the shell's player: the first song (alias
    /// 178, the requested `new`) plays, the second has no identity.
    private func skippingHandoff(_ store: AppQueueStore) -> PersistentIDHandoff {
        XCTAssertEqual(persistentIDHex(fromAlias: "178"), new)
        let library = FakePersistentIDLibrary([new: [HandoffTrackHit(persistentID: new, inLibrary: true,
                                                                     databaseID: "501", libraryIndex: 7,
                                                                     name: "La Femme d'Argent")]])
        let player = AppQueueHandoffPlayer(store: store,
                                           playFirst: requestedHandoffPlayFirst(backend: FakeMusicInterpreter().backend,
                                                                                appQueue: store))
        return PersistentIDHandoff(library: library, player: player, selfCheck: LibraryAliasSelfCheck(),
                                   currentStamp: { MusicTUIHandoffStamp(epoch: 1, dataEpoch: 1) })
    }

    private let skippedRows = [
        MusicRow(id: "l.1", title: "La Femme d'Argent", artist: "Air", album: "Moon Safari", kind: .song, alias: "178"),
        MusicRow(id: "l.2", title: "Sexy Boy", artist: "Air", album: "Moon Safari", kind: .song, alias: nil),
    ]

    func testAnUnconfirmedHandoffWarningKeepsTheSkippedSongsNotice() throws {
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let report = try skippingHandoff(store).playLibrary(rows: skippedRows, startAt: 1, shuffle: false,
                                                            title: "Moon Safari")
        let notice = try XCTUnwrap(report.notice, "the hand-off skipped one song")
        status.post(LibraryProvenance.playingOnMusicTUI("Moon Safari", report: report), untilStateChange: true)
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Moon Safari") + " " + notice],
                       "the warning replaced the skipped-songs notice")
    }

    func testALateConfirmedHandoffRestoresThePlayingLineWithItsNotice() throws {
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        // Music starts the song late, after the warning showed.
        rig.onRead = { n in
            if n == 9 { rig.setReadings([self.reading("playing", self.new)]) }
        }
        let report = try skippingHandoff(store).playLibrary(rows: skippedRows, startAt: 1, shuffle: false,
                                                            title: "Moon Safari")
        let line = LibraryProvenance.playingOnMusicTUI("Moon Safari", report: report)
        status.post(line, untilStateChange: true)
        rig.runJobs()
        XCTAssertEqual(rig.posts.count, 1, "the warning showed first")
        XCTAssertNil(rig.confirmer.currentTicket(), "the late playing read confirmed it")
        XCTAssertEqual(status.current()?.text, "Playing 'Moon Safari' on MusicTUI. 1 song isn't available to SpanDAC.")
        XCTAssertEqual(status.current()?.text, line, "the late confirmation took the skipped-songs notice away")
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
        rig.runJobs()
        XCTAssertEqual(rig.targets.first, .position(playlist: "Library", index: 41))
        rig.runJobs()
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Moon Safari")])
        XCTAssertEqual(store.read()?.currentIndex, 1, "the queue is kept")
    }

    // MARK: - Codex r1

    private func libraryScene(_ fake: FakeMusicInterpreter, _ store: AppQueueStore, _ status: StatusStore,
                              _ actions: ActionRunner, tracks: [TrackListEntry], matched: Int) -> LibraryScene {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.musicApp)
        let routing = RoutingCoordinator(store: modeStore, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) })
        let sources = LibraryDataSources(onAlbums: { _ in true }, onSongs: { _ in true }, onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        return LibraryScene(backend: fake.backend, routing: routing, sources: sources, appQueue: store,
                            status: status, actions: actions,
                            resolveAlbum: { _, _, _ in AlbumResolution(tracks: tracks, matched: matched) },
                            resultCache: temporaryResultCache().cache)
    }

    func testAWindowReadBegunBeforeANewerRequestForTheSameTrackReleasesNothing() {
        let rig = ConfirmRig([reading("playing", new)])
        let first = rig.confirmer.request()
        rig.onRead = { n in
            if n == 1 {
                let second = rig.confirmer.request()
                rig.confirmer.confirm(second, expected: self.new, title: "Again")
            }
        }
        rig.confirmer.confirm(first, expected: new, title: "Once")
        rig.runNextJob()   // the first window only; its one read began before the second request
        XCTAssertNotNil(rig.confirmer.currentTicket(), "the first request's old read confirmed the second")
        rig.onRead = nil
        rig.runJobs()      // the second window reads for itself
        XCTAssertNil(rig.confirmer.currentTicket())
        XCTAssertEqual(rig.posts, [])
    }

    func testThePausedRequestedTrackDoesNotReleaseTheHold() {
        let rig = ConfirmRig([reading("paused", new)])
        let t = rig.confirmer.request()
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(rig.confirmer.currentTicket(), t, "only `playing` of the requested track confirms")
        XCTAssertEqual(rig.posts, [playNotStartedWarning("Song")])
    }

    func testALateConfirmationWithdrawsThatRequestsWarning() {
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let t = rig.confirmer.request()
        var shown: String?
        rig.onRead = { n in
            guard n == 9 else { return }
            shown = status.current()?.text
            rig.setReadings([self.reading("playing", self.new)])
        }
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(shown, playNotStartedWarning("Song"), "the warning showed after the window")
        XCTAssertNil(status.current(), "the warning for a play now confirmed stayed up")
    }

    func testALateConfirmationNeverWithdrawsAnotherMessage() {
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let t = rig.confirmer.request()
        rig.onRead = { n in
            guard n == 9 else { return }
            status.post("Volume 50%")
            rig.setReadings([self.reading("playing", self.new)])
        }
        rig.confirmer.confirm(t, expected: new, title: "Song")
        rig.runJobs()
        XCTAssertEqual(status.current()?.text, "Volume 50%", "a late confirmation took back another message")
    }

    // UX: the Library's partial-availability notice survives the warning.

    func testALibraryAlbumWarningKeepsThePartialAvailabilityNotice() {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let tracks = (1...3).map { TrackListEntry(index: 40 + $0, name: "T\($0)", artist: "Air", isCurrent: false) }
        libraryScene(fake, store, status, actions, tracks: tracks, matched: 5)
            .playAlbum(title: "Moon Safari", artist: "Air", shuffle: false)
        actions.waitUntilIdle()
        rig.runJobs()
        let text = status.current()?.text ?? ""
        XCTAssertTrue(text.contains(playNotStartedWarning("Moon Safari")), text)
        XCTAssertTrue(text.contains("the rest aren't available yet"), "the warning erased the partial-availability notice: \(text)")
    }


    // MARK: - Codex r4: the play's success is the play command alone

    func testThePlayScriptIsMainsAndTheOnlyScriptOnTheCallersThread() {
        let shipped = FakeMusicInterpreter()
        XCTAssertTrue(playQueueTrack(backend: shipped.backend, playlist: "Mix", position: 3))
        let fake = FakeMusicInterpreter()
        let rig = ConfirmRig([reading("playing", new)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(5, at: 3))
        XCTAssertTrue(playRequestedQueueTrack(backend: fake.backend, appQueue: store, playlist: "Mix",
                                              position: 3, title: "T3"))
        XCTAssertEqual(fake.scripts, shipped.scripts,
                       "the caller's thread ran something other than main's play script")
    }

    func testAKilledIdentityPhaseNeverRollsBackANextMusicAccepted() {
        let fake = FakeMusicInterpreter()
        fake.killIdentityPhase()
        let rig = ConfirmRig([reading("paused", old)])
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        store.set(queue(3, at: 1))
        XCTAssertNoThrow(try musicTUISkip(1, backend: fake.backend, appQueue: store),
                         "a play Music accepted was reported as failed")
        XCTAssertEqual(store.read()?.currentIndex, 2, "the step was rolled back")
    }

    func testAKilledIdentityPhaseNeverRefusesALibraryPlayMusicAccepted() {
        let fake = FakeMusicInterpreter()
        fake.killIdentityPhase()
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        let tracks = (1...3).map { TrackListEntry(index: 40 + $0, name: "T\($0)", artist: "Air", isCurrent: false) }
        libraryScene(fake, store, status, actions, tracks: tracks, matched: 3)
            .playAlbum(title: "Moon Safari", artist: "Air", shuffle: false)
        actions.waitUntilIdle()
        XCTAssertNotEqual(status.current()?.text, "Couldn't play 'Moon Safari'.",
                          "a play Music accepted was refused")
        XCTAssertEqual(store.read()?.currentIndex, 1)
    }

    func testAWithdrawnWarningLeavesThePartialAvailabilityNotice() {
        let fake = FakeMusicInterpreter()
        fake.reply(new + "\n")
        let status = StatusStore()
        let rig = ConfirmRig([reading("paused", old)], status: status)
        let store = AppQueueStore()
        store.confirmer = rig.confirmer
        let actions = ActionRunner(status: status)
        // Music starts the album late, after the warning showed.
        rig.onRead = { n in
            if n == 9 { rig.setReadings([PlayerIdentityReading(state: "playing", persistentID: self.new, requestedID: self.new)]) }
        }
        let tracks = (1...3).map { TrackListEntry(index: 40 + $0, name: "T\($0)", artist: "Air", isCurrent: false) }
        libraryScene(fake, store, status, actions, tracks: tracks, matched: 5)
            .playAlbum(title: "Moon Safari", artist: "Air", shuffle: false)
        actions.waitUntilIdle()
        rig.runJobs()
        XCTAssertEqual(status.current()?.text, "Playing 3 of 5 \u{2014} the rest aren't available yet.",
                       "the late confirmation took the availability notice away with the warning")
    }

    // MARK: - The confirmation reads compile against Music (live, 2026-11-02)

    /// Every variable a confirmation read declares, from its `set X to` lines.
    private func declaredVariables(_ script: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"(?m)^\s*set\s+([A-Za-z_][A-Za-z0-9_]*)\s+to\b"#)
        let range = NSRange(script.startIndex..., in: script)
        return Set(pattern.matches(in: script, range: range).compactMap {
            Range($0.range(at: 1), in: script).map { String(script[$0]) }
        })
    }

    func testTheConfirmationReadsDeclareOnlyTheAllowListedNames() {
        // `st` is a Music term: the read failed to compile (-2741) on every
        // play, live, while every fake-backend test passed. So do not test the
        // script's effect here; pin its names. There is no osacompile or other
        // compile check in this repo, and tests never run osascript.
        let scripts = [playerIdentityReadScript,
                       playerIdentityReadScript(for: .position(playlist: "Mix", index: 3)),
                       playerIdentityReadScript(for: .persistentID(new))]
        let allowed = Set(confirmationReadVariables)
        let knownBad: Set<String> = ["st", "pid", "want", "fs", "active", "left", "state", "name", "index"]
        for script in scripts {
            let declared = declaredVariables(script)
            XCTAssertFalse(declared.isEmpty)
            XCTAssertTrue(declared.isSubset(of: allowed), "undeclared names: \(declared.subtracting(allowed))")
            XCTAssertTrue(declared.isDisjoint(with: knownBad), "a known Music/AppleScript term: \(declared.intersection(knownBad))")
            for name in declared {
                XCTAssertGreaterThanOrEqual(name.count, 7, "\(name): short names collide with Music's terms")
            }
        }
    }

    func testThePositionConfirmationReadIsTheBodyVerifiedLive() {
        // The body the controller ran against Music on 2026-11-02, which
        // answered `paused<US>2034218F875BE907<US>2034218F875BE907`.
        XCTAssertEqual(playerIdentityReadScript(for: .position(playlist: "P", index: 5)), [
            "set sepChar to (ASCII character 31)",
            "set playerStateText to player state as text",
            "set currentPID to \"\"",
            "try",
            "    set currentPID to persistent ID of current track",
            "end try",
            "set wantedPID to \"\"",
            "try",
            "    set wantedPID to persistent ID of track 5 of playlist \"P\"",
            "end try",
            "return playerStateText & sepChar & currentPID & sepChar & wantedPID",
        ].joined(separator: "\n"))
    }
}
