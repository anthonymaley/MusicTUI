import XCTest
@testable import music

// Album-cleanup score step A5: the end, the song phase and its retries.
// Fakes only: a recording action queue, a fake clock, a fake song guard, the
// REAL `DiscoverCopyDeleter` over a fake script runner, in-memory stores.
// Nothing here reaches Music.app, a socket or ~/.config/music.

// MARK: Shared A5 fakes (A5-prefixed: a duplicate type name breaks the target)

/// One ordered record shared by the fakes, so a test can check what ran first.
final class A5Events {
    private(set) var log: [String] = []
    func add(_ event: String) { log.append(event) }
}

/// The action queue, recorded: items run only when the test runs them.
final class A5Queue {
    private(set) var items: [() -> Void] = []
    let events: A5Events?
    init(events: A5Events? = nil) { self.events = events }
    var enqueue: (@escaping () -> Void) -> Void {
        return { [self] item in
            events?.add("enqueue")
            items.append(item)
        }
    }
    var count: Int { items.count }
    @discardableResult
    func runNext() -> Bool {
        guard !items.isEmpty else { return false }
        let item = items.removeFirst()
        item()
        return true
    }
    func drain() { while runNext() {} }
}

final class A5Clock {
    var now: Date
    init(_ seconds: TimeInterval = 1_800_000_000) { now = Date(timeIntervalSince1970: seconds) }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class A5Posts {
    private(set) var toasts: [DiscoverToast] = []
    func post(_ toast: DiscoverToast) { toasts.append(toast) }
}

/// A fake `DiscoverOwnedSongDeleter.run`. It behaves as A4 promises: no
/// "script" (and `.notRun`) unless the entry's container is gone and the song
/// is `owned`; otherwise it answers the next scripted outcome for that
/// position (`.deleted` when none is scripted; the last one repeats) and
/// writes what A4 would write for it.
final class A5Guard {
    let journal: DiscoverCopyJournalStore
    let events: A5Events?
    var outcomes: [Int: [DiscoverSongGuardOutcome]] = [:]
    private(set) var calls: [Int] = []          // positions that reached a "script"
    private(set) var asked: [Int] = []          // every position asked, script or not

    init(journal: DiscoverCopyJournalStore, events: A5Events? = nil) {
        self.journal = journal
        self.events = events
    }

    func run(_ txn: String, _ position: Int) -> DiscoverSongGuardOutcome {
        asked.append(position)
        guard let entry = (try? journal.entries())?.first(where: { $0.txn == txn }),
              entry.containerGone == true,
              entry.songs?.first(where: { $0.position == position })?.state == .owned else { return .notRun }
        calls.append(position)
        events?.add("guard:\(position)")
        var queue = outcomes[position] ?? []
        let outcome: DiscoverSongGuardOutcome
        if queue.isEmpty {
            outcome = .deleted
        } else {
            outcome = queue.count > 1 ? queue.removeFirst() : queue[0]
        }
        outcomes[position] = queue
        _ = try? journal.update(txn: txn) { entry in
            guard var songs = entry.songs, let index = songs.firstIndex(where: { $0.position == position })
            else { return }
            switch outcome {
            case .deleted:
                songs[index].state = .deleted
                songs[index].deletedAt = 1
            case .kept(let reason, let playlist):
                songs[index].state = .kept
                songs[index].keptReason = reason
                songs[index].keptPlaylist = playlist
            case .gaveUp:
                songs[index].state = .kept
                songs[index].keptReason = "couldn't check"
                songs[index].guardStrikes = 3
            case .retry(let strikes):
                songs[index].guardStrikes = strikes
            case .spared, .notRun:
                break
            }
            entry.songs = songs
        }
        return outcome
    }
}

/// A script runner that records every script and answers from a queue (the
/// last answer repeats).
final class A5Runner {
    var answers: [String?]
    let events: A5Events?
    private(set) var scripts: [String] = []
    init(_ answers: [String?], events: A5Events? = nil) {
        self.answers = answers
        self.events = events
    }
    var run: ScriptRunner {
        return { [self] script in
            scripts.append(script)
            events?.add("script")
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        }
    }
}

/// The cleaner and everything it reaches, wired to fakes.
final class A5Rig {
    let events = A5Events()
    let journal: InMemoryDiscoverCopyJournalStore
    let beforeSet: InMemoryBeforeSetStore
    let queue: A5Queue
    let clock = A5Clock()
    let posts = A5Posts()
    let songGuard: A5Guard
    private(set) var logs: [String] = []
    private(set) var cleaner: DiscoverAlbumCleaner!

