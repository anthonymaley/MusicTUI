import XCTest
@testable import music

// Album-cleanup score step A5: the album reconcile (design 4.7, tests 15 and
// 16; CH17) and the F-script. Fakes only; no script is ever run.
final class DiscoverAlbumReconcileTests: XCTestCase {

    /// The reconciler over an `A5Rig`, with every outside read scripted and recorded.
    private final class Harness {
        let rig: A5Rig
        let relations = FakeLibraryRelations()
        var selected = true
        var found: [String]?? = .some([])          // .none = never scripted: answer []
        var entryIDs: [String]?
        var deleteResult: DiscoverCopyDeleteResult = .deleted
        /// When set, `deleteIfOwned` is the REAL deleter over this runner.
        var runner: A5Runner?
        private(set) var findCalls: [String] = []
        private(set) var entryIDCalls: [String] = []
        private(set) var deleteCalls: [String] = []
        private(set) var adopts: [String] = []
        private(set) var proofs: [String] = []
        private(set) var reconciler: DiscoverAlbumReconciler!

        init(_ entries: [DiscoverCopyEntry]) {
            rig = A5Rig(entries)
            reconciler = DiscoverAlbumReconciler(seams: .init(
                journal: rig.journal, beforeSet: rig.beforeSet,
                relations: { [unowned self] in relations },
                findContainers: { [unowned self] name in
                    findCalls.append(name)
                    return found ?? []
                },
                readEntryIDs: { [unowned self] hex in
                    entryIDCalls.append(hex)
                    return entryIDs
                },
                deleteIfOwned: { [unowned self] txn in
                    deleteCalls.append(txn)
                    if let runner {
                        return DiscoverCopyDeleter(journal: rig.journal, run: runner.run).end(txn: txn)
                    }
                    if deleteResult == .deleted || deleteResult == .alreadyGone {
                        // What the real deleter records for an album entry (CH6).
                        _ = try? rig.journal.update(txn: txn) { entry in
                            entry.containerGone = true
                            entry.watching = false
                        }
                    }
                    return deleteResult
                },
                adopt: { [unowned self] txn, hex in adopts.append("\(txn):\(hex)") },
                startProof: { [unowned self] txn in proofs.append(txn) },
                cleaner: rig.cleaner,
                spandacDataSelected: { [unowned self] in selected },
                post: { [unowned self] in rig.posts.post($0) },
                now: { [unowned self] in rig.clock.now },
                log: { _ in }))
        }

        func replay(atLaunch: Bool, txn: String = albumTestTxn) {
            guard let entry = rig.entry(txn) else { return XCTFail("no entry \(txn)") }
            reconciler.replay(entry, atLaunch: atLaunch)
        }

        var writes: [String] { rig.journal.events.filter { $0 != "entries" } }
    }

    private var sentAt: Double { A5Clock().now.timeIntervalSince1970 - 10 }

    /// An `intent` entry whose ensure was sent: its songs are `pending` (CH22).
    private func sentEntry(songs: [DiscoverAlbumSong]? = nil, state: DiscoverCopyState = .intent,
                           reason: String? = nil) -> DiscoverCopyEntry {
        var entry = albumTestEntry(state: state, songs: songs, songState: .pending)
        entry.writeSentAt = sentAt
        entry.uncertainReason = reason
        return entry
    }

    private func playedEntry(songs: [DiscoverAlbumSong], state: DiscoverCopyState = .listening,
                             containerGone: Bool? = nil, writeSentAt: Double? = nil) -> DiscoverCopyEntry {
        var entry = albumTestEntry(state: state, hex: a5Hex, songs: songs, watching: state == .listening,
                                   containerGone: containerGone)
        entry.writeSentAt = writeSentAt ?? sentAt
        return entry
    }

    private func leftLine(_ titles: [String]) -> DiscoverToast {
        .outcome(.refused(discoverAlbumLeftText(titles: titles, album: albumTestAlbum)), title: albumTestAlbum)
    }

