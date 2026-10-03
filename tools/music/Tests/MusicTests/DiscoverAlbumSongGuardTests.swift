import XCTest
@testable import music

// Score step A4: the song guard. Design tests 12 (script text), 13 (answers),
// 23 (unreadable keeps) and CH15 (another live MusicTUI container spares).
// Every script goes to a fake runner; nothing here runs AppleScript.

/// A fake `ScriptRunner`: records every script and answers from `answer`.
private final class A4ScriptRunner {
    private(set) var scripts: [String] = []
    var answer: (String) -> String?

    init(_ answer: @escaping (String) -> String?) { self.answer = answer }
    convenience init(answers: [String?]) {
        var queue = answers
        self.init { _ in queue.isEmpty ? nil : queue.removeFirst() }
    }

    var run: ScriptRunner {
        { [unowned self] script in
            self.scripts.append(script)
            return self.answer(script)
        }
    }
    var deletingScripts: Int { scripts.filter { $0.contains("\ndelete songRef\n") }.count }
}

private final class A4UnreadableJournal: DiscoverCopyJournalStore {
    func entries() throws -> [DiscoverCopyEntry] { throw DiscoverCopyJournalError.unreadable }
    func insert(_ entry: DiscoverCopyEntry) throws { throw DiscoverCopyJournalError.unreadable }
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        throw DiscoverCopyJournalError.unreadable
    }
}

private let a4Now = Date(timeIntervalSince1970: 1_800_000_000.5)
private let a4OtherTxn = "A1B2C3D4-0000-4000-8000-00000000B2C0"
private let a4OtherHex = "00000000000C0FFE"
private let a4ThirdHex = "0000000000BEEF00"

/// An album entry whose container is gone and whose songs are all `owned`.
private func a4GoneEntry(songs: [DiscoverAlbumSong]? = nil) -> DiscoverCopyEntry {
    albumTestEntry(state: .listening, hex: "00000000000000AA", songs: songs, songCount: 3,
                   songState: .owned, containerGone: true)
}