    init(_ entries: [DiscoverCopyEntry]) {
        journal = InMemoryDiscoverCopyJournalStore(entries: entries)
        var files: [String: Set<String>] = [:]
        for entry in entries { if let file = entry.beforeFile { files[file] = [] } }
        beforeSet = InMemoryBeforeSetStore(files: files)
        queue = A5Queue(events: events)
        songGuard = A5Guard(journal: journal, events: events)
        cleaner = DiscoverAlbumCleaner(seams: .init(
            journal: journal, beforeSet: beforeSet,
            guardSong: { [songGuard] txn, position in songGuard.run(txn, position) },
            enqueue: queue.enqueue,
            post: { [posts] in posts.post($0) },
            now: { [clock] in clock.now },
            log: { [unowned self] in logs.append($0) }))
    }

    func entry(_ txn: String = albumTestTxn) -> DiscoverCopyEntry? {
        journal.stored.first(where: { $0.txn == txn })
    }

    func songStates(_ txn: String = albumTestTxn) -> [DiscoverAlbumSongState] {
        entry(txn)?.songs?.map(\.state) ?? []
    }

    func setSong(_ position: Int, _ change: @escaping (inout DiscoverAlbumSong) -> Void,
                 txn: String = albumTestTxn) {
        _ = try? journal.update(txn: txn) { entry in
            guard var songs = entry.songs, let index = songs.firstIndex(where: { $0.position == position })
            else { return }
            change(&songs[index])
            entry.songs = songs
        }
    }
}

let a5Hex = "00112233AABBCCDD"

// MARK: The tests

final class DiscoverAlbumEndTests: XCTestCase {

    private func playedEntry(songs: [DiscoverAlbumSong], containerGone: Bool? = nil) -> DiscoverCopyEntry {
        albumTestEntry(state: .listening, hex: a5Hex, songs: songs, watching: true,
                       containerGone: containerGone, priorShuffle: true, priorRepeat: "all")
    }

    private struct EndRun {
        let rig: A5Rig
        let runner: A5Runner
        let result: DiscoverCopyDeleteResult
        let restores: [String]
        let readopts: [String]
    }

    private func end(_ entry: DiscoverCopyEntry, answer: String?) -> EndRun {
        let rig = A5Rig([entry])
        let runner = A5Runner([answer], events: rig.events)
        var restores: [String] = []
        var readopts: [String] = []
        let result = discoverAlbumHandleEnd(
            txn: entry.txn, deleter: DiscoverCopyDeleter(journal: rig.journal, run: runner.run),
            journal: rig.journal,
            restoreModes: { restores.append($0); rig.events.add("restore") },
            readopt: { txn, hex in readopts.append("\(txn):\(hex)") },
            cleaner: rig.cleaner)
        return EndRun(rig: rig, runner: runner, result: result, restores: restores, readopts: readopts)
    }

    private func ownedSongs(_ count: Int) -> [DiscoverAlbumSong] {
        (1...count).map { albumTestSong($0, state: .owned) }
    }

    // MARK: Design test 11: end order

    func testTheContainerScriptRunsBeforeAnySongItem() throws {
        let run = end(playedEntry(songs: ownedSongs(3)), answer: "deleted")
        XCTAssertEqual(run.result, .deleted)
        XCTAssertEqual(run.rig.events.log, ["script", "restore", "enqueue", "enqueue", "enqueue"],
                       "the container goes first, then the restore, then one item per song")
        XCTAssertEqual(run.runner.scripts.count, 1)
        XCTAssertTrue(run.runner.scripts[0].contains("delete pl"), "the one script is the container's")
        XCTAssertTrue(run.rig.songGuard.calls.isEmpty, "no song is touched inline")
        let entry = try XCTUnwrap(run.rig.entry())
        XCTAssertEqual(entry.containerGone, true)
        XCTAssertEqual(entry.listeningEnded, true)
        XCTAssertEqual(entry.state, .listening, "CH6: an album entry is not closed by the container's delete")

        run.rig.queue.drain()
        XCTAssertEqual(run.rig.songGuard.calls, [1, 2, 3], "album order, one item each")
        XCTAssertEqual(run.rig.songStates(), [.deleted, .deleted, .deleted])
    }

    func testEachSongIsItsOwnQueueItem() {
        let run = end(playedEntry(songs: ownedSongs(3)), answer: "deleted")
        XCTAssertEqual(run.rig.queue.count, 3)
        run.rig.queue.runNext()
        XCTAssertEqual(run.rig.songGuard.calls, [1], "one item runs one song's guard")
        run.rig.queue.runNext()
        XCTAssertEqual(run.rig.songGuard.calls, [1, 2])
    }