    private let both = [true, false]

    // MARK: closed, and intent with nothing sent

    func testAClosedEntryIsLeftAlone() {
        for atLaunch in both {
            var entry = albumTestEntry(state: .closed, songs: [albumTestSong(1, state: .uncertain)])
            entry.writeSentAt = sentAt
            let h = Harness([entry])
            h.replay(atLaunch: atLaunch)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertTrue(h.rig.posts.toasts.isEmpty)
            XCTAssertTrue(h.findCalls.isEmpty && h.deleteCalls.isEmpty && h.relations.calls.isEmpty)
            XCTAssertTrue(h.rig.beforeSet.calls.isEmpty)
        }
    }

    func testAnIntentWithNothingSentClosesAndDeletesTheSideFile() {
        for atLaunch in both {
            let h = Harness([albumTestEntry(state: .intent)])
            h.replay(atLaunch: atLaunch)
            XCTAssertEqual(h.rig.entry()?.state, .closed)
            XCTAssertEqual(h.rig.beforeSet.calls, ["delete:before-\(albumTestTxn).json"])
            XCTAssertTrue(h.findCalls.isEmpty, "nothing was sent, so nothing is looked for")
            XCTAssertTrue(h.rig.posts.toasts.isEmpty)
        }
    }

    // MARK: intent with writeSentAt (and uncertain from an unknown outcome)

    func testAnIntentWaitsWhileSpanDACDataIsNotSelected() {
        for atLaunch in both {
            let h = Harness([sentEntry()])
            h.selected = false
            h.replay(atLaunch: atLaunch)
            XCTAssertTrue(h.findCalls.isEmpty)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertEqual(h.rig.entry()?.state, .intent)
        }
    }

    func testAnUnreadableFindChangesNothing() {
        for atLaunch in both {
            let h = Harness([sentEntry()])
            h.found = .some(nil)
            h.replay(atLaunch: atLaunch)
            XCTAssertEqual(h.findCalls, [discoverPlaylistPrefix + albumTestTxn + discoverPlaylistNameSeparator + albumTestAlbum],
                           "the container is looked for by its exact name")
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertTrue(h.relations.calls.isEmpty)
            XCTAssertTrue(h.rig.posts.toasts.isEmpty)
        }
    }

    func testExactlyOneContainerMakesTheEntryOwnedAndReadsE() throws {
        for atLaunch in both {
            let h = Harness([sentEntry()])
            let ids = [albumTestHex(11), albumTestHex(12), albumTestHex(13)]
            h.found = .some([a5Hex])
            h.entryIDs = ids
            h.replay(atLaunch: atLaunch)
            let entry = try XCTUnwrap(h.rig.entry())
            XCTAssertEqual(entry.hex, a5Hex)
            XCTAssertNil(entry.uncertainReason)
            XCTAssertEqual(entry.entryIDs, ids)
            XCTAssertEqual(entry.songs?.compactMap(\.entryHex), ids)
            XCTAssertEqual(h.entryIDCalls, [a5Hex])
            XCTAssertEqual(h.deleteCalls, [albumTestTxn], "then the owned branch: the container first")
            XCTAssertEqual(entry.containerGone, true)
            XCTAssertEqual(entry.songs?.map(\.state), [.pending, .pending, .pending])
            XCTAssertEqual(h.proofs, [albumTestTxn], "the songs go on toward proof inside their window")
            XCTAssertTrue(h.relations.calls.isEmpty)
        }
    }

    func testOneContainerWithAnUnreadableELeavesEUnset() throws {
        let h = Harness([sentEntry()])
        h.found = .some([a5Hex])
        h.entryIDs = nil
        h.deleteResult = .spared
        h.replay(atLaunch: true)
        let entry = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(entry.state, .listening)
        XCTAssertEqual(entry.hex, a5Hex)
        XCTAssertNil(entry.entryIDs)
        XCTAssertEqual(entry.songs?.compactMap(\.entryHex), [])
        XCTAssertEqual(h.adopts, ["\(albumTestTxn):\(a5Hex)"])
    }