private func a4CopyEntry(txn: String, state: DiscoverCopyState, hex: String?) -> DiscoverCopyEntry {
    DiscoverCopyEntry(txn: txn, playlistID: "pl.copy", title: "A Copy", state: state, hex: hex,
                      copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                      priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
}

private func a4Song(_ journal: InMemoryDiscoverCopyJournalStore, _ position: Int,
                    txn: String = albumTestTxn) -> DiscoverAlbumSong? {
    journal.stored.first { $0.txn == txn }?.songs?.first { $0.position == position }
}

private func a4Index(_ needle: String, in script: String, file: StaticString = #filePath,
                     line: UInt = #line) -> String.Index {
    guard let range = script.range(of: needle) else {
        XCTFail("missing: \(needle)", file: file, line: line)
        return script.endIndex
    }
    return range.lowerBound
}

final class DiscoverAlbumSongGuardTests: XCTestCase {
    private let hex = albumTestHex(2)

    private func deleter(_ journal: DiscoverCopyJournalStore, _ runner: A4ScriptRunner) -> DiscoverOwnedSongDeleter {
        DiscoverOwnedSongDeleter(journal: journal, run: runner.run, now: { a4Now })
    }

    // MARK: Design test 12: the script text

    func testEveryKeepCheckAndThePlayerCheckPrecedeTheOnlyDelete() {
        for live in [[], [a4OtherHex], [a4OtherHex, a4ThirdHex]] {
            let script = discoverOwnedSongGuardScript(hex: hex, live: live, delete: true)
            XCTAssertEqual(script.components(separatedBy: "delete").count - 1, 2,
                           "only `delete songRef` and the `deleted` answer")
            XCTAssertEqual(script.components(separatedBy: "\ndelete songRef\n").count - 1, 1)
            let deleteAt = a4Index("\ndelete songRef\n", in: script)
            for check in ["set userLists to every user playlist",
                          "if userLists is missing value then return \"unreadable\"",
                          "set plSmart to smart of plRef",
                          "if plSmart is not true then",
                          "set plHitCount to count of (tracks of plRef whose persistent ID is \"\(hex)\")",
                          "return \"kept|playlist|\" & plNameText",
                          "if liveHolds then return \"spared\"",
                          "set lovedFlag to favorited of songRef",
                          "if lovedFlag is missing value then return \"unreadable\"",
                          "if lovedFlag is true then return \"kept|loved\"",
                          "set albumLovedFlag to album favorited of songRef",
                          "if albumLovedFlag is missing value then return \"unreadable\"",
                          "if albumLovedFlag is true then return \"kept|album\"",
                          "set stateText to (player state as text)",
                          "set currentSongID to (persistent ID of current track) as text",
                          "if currentSongID is \"\" or currentSongID is \"\(hex)\" then return \"spared\""] {
                XCTAssertLessThan(a4Index(check, in: script), deleteAt, check)
            }
            // The scan runs first, the cheap checks last.
            XCTAssertLessThan(a4Index("end repeat", in: script), a4Index("favorited of songRef", in: script))
            XCTAssertTrue(script.contains("set stateText to \"\(unreadablePlayerStateFallback)\""))
            XCTAssertTrue(script.hasSuffix("if (count of afterHits) is 0 then return \"deleted\"\nreturn \"still\""))
        }
    }

    func testASmartPlaylistIsReadAndSkipped() {
        let script = discoverOwnedSongGuardScript(hex: hex, live: [], delete: true)
        let smartAt = a4Index("set plSmart to smart of plRef", in: script)
        let skipAt = a4Index("if plSmart is not true then", in: script)
        let countAt = a4Index("set plHitCount to count of", in: script)
        XCTAssertLessThan(smartAt, skipAt)
        XCTAssertLessThan(skipAt, countAt)
        // An unreadable `smart` stays `missing value`, which is "not true": scanned.
        XCTAssertTrue(script.contains("set plSmart to missing value\n    try\n        set plSmart to smart of plRef"))
        // An unreadable count stays -1, which is a hit.
        XCTAssertTrue(script.contains("set plHitCount to -1"))
    }

    func testLiveContainersRouteToSparedAndNeverToKept() {
        let script = discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex], delete: true)
        XCTAssertTrue(script.contains("""
                if plIDText is "\(a4OtherHex)" then
                    if plHitCount is not 0 then set liveHolds to true
                else
                    if plHitCount is not 0 then return "kept|playlist|" & plNameText
                end if
        """))
        XCTAssertEqual(script.components(separatedBy: "kept|playlist|").count - 1, 1)
        XCTAssertLessThan(a4Index("if liveHolds then return \"spared\"", in: script),
                          a4Index("favorited of songRef", in: script))

        let two = discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex, a4ThirdHex], delete: true)
        XCTAssertTrue(two.contains("if plIDText is \"\(a4OtherHex)\" or plIDText is \"\(a4ThirdHex)\" then"))

        let none = discoverOwnedSongGuardScript(hex: hex, live: [], delete: true)
        XCTAssertFalse(none.contains("plIDText is \""), "with no live container the branch is omitted")
        XCTAssertFalse(none.contains("set liveHolds to true"))
        XCTAssertTrue(none.contains("        end try\n        if plHitCount is not 0 then return \"kept|playlist|\" & plNameText\n    end if"))
    }

    func testTheSongIsAddressedByPersistentIDOnlyAndNoTitleAppears() {
        let entry = a4GoneEntry()
        for live in [[], [a4OtherHex]] {
            for delete in [true, false] {
                let script = discoverOwnedSongGuardScript(hex: hex, live: live, delete: delete)
                for song in entry.songs ?? [] {
                    XCTAssertFalse(script.contains(song.title))
                    XCTAssertFalse(script.contains(song.catalogueID))
                }
                XCTAssertFalse(script.contains(albumTestAlbum))
                XCTAssertFalse(script.contains("name of songRef"))
                XCTAssertFalse(script.contains("whose name"))
                for line in script.split(separator: "\n") where line.contains("track") {
                    let text = String(line)
                    let allowed = text.contains("whose persistent ID is \"\(hex)\"")
                        || text.contains("persistent ID of current track")
                    XCTAssertTrue(allowed, "a track reference not by persistent ID: \(text)")
                }
                XCTAssertTrue(script.contains("set songRef to item 1 of songHits"))
            }
        }
    }

    func testDeleteFalseHoldsNoDelete() {
        for live in [[], [a4OtherHex]] {
            let script = discoverOwnedSongGuardScript(hex: hex, live: live, delete: false)
            XCTAssertFalse(script.contains("delete"))
            XCTAssertFalse(script.contains("afterHits"))
            XCTAssertTrue(script.hasSuffix("then return \"spared\"\nend if\nreturn \"checked\""))
            let deleting = discoverOwnedSongGuardScript(hex: hex, live: live, delete: true)
            let shared = deleting.components(separatedBy: "\ndelete songRef\n")[0]
            XCTAssertEqual(script, shared + "\nreturn \"checked\"")
        }
    }

    func testAMalformedHexBuildsAScriptThatTouchesNothing() {
        for (bad, live) in [("00000000000000ab", [String]()), ("ABC", []), ("", []),
                            (hex, ["XYZ"]), (hex, ["00000000000000aa"])] {
            let script = discoverOwnedSongGuardScript(hex: bad, live: live, delete: true)
            XCTAssertEqual(script, "return \"unreadable\"")
        }
    }

    func testAMalformedEntryHexRunsNoScript() {
        for bad in ["00000000000000ab", "123", "ZZZZZZZZZZZZZZZZ"] {
            var song = albumTestSong(2, state: .owned)
            song.entryHex = bad
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(songs: [
                albumTestSong(1, state: .owned), song, albumTestSong(3, state: .owned),
            ])])
            let runner = A4ScriptRunner(answers: ["deleted"])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .notRun)
            XCTAssertTrue(runner.scripts.isEmpty)
        }
    }

    func testTheNameGate() {
        let scripts = [
            discoverOwnedSongGuardScript(hex: hex, live: [], delete: true),
            discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex], delete: true),
            discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex, a4ThirdHex], delete: true),
            discoverOwnedSongGuardScript(hex: hex, live: [], delete: false),
            discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex], delete: false),
        ]
        for script in scripts {
            let names = appleScriptAssignedNames(script)
            XCTAssertFalse(names.isEmpty)
            XCTAssertTrue(names.isSubset(of: discoverAlbumScriptVariables),
                          "not allowed: \(names.subtracting(discoverAlbumScriptVariables))")
            XCTAssertTrue(names.isDisjoint(with: discoverAppleScriptReservedNames))
        }
        XCTAssertTrue(appleScriptAssignedNames(scripts[0]).isSuperset(of: [
            "songHits", "userLists", "liveHolds", "plRef", "plSmart", "plIDText", "plNameText",
            "plHitCount", "songRef", "lovedFlag", "albumLovedFlag", "stateText", "currentSongID", "afterHits",
        ]))
    }

    // MARK: The live containers (CH15)

    func testLiveContainerHexes() {
        let mine = albumTestEntry(state: .listening, hex: "00000000000000AA", songState: .owned, containerGone: true)
        let liveAlbum = albumTestEntry(txn: a4OtherTxn, state: .listening, hex: a4OtherHex, songState: .owned)
        let ownedCopy = a4CopyEntry(txn: "C0", state: .owned, hex: a4ThirdHex)
        let entries = [
            mine, liveAlbum, ownedCopy,
            a4CopyEntry(txn: "C1", state: .preexisting, hex: "0000000000000011"),
            a4CopyEntry(txn: "C2", state: .closed, hex: "0000000000000022"),
            a4CopyEntry(txn: "C3", state: .uncertain, hex: "0000000000000033"),
            a4CopyEntry(txn: "C4", state: .intent, hex: nil),
            albumTestEntry(txn: "A5", state: .owned, hex: "0000000000000055", songState: .owned, containerGone: true),
            albumTestEntry(txn: "A6", state: .preexisting, hex: "0000000000000066", songState: .preexisting),
        ]
        XCTAssertEqual(discoverLiveContainerHexes(entries, excluding: albumTestTxn), [a4OtherHex, a4ThirdHex])
        // The excluded txn's own hex never appears, gone or not.
        var mineLive = mine
        mineLive.containerGone = nil
        XCTAssertEqual(discoverLiveContainerHexes([mineLive], excluding: albumTestTxn), [])
        XCTAssertEqual(discoverLiveContainerHexes([mineLive], excluding: a4OtherTxn), ["00000000000000AA"])
    }

    func testPreexistingEntriesAreNotLive() {
        let entries = [
            a4CopyEntry(txn: "C1", state: .preexisting, hex: a4OtherHex),
            albumTestEntry(txn: a4OtherTxn, state: .preexisting, hex: a4ThirdHex, songState: .preexisting),
        ]
        XCTAssertEqual(discoverLiveContainerHexes(entries, excluding: albumTestTxn), [])
    }

    func testAMalformedLiveHexIsNilAndRunsNoScript() {
        for bad: String? in ["00000000000000ab", "12", nil] {
            let live = a4CopyEntry(txn: "C0", state: .listening, hex: bad)
            XCTAssertNil(discoverLiveContainerHexes([live], excluding: albumTestTxn))
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(), live])
            let runner = A4ScriptRunner(answers: ["deleted"])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .notRun)
            XCTAssertTrue(runner.scripts.isEmpty)
            XCTAssertEqual(a4Song(journal, 2)?.state, .owned)
        }
    }

    func testCH15ASecondLiveAlbumSparesUntilItsContainerIsGone() {
        let second = albumTestEntry(txn: a4OtherTxn, state: .listening, hex: a4OtherHex,
                                    songs: [albumTestSong(1, state: .preexisting)], watching: true)
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(), second])
        // Music.app as the fake sees it: the second container holds the song
        // while it exists; once it is gone nothing else holds it.
        var secondExists = true
        let runner = A4ScriptRunner { script in
            if script.contains("plIDText is \"\(a4OtherHex)\"") { return secondExists ? "spared" : "kept|playlist|x" }
            return secondExists ? "kept|playlist|" + discoverPlaylistPrefix + a4OtherTxn : "deleted"
        }
        let guardSong = deleter(journal, runner)

        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .spared)
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertTrue(runner.scripts[0].contains("plIDText is \"\(a4OtherHex)\""))
        XCTAssertEqual(a4Song(journal, 2)?.state, .owned)
        XCTAssertEqual(a4Song(journal, 2)?.guardStrikes, 0)

        // Spared again on the retry: never kept, no strike.
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .spared)
        XCTAssertEqual(a4Song(journal, 2)?.state, .owned)

        // The second container goes.
        secondExists = false
        _ = try? journal.update(txn: a4OtherTxn) { $0.containerGone = true; $0.watching = false }

        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .deleted)
        XCTAssertEqual(runner.scripts.count, 3)
        XCTAssertFalse(runner.scripts[2].contains("plIDText is \""))
        XCTAssertTrue(runner.scripts[2].contains("\ndelete songRef\n"))
        XCTAssertEqual(a4Song(journal, 2)?.state, .deleted)
    }

    func testAPreexistingSecondEntryIsHisSoTheSongIsKept() {
        let his = albumTestEntry(txn: a4OtherTxn, state: .preexisting, hex: a4OtherHex,
                                 songState: .preexisting)
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(), his])
        let runner = A4ScriptRunner { script in
            script.contains("plIDText is \"\(a4OtherHex)\"") ? "spared" : "kept|playlist|His List"
        }
        XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 1),
                       .kept(reason: "playlist", playlist: "His List"))
        XCTAssertEqual(a4Song(journal, 1)?.state, .kept)
    }

    // MARK: Design test 13: each answer maps to its outcome

    func testDeletedAndGoneBecomeDeleted() {
        for answer in ["deleted", "gone", "  gone\n", "deleted\n"] {
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
            let runner = A4ScriptRunner(answers: [answer])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .deleted, answer)
            let song = a4Song(journal, 2)
            XCTAssertEqual(song?.state, .deleted)
            XCTAssertEqual(song?.deletedAt, a4Now.timeIntervalSince1970)
            XCTAssertEqual(song?.entryHex, hex)
            XCTAssertEqual(a4Song(journal, 1)?.state, .owned, "only the asked song changes")
            XCTAssertEqual(runner.scripts, [discoverOwnedSongGuardScript(hex: hex, live: [], delete: true)])
        }
    }

    func testKeptAnswersBecomeKeptWithTheirReason() {
        let cases: [(String, DiscoverSongGuardOutcome, String, String?)] = [
            ("kept|loved", .kept(reason: "loved", playlist: nil), "loved", nil),
            ("kept|album", .kept(reason: "album", playlist: nil), "album", nil),
            ("kept|playlist|House", .kept(reason: "playlist", playlist: "House"), "playlist", "House"),
            ("kept|playlist|Rock | Roll \"Live\" 'n' |", .kept(reason: "playlist", playlist: "Rock | Roll \"Live\" 'n' |"),
             "playlist", "Rock | Roll \"Live\" 'n' |"),
            ("kept|playlist|a|b|c\n", .kept(reason: "playlist", playlist: "a|b|c"), "playlist", "a|b|c"),
        ]
        for (answer, outcome, reason, playlist) in cases {
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
            let runner = A4ScriptRunner(answers: [answer])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), outcome, answer)
            let song = a4Song(journal, 2)
            XCTAssertEqual(song?.state, .kept)
            XCTAssertEqual(song?.keptReason, reason)
            XCTAssertEqual(song?.keptPlaylist, playlist)
            XCTAssertNil(song?.deletedAt)
        }
    }

    func testSparedLeavesTheSongUnchanged() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
        let before = journal.stored
        let runner = A4ScriptRunner(answers: ["spared"])
        XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .spared)
        XCTAssertEqual(journal.stored, before)
        XCTAssertFalse(journal.events.contains { $0.hasPrefix("update") })
    }

    func testStrikeAnswersCountAndTheThirdGivesUp() {
        for answer: String? in ["unreadable", "still", "checked", "kept", "kept|", "Deleted", "", nil] {
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
            let runner = A4ScriptRunner { _ in answer }
            let guardSong = deleter(journal, runner)
            XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .retry(strikes: 1), String(describing: answer))
            XCTAssertEqual(a4Song(journal, 2)?.guardStrikes, 1)
            XCTAssertEqual(a4Song(journal, 2)?.state, .owned)
            XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .retry(strikes: 2))
            XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .gaveUp)
            let song = a4Song(journal, 2)
            XCTAssertEqual(song?.state, .kept)
            XCTAssertEqual(song?.keptReason, "couldn't check")
            XCTAssertNil(song?.keptPlaylist)
            XCTAssertEqual(song?.guardStrikes, 3)
            XCTAssertEqual(runner.scripts.count, 3)
        }
    }

    func testATimeoutIsAStrike() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
        let runner = A4ScriptRunner(answers: [nil])   // the runner's 10 s bound answers nil
        XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .retry(strikes: 1))
        XCTAssertEqual(a4Song(journal, 2)?.state, .owned)
    }

    func testParse() {
        XCTAssertNil(parseDiscoverSongGuardAnswer(nil))
        XCTAssertNil(parseDiscoverSongGuardAnswer("whatever"))
        XCTAssertNil(parseDiscoverSongGuardAnswer(""))
        XCTAssertEqual(parseDiscoverSongGuardAnswer(" gone \n"), .gone)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("deleted"), .deleted)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("spared"), .spared)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("still"), .still)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("unreadable"), .unreadable)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("checked"), .checked)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("kept|loved"), .keptLoved)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("kept|album"), .keptAlbum)
        XCTAssertEqual(parseDiscoverSongGuardAnswer("kept|playlist|"), .keptPlaylist(""))
        XCTAssertEqual(parseDiscoverSongGuardAnswer("kept|playlist|kept|loved"), .keptPlaylist("kept|loved"))
        XCTAssertEqual(parseDiscoverSongGuardAnswer("kept|playlist|\"Q\" | 'R'"), .keptPlaylist("\"Q\" | 'R'"))
    }

    func testSongsNotOwnedAndContainersNotGoneRunNoScript() {
        for state in [DiscoverAlbumSongState.intent, .pending, .uncertain, .preexisting, .deleted, .kept] {
            var song = albumTestSong(2, state: state)
            if state == .deleted { song.entryHex = hex }
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(songs: [
                albumTestSong(1, state: .owned), song, albumTestSong(3, state: .owned),
            ])])
            let runner = A4ScriptRunner(answers: ["deleted"])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .notRun, state.rawValue)
            XCTAssertTrue(runner.scripts.isEmpty)
        }
        for gone: Bool? in [nil, false] {
            let entry = albumTestEntry(state: .listening, hex: "00000000000000AA", songState: .owned,
                                       containerGone: gone)
            let journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
            let runner = A4ScriptRunner(answers: ["deleted"])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 1), .notRun)
            XCTAssertTrue(runner.scripts.isEmpty)
        }
    }

    func testNoEntryNoSongOrACopyEntryRunsNoScript() {
        let copy = a4CopyEntry(txn: albumTestTxn, state: .owned, hex: "00000000000000AA")
        let cases: [(InMemoryDiscoverCopyJournalStore, String, Int)] = [
            (InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()]), a4OtherTxn, 1),
            (InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()]), albumTestTxn, 9),
            (InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()]), albumTestTxn, 0),
            (InMemoryDiscoverCopyJournalStore(entries: [copy]), albumTestTxn, 1),
            (InMemoryDiscoverCopyJournalStore(entries: []), albumTestTxn, 1),
        ]
        for (journal, txn, position) in cases {
            let runner = A4ScriptRunner(answers: ["deleted"])
            XCTAssertEqual(deleter(journal, runner).run(txn: txn, position: position), .notRun)
            XCTAssertTrue(runner.scripts.isEmpty)
        }
    }

    func testAnOwnedSongWithNoEntryHexRunsNoScript() {
        var song = albumTestSong(1, state: .owned)
        song.entryHex = nil
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(songs: [song])])
        let runner = A4ScriptRunner(answers: ["deleted"])
        XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 1), .notRun)
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testAnUnreadableJournalRetriesWithNoStrikeAndNoScript() {
        let runner = A4ScriptRunner(answers: ["deleted"])
        XCTAssertEqual(deleter(A4UnreadableJournal(), runner).run(txn: albumTestTxn, position: 1),
                       .retry(strikes: 0))
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testAFailedJournalWriteLeavesTheSongOwnedAndRetries() {
        for answer in ["deleted", "kept|loved", "unreadable"] {
            let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
            journal.failWrites = { $0.hasPrefix("update:") }
            let runner = A4ScriptRunner(answers: [answer])
            XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .retry(strikes: 0), answer)
            XCTAssertEqual(a4Song(journal, 2)?.state, .owned)
            XCTAssertEqual(a4Song(journal, 2)?.guardStrikes, 0)
        }
        // A deleted song whose write failed reads `gone` next time.
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
        journal.failWrites = { $0.hasPrefix("update:") }
        let runner = A4ScriptRunner(answers: ["deleted", "gone"])
        let guardSong = deleter(journal, runner)
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .retry(strikes: 0))
        journal.failWrites = { _ in false }
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 2), .deleted)
        XCTAssertEqual(a4Song(journal, 2)?.state, .deleted)
    }

    // MARK: Design test 23: an unreadable keep fact never deletes

    func testUnreadableKeepFactsReturnBeforeTheDelete() {
        let script = discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex], delete: true)
        let deleteAt = a4Index("\ndelete songRef\n", in: script)
        // The playlist list, `favorited` and `album favorited` each answer
        // `unreadable` when they cannot be read, before the delete.
        for line in ["if userLists is missing value then return \"unreadable\"",
                     "if lovedFlag is missing value then return \"unreadable\"",
                     "if albumLovedFlag is missing value then return \"unreadable\""] {
            XCTAssertLessThan(a4Index(line, in: script), deleteAt)
        }
        // And each read starts as `missing value` inside a `try`.
        for read in ["set userLists to missing value\ntry\n    set userLists to every user playlist\nend try",
                     "set lovedFlag to missing value\ntry\n    set lovedFlag to favorited of songRef\nend try",
                     "set albumLovedFlag to missing value\ntry\n    set albumLovedFlag to album favorited of songRef\nend try"] {
            XCTAssertTrue(script.contains(read), read)
        }
    }

    func testUnreadableAnswersNeverDeleteAndThreeGiveCouldntCheck() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
        let runner = A4ScriptRunner(answers: ["unreadable", "unreadable", "unreadable", "deleted"])
        let guardSong = deleter(journal, runner)
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 3), .retry(strikes: 1))
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 3), .retry(strikes: 2))
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 3), .gaveUp)
        XCTAssertEqual(a4Song(journal, 3)?.state, .kept)
        XCTAssertEqual(a4Song(journal, 3)?.keptReason, "couldn't check")
        XCTAssertNil(a4Song(journal, 3)?.deletedAt)
        // A later item for the same song runs nothing.
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 3), .notRun)
        XCTAssertEqual(runner.scripts.count, 3)
    }

    func testATimeoutThenGoneDeletesOnceAndALaterItemRunsNothing() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry()])
        let runner = A4ScriptRunner(answers: [nil, "gone", "deleted"])
        let guardSong = deleter(journal, runner)
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 1), .retry(strikes: 1))
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 1), .deleted)
        XCTAssertEqual(runner.scripts.count, 2, "one script per item")
        XCTAssertEqual(runner.deletingScripts, 2)
        XCTAssertEqual(a4Song(journal, 1)?.state, .deleted)
        XCTAssertEqual(a4Song(journal, 1)?.guardStrikes, 1)
        XCTAssertEqual(guardSong.run(txn: albumTestTxn, position: 1), .notRun)
        XCTAssertEqual(runner.scripts.count, 2, "a later item runs no script")
    }

    func testTheDeleterAlwaysSendsTheDeletingFormWithTheLiveList() {
        let live = albumTestEntry(txn: a4OtherTxn, state: .owned, hex: a4OtherHex, songState: .owned)
        let journal = InMemoryDiscoverCopyJournalStore(entries: [a4GoneEntry(), live])
        let runner = A4ScriptRunner(answers: ["deleted"])
        XCTAssertEqual(deleter(journal, runner).run(txn: albumTestTxn, position: 2), .deleted)
        XCTAssertEqual(runner.scripts, [discoverOwnedSongGuardScript(hex: hex, live: [a4OtherHex], delete: true)])
    }
}