    func testTheRestoreRunsForEveryContainerResult() {
        let cases: [(String?, DiscoverCopyDeleteResult)] = [
            ("deleted", .deleted), ("gone", .alreadyGone), ("spared", .spared),
            ("still", .failed), (nil, .failed), ("something else", .failed),
        ]
        for (answer, expected) in cases {
            let run = end(playedEntry(songs: ownedSongs(2)), answer: answer)
            XCTAssertEqual(run.result, expected, "\(String(describing: answer))")
            XCTAssertEqual(run.restores, [albumTestTxn], "restore for \(String(describing: answer))")
        }
    }

    func testASparedContainerIsReadoptedAndNoSongItemIsEnqueued() throws {
        let run = end(playedEntry(songs: ownedSongs(3)), answer: "spared")
        XCTAssertEqual(run.result, .spared)
        XCTAssertEqual(run.readopts, ["\(albumTestTxn):\(a5Hex)"])
        XCTAssertEqual(run.rig.queue.count, 0)
        XCTAssertTrue(run.rig.songGuard.asked.isEmpty)
        let entry = try XCTUnwrap(run.rig.entry())
        XCTAssertNil(entry.containerGone)
        XCTAssertEqual(entry.listeningEnded, true, "recorded; it gates nothing (CH8)")
    }

    func testAFailedContainerDeleteTouchesNoSong() {
        for answer in ["still", nil] as [String?] {
            let run = end(playedEntry(songs: ownedSongs(2)), answer: answer)
            XCTAssertEqual(run.result, .failed)
            XCTAssertEqual(run.rig.queue.count, 0)
            XCTAssertNil(run.rig.entry()?.containerGone)
            XCTAssertTrue(run.readopts.isEmpty)
        }
    }

    func testAContainerAlreadyGoneStartsTheSongPhase() {
        let run = end(playedEntry(songs: ownedSongs(2)), answer: "gone")
        XCTAssertEqual(run.result, .alreadyGone)
        XCTAssertEqual(run.rig.queue.count, 2)
        XCTAssertEqual(run.rig.entry()?.containerGone, true)
    }

    // MARK: The song phase