    func testOneContainerWhoseEDoesNotMatchTheSongsWritesNoEntryHex() throws {
        let h = Harness([sentEntry()])
        h.found = .some([a5Hex])
        h.entryIDs = [albumTestHex(11), albumTestHex(12)]
        h.replay(atLaunch: false)
        let entry = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(entry.entryIDs, [albumTestHex(11), albumTestHex(12)])
        XCTAssertEqual(entry.songs?.compactMap(\.entryHex), [])
    }

    func testTwoContainersMakeEveryUnfinishedSongUncertainAndTellHim() throws {
        let songs = [albumTestSong(1, state: .pending), albumTestSong(2, state: .preexisting),
                     albumTestSong(3, state: .pending)]
        for atLaunch in both {
            let h = Harness([sentEntry(songs: songs)])
            h.found = .some([a5Hex, albumTestHex(77)])
            h.replay(atLaunch: atLaunch)
            let entry = try XCTUnwrap(h.rig.entry())
            XCTAssertEqual(entry.state, atLaunch ? .closed : .uncertain,
                           "at launch every song is terminal and told, so CH9 closes it")
            XCTAssertEqual(entry.uncertainReason, "several")
            XCTAssertEqual(entry.songs?.map(\.state), [.uncertain, .preexisting, .uncertain])
            XCTAssertNil(entry.hex)
            XCTAssertTrue(h.relations.calls.isEmpty)
            XCTAssertTrue(h.deleteCalls.isEmpty)
            XCTAssertEqual(h.rig.posts.toasts, [leftLine(["Track 1", "Track 3"])], "told once, by name")
            XCTAssertEqual(entry.songs?.map(\.toldAtLaunch), [atLaunch, false, atLaunch])
        }
    }

    func testNoContainerAndNoRelationCloses() {
        for atLaunch in both {
            let songs = [albumTestSong(1, state: .pending), albumTestSong(2, state: .preexisting)]
            let h = Harness([sentEntry(songs: songs)])
            h.found = .some([])
            h.replay(atLaunch: atLaunch)
            XCTAssertEqual(h.relations.calls, [[albumTestCatalogueID(1)]],
                           "one read, of the songs that could have been added")
            XCTAssertEqual(h.rig.entry()?.state, .closed)
            XCTAssertEqual(h.rig.beforeSet.calls, ["delete:before-\(albumTestTxn).json"])
            XCTAssertTrue(h.rig.posts.toasts.isEmpty)
        }
    }

    func testNoContainerButARelationMakesTheEntryUncertain() throws {
        let h = Harness([sentEntry()])
        h.found = .some([])
        h.relations.results = [.success([albumTestCatalogueID(1): [], albumTestCatalogueID(2): [nil],
                                         albumTestCatalogueID(3): []])]
        h.replay(atLaunch: false)
        let entry = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(entry.state, .uncertain)
        XCTAssertEqual(entry.uncertainReason, "not_created")
        XCTAssertEqual(entry.songs?.map(\.state), [.uncertain, .uncertain, .uncertain])
        XCTAssertEqual(h.rig.posts.toasts, [leftLine(["Track 1", "Track 2", "Track 3"])])
        XCTAssertTrue(h.rig.beforeSet.calls.isEmpty)
    }

    func testAnUnreadableRelationsReadChangesNothing() {
        let unreadable: [Result<[String: [String?]], Error>] = [
            .failure(SpanDACLibraryOpError.failed("upstream")),
            .failure(SpanDACLibraryOpError.notOffered),
            .success([albumTestCatalogueID(1): []]),        // two ids missing from the reply
        ]
        for result in unreadable {
            for atLaunch in both {
                let h = Harness([sentEntry()])
                h.found = .some([])
                h.relations.results = [result]
                h.replay(atLaunch: atLaunch)
                XCTAssertTrue(h.writes.isEmpty, "\(result)")
                XCTAssertTrue(h.rig.posts.toasts.isEmpty)
                XCTAssertTrue(h.rig.beforeSet.calls.isEmpty)
            }
        }
    }