    func testTheSongPhaseNeedsTheContainerGone() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(2))])
        rig.cleaner.songPhase(txn: albumTestTxn)
        XCTAssertEqual(rig.queue.count, 0)
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 1)
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testOnlyOwnedSongsAreHandedToTheGuardInAlbumOrder() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .preexisting),
                     albumTestSong(3, state: .pending), albumTestSong(4, state: .uncertain),
                     albumTestSong(5, state: .owned)]
        let rig = A5Rig([playedEntry(songs: songs, containerGone: true)])
        rig.cleaner.songPhase(txn: albumTestTxn)
        XCTAssertEqual(rig.queue.count, 2)
        rig.queue.drain()
        XCTAssertEqual(rig.songGuard.asked, [1, 5], "pending, uncertain and preexisting songs never reach the guard")
        XCTAssertEqual(rig.songStates(), [.deleted, .preexisting, .pending, .uncertain, .deleted])
    }

    func testWithNoOwnedSongTheSongPhaseSettlesAtOnce() {
        let songs = [albumTestSong(1, state: .deleted), albumTestSong(2, state: .preexisting)]
        let rig = A5Rig([playedEntry(songs: songs, containerGone: true)])
        rig.cleaner.songPhase(txn: albumTestTxn)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.posts.toasts, [.progress(discoverAlbumAllRemovedText(album: albumTestAlbum))])
        XCTAssertEqual(rig.entry()?.state, .closed)
    }

    // MARK: Design test 14 (end half): a pending song at the end

    func testAPendingSongGetsNoGuardItemUntilHandedOver() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)]
        let run = end(playedEntry(songs: songs), answer: "deleted")
        XCTAssertEqual(run.rig.queue.count, 1)
        run.rig.queue.drain()
        XCTAssertEqual(run.rig.songGuard.asked, [1])
        XCTAssertTrue(run.rig.posts.toasts.isEmpty, "nothing is told while a song is still being proven")
        XCTAssertEqual(run.rig.entry()?.state, .listening)

        // The proof collector proves song 2 after the end and hands it over.
        run.rig.setSong(2) { song in
            song.state = .owned
            song.entryHex = albumTestHex(2)
            song.alias = "2"
        }
        run.rig.cleaner.handToGuard(txn: albumTestTxn, position: 2)
        XCTAssertEqual(run.rig.queue.count, 1)
        run.rig.queue.drain()
        XCTAssertEqual(run.rig.songGuard.calls, [1, 2])
        XCTAssertEqual(run.rig.posts.toasts, [.progress(discoverAlbumAllRemovedText(album: albumTestAlbum))])
        XCTAssertEqual(run.rig.entry()?.state, .closed)
    }

    func testAPendingSongWhoseWindowClosesIsToldByName() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)]
        let run = end(playedEntry(songs: songs), answer: "deleted")
        run.rig.queue.drain()
        // The collector's window closes: the song becomes uncertain, then settled.
        run.rig.setSong(2) { $0.state = .uncertain }
        run.rig.cleaner.settle(txn: albumTestTxn)
        XCTAssertEqual(run.rig.songGuard.asked, [1], "an uncertain song never reaches the guard")
        XCTAssertEqual(run.rig.posts.toasts, [
            .outcome(.refused("MusicTUI left 'Track 2' from 'Test Album' in your library because it couldn't prove it added it."),
                     title: albumTestAlbum),
        ])
        XCTAssertEqual(run.rig.entry()?.state, .listening, "open until the launch repeat (CH9)")
    }

    // MARK: Retries

    func testSparedAndRetrySongsAreRetriedEveryRetryInterval() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(3), containerGone: true)])
        rig.songGuard.outcomes = [1: [.spared, .deleted], 2: [.retry(strikes: 1), .deleted]]
        rig.cleaner.songPhase(txn: albumTestTxn)
        rig.queue.drain()
        XCTAssertEqual(rig.songGuard.calls, [1, 2, 3])
        XCTAssertEqual(rig.songStates(), [.owned, .owned, .deleted])

        rig.clock.advance(DiscoverAlbumTiming.retryInterval - 1)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 0, "not before the interval")

        rig.clock.advance(1)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 2)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 2, "a song already on the queue is not queued again")
        rig.queue.drain()
        XCTAssertEqual(rig.songGuard.calls, [1, 2, 3, 1, 2])
        XCTAssertEqual(rig.songStates(), [.deleted, .deleted, .deleted])

        rig.clock.advance(DiscoverAlbumTiming.retryInterval)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 0, "a settled song is never retried")
    }

    func testKeptGaveUpAndNotRunSongsAreNotRetried() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(2), containerGone: true)])
        rig.songGuard.outcomes = [1: [.kept(reason: "loved", playlist: nil)], 2: [.gaveUp]]
        rig.cleaner.songPhase(txn: albumTestTxn)
        rig.queue.drain()
        rig.clock.advance(DiscoverAlbumTiming.retryInterval * 3)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testATickWithNothingWaitingDoesNothing() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(2), containerGone: true)])
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.journal.events.isEmpty, "no journal read either")
    }

    func testHandingTheSameSongTwiceQueuesOneItem() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(2), containerGone: true)])
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 1)
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 1)
        XCTAssertEqual(rig.queue.count, 1)
        rig.queue.drain()
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 1)
        XCTAssertEqual(rig.queue.count, 0, "a deleted song is not owned any more")
    }

    func testHandToGuardIgnoresASongThatIsNotOwned() {
        let songs = [albumTestSong(1, state: .pending), albumTestSong(2, state: .kept, keptReason: "loved")]
        let rig = A5Rig([playedEntry(songs: songs, containerGone: true)])
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 1)
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 2)
        rig.cleaner.handToGuard(txn: albumTestTxn, position: 9)
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testAnUnreadableJournalHandsNothingOver() {
        let rig = A5Rig([playedEntry(songs: ownedSongs(2), containerGone: true)])
        let broken = A5UnreadableJournal()
        let cleaner = DiscoverAlbumCleaner(seams: .init(
            journal: broken, beforeSet: rig.beforeSet, guardSong: { _, _ in .deleted },
            enqueue: rig.queue.enqueue, post: { rig.posts.post($0) }, now: { rig.clock.now }, log: { _ in }))
        cleaner.songPhase(txn: albumTestTxn)
        cleaner.handToGuard(txn: albumTestTxn, position: 1)
        cleaner.settle(txn: albumTestTxn)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.posts.toasts.isEmpty)
    }
}

/// A journal that can never be read.
final class A5UnreadableJournal: DiscoverCopyJournalStore {
    func entries() throws -> [DiscoverCopyEntry] { throw DiscoverCopyJournalError.unreadable }
    func insert(_ entry: DiscoverCopyEntry) throws { throw DiscoverCopyJournalError.unreadable }
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        throw DiscoverCopyJournalError.unreadable
    }
}