    func testAnUnknownOutcomeIsResolvedTheSameWay() throws {
        let h = Harness([sentEntry(state: .uncertain, reason: "outcome_unknown")])
        h.found = .some([a5Hex])
        h.entryIDs = [albumTestHex(11), albumTestHex(12), albumTestHex(13)]
        h.replay(atLaunch: true)
        let entry = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(entry.state, .owned)
        XCTAssertNil(entry.uncertainReason)
        XCTAssertEqual(entry.containerGone, true)
    }

    // MARK: owned / listening

    func testASparedContainerIsReadoptedAndNoSongGoesFurther() throws {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)]
        for atLaunch in both {
            let h = Harness([playedEntry(songs: songs, state: .owned)])
            h.deleteResult = .spared
            h.replay(atLaunch: atLaunch)
            let entry = try XCTUnwrap(h.rig.entry())
            XCTAssertEqual(entry.state, .listening)
            XCTAssertTrue(entry.watching)
            XCTAssertEqual(h.adopts, ["\(albumTestTxn):\(a5Hex)"])
            XCTAssertEqual(h.rig.queue.count, 0)
            XCTAssertTrue(h.proofs.isEmpty)
        }
    }

    func testAFailedContainerDeleteStops() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)]
        let h = Harness([playedEntry(songs: songs)])
        h.deleteResult = .failed
        h.replay(atLaunch: true)
        XCTAssertEqual(h.rig.queue.count, 0)
        XCTAssertTrue(h.proofs.isEmpty)
        XCTAssertTrue(h.adopts.isEmpty)
        XCTAssertTrue(h.writes.isEmpty)
    }

    func testOwnedSongsAreEnqueuedAndNoGuardRunsInline() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .preexisting),
                     albumTestSong(3, state: .owned)]
        for atLaunch in both {
            let h = Harness([playedEntry(songs: songs)])
            h.replay(atLaunch: atLaunch)
            XCTAssertEqual(h.deleteCalls, [albumTestTxn])
            XCTAssertEqual(h.rig.queue.count, 2)
            XCTAssertTrue(h.rig.songGuard.asked.isEmpty, "only enqueued items run the guard")
            h.rig.queue.drain()
            XCTAssertEqual(h.rig.songGuard.calls, [1, 3])
            XCTAssertEqual(h.rig.songStates(), [.deleted, .preexisting, .deleted])
        }
    }

    func testAContainerAlreadyRecordedGoneIsNotAskedAgain() {
        let h = Harness([playedEntry(songs: [albumTestSong(1, state: .owned)], containerGone: true)])
        h.replay(atLaunch: false)
        XCTAssertTrue(h.deleteCalls.isEmpty)
        XCTAssertEqual(h.rig.queue.count, 1)
    }

    func testPendingSongsPastTheirWindowBecomeUncertainAndAreToldAtLaunch() throws {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending),
                     albumTestSong(3, state: .pending)]
        let h = Harness([playedEntry(songs: songs, writeSentAt: A5Clock().now.timeIntervalSince1970 - 181)])
        h.replay(atLaunch: true)
        let entry = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(entry.songs?.map(\.state), [.owned, .uncertain, .uncertain])
        XCTAssertTrue(h.proofs.isEmpty)
        XCTAssertEqual(h.rig.posts.toasts, [leftLine(["Track 2", "Track 3"])], "one line for the entry")
        XCTAssertEqual(entry.songs?.map(\.toldAtLaunch), [false, true, true])
    }

    func testPendingSongsInsideTheirWindowGoToTheProofCollector() throws {
        let songs = [albumTestSong(1, state: .pending)]
        let h = Harness([playedEntry(songs: songs, writeSentAt: A5Clock().now.timeIntervalSince1970 - 180)])
        h.replay(atLaunch: false)
        XCTAssertEqual(h.rig.entry()?.songs?.map(\.state), [.pending])
        XCTAssertEqual(h.proofs, [albumTestTxn])
    }

    func testAPendingSongBeforeAPlayIsNotToldUntilTheEnd() {
        let songs = [albumTestSong(1, state: .pending), albumTestSong(2, state: .owned)]
        let h = Harness([playedEntry(songs: songs, writeSentAt: A5Clock().now.timeIntervalSince1970 - 500)])
        h.replay(atLaunch: false)
        XCTAssertEqual(h.rig.songStates(), [.uncertain, .owned])
        XCTAssertTrue(h.rig.posts.toasts.isEmpty, "the end line tells him once the songs are finished")
        h.rig.queue.drain()
        XCTAssertEqual(h.rig.posts.toasts, [.outcome(.refused(discoverAlbumLeftText(titles: ["Track 1"], album: albumTestAlbum)),
                                                     title: albumTestAlbum)])
    }

    // MARK: Design test 16: the launch sweep went first

    func testAContainerTheLaunchSweepDeletedReadsGoneAndTheSongsProceedOnE() throws {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .owned)]
        var entry = playedEntry(songs: songs)
        entry.entryIDs = [albumTestHex(1), albumTestHex(2)]
        let h = Harness([entry])
        h.runner = A5Runner(["gone"])
        h.replay(atLaunch: true)
        XCTAssertEqual(h.runner?.scripts.count, 1, "the container script, and nothing else inline")
        let after = try XCTUnwrap(h.rig.entry())
        XCTAssertEqual(after.containerGone, true)
        XCTAssertEqual(after.state, .listening)
        XCTAssertEqual(after.songs?.compactMap(\.entryHex), [albumTestHex(1), albumTestHex(2)], "the recorded E")
        XCTAssertEqual(h.rig.queue.count, 2)
        h.rig.queue.drain()
        XCTAssertEqual(h.rig.songGuard.calls, [1, 2])
        XCTAssertEqual(h.rig.posts.toasts, [.progress(discoverAlbumAllRemovedText(album: albumTestAlbum))])
        XCTAssertEqual(h.rig.entry()?.state, .closed)
    }

    // MARK: uncertain for any other reason

    func testAnUncertainEntryMakesItsUnfinishedSongsUncertain() throws {
        let songs = [albumTestSong(1, state: .pending), albumTestSong(2, state: .preexisting),
                     albumTestSong(3, state: .intent)]
        var entry = albumTestEntry(state: .uncertain, songs: songs)
        entry.uncertainReason = "not_created"
        let h = Harness([entry])
        h.replay(atLaunch: false)
        XCTAssertEqual(h.rig.songStates(), [.uncertain, .preexisting, .uncertain])
        XCTAssertTrue(h.rig.posts.toasts.isEmpty, "before a play: told at the next launch")
        XCTAssertTrue(h.findCalls.isEmpty && h.relations.calls.isEmpty)
    }

    func testUncertainSongsAreToldExactlyOnceAtLaunch() throws {
        let songs = [albumTestSong(1, state: .uncertain), albumTestSong(2, state: .uncertain),
                     albumTestSong(3, state: .preexisting)]
        var entry = albumTestEntry(state: .uncertain, songs: songs)
        entry.uncertainReason = "several"
        let h = Harness([entry])
        h.replay(atLaunch: false)
        XCTAssertTrue(h.rig.posts.toasts.isEmpty, "not before a play")
        h.replay(atLaunch: true)
        XCTAssertEqual(h.rig.posts.toasts, [leftLine(["Track 1", "Track 2"])])
        XCTAssertEqual(h.rig.entry()?.state, .closed, "told, so CH9 lets it close")
        h.replay(atLaunch: true)
        XCTAssertEqual(h.rig.posts.toasts.count, 1)
    }

    func testAnAlreadyToldSongIsNotToldAgain() {
        var told = albumTestSong(1, state: .uncertain)
        told.toldAtLaunch = true
        let songs = [told, albumTestSong(2, state: .uncertain)]
        var entry = albumTestEntry(state: .uncertain, songs: songs)
        entry.uncertainReason = "several"
        let h = Harness([entry])
        h.replay(atLaunch: true)
        XCTAssertEqual(h.rig.posts.toasts, [leftLine(["Track 2"])])
    }

    func testACopyEntryIsNotTheAlbumBranchs() {
        let copy = DiscoverCopyEntry(txn: "C", playlistID: "pl.one", title: "Copy", state: .intent, hex: nil,
                                     copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                                     priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
        let h = Harness([copy])
        h.replay(atLaunch: true, txn: "C")
        XCTAssertTrue(h.writes.isEmpty)
    }

    // MARK: The F-script

    func testTheFindScriptPassesTheNameGate() {
        let script = discoverAlbumFindContainerScript(name: "__discover__ X — Y")
        let names = appleScriptAssignedNames(script)
        XCTAssertEqual(names, ["foundText", "userLists", "plRef", "plNameText"])
        XCTAssertTrue(names.isSubset(of: discoverAlbumScriptVariables))
        XCTAssertTrue(names.isDisjoint(with: discoverAppleScriptReservedNames))
    }

    func testTheFindScriptComparesCaseSensitivelyByExactName() throws {
        let name = discoverPlaylistPrefix + albumTestTxn + discoverPlaylistNameSeparator + albumTestAlbum
        let script = discoverAlbumFindContainerScript(name: name)
        let considering = try XCTUnwrap(script.range(of: "considering case"))
        let compare = try XCTUnwrap(script.range(of: "if plNameText is \"\(name)\" then"))
        let endConsidering = try XCTUnwrap(script.range(of: "end considering"))
        XCTAssertLessThan(considering.upperBound, compare.lowerBound)
        XCTAssertLessThan(compare.upperBound, endConsidering.lowerBound)
        XCTAssertFalse(script.contains("contains"), "exact equality, never a substring match")
        XCTAssertFalse(script.contains("delete"))
        XCTAssertTrue(script.hasSuffix("return \"ok\" & linefeed & foundText"))
    }

    func testTheFindScriptEscapesTheName() {
        let script = discoverAlbumFindContainerScript(name: #"__discover__ T — Say "Hi" \ Bye"#)
        XCTAssertTrue(script.contains(#"if plNameText is "__discover__ T — Say \"Hi\" \\ Bye" then"#), script)
    }

    func testTheFindScriptParser() {
        XCTAssertNil(parseDiscoverAlbumFoundContainers(nil))
        XCTAssertNil(parseDiscoverAlbumFoundContainers(""))
        XCTAssertNil(parseDiscoverAlbumFoundContainers("nope"))
        XCTAssertNil(parseDiscoverAlbumFoundContainers("OK\n\(a5Hex)"))
        XCTAssertNil(parseDiscoverAlbumFoundContainers("ok\n\(a5Hex.lowercased())\n"))
        XCTAssertNil(parseDiscoverAlbumFoundContainers("ok\n\(a5Hex)\nnot a hex\n"))
        XCTAssertNil(parseDiscoverAlbumFoundContainers("ok\n\(a5Hex)00\n"))
        XCTAssertEqual(parseDiscoverAlbumFoundContainers("ok"), [])
        XCTAssertEqual(parseDiscoverAlbumFoundContainers("ok\n"), [])
        XCTAssertEqual(parseDiscoverAlbumFoundContainers("ok\n\(a5Hex)\n"), [a5Hex])
        XCTAssertEqual(parseDiscoverAlbumFoundContainers("ok\r\n\(a5Hex)\r\n\(albumTestHex(9))\n"),
                       [a5Hex, albumTestHex(9)])
    }
}
