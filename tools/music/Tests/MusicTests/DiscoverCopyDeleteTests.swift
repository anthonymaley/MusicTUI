import XCTest
@testable import music

/// Score step C5, section 9 item 5: the one place a copy is deleted. Every
/// script goes to a recording fake; nothing here reaches Music.app.
final class DiscoverCopyDeleteTests: XCTestCase {
    private let hex = "00112233AABBCCDD"
    private let title = "Morning Mix Zebra"

    private func entry(_ state: DiscoverCopyState, hex: String?, watching: Bool = true,
                       txn: String = "A") -> DiscoverCopyEntry {
        DiscoverCopyEntry(txn: txn, playlistID: "pl.one", title: title, state: state, hex: hex,
                          copiesRead: 0, watching: watching, copySeen: false, toldAtLaunch: false,
                          priorShuffle: true, priorRepeat: "all", createdAt: 1, updatedAt: 1)
    }

    /// A script runner that records every script and answers from a queue
    /// (the last answer repeats).
    private final class Runner {
        var answers: [String?]
        private(set) var scripts: [String] = []
        init(_ answers: [String?]) { self.answers = answers }
        var run: ScriptRunner {
            return { [self] script in
                scripts.append(script)
                return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
            }
        }
    }

    private func rig(_ state: DiscoverCopyState, hex: String?, answers: [String?])
        -> (InMemoryDiscoverCopyJournalStore, Runner, DiscoverCopyDeleter) {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [entry(state, hex: hex)])
        let runner = Runner(answers)
        return (journal, runner, DiscoverCopyDeleter(journal: journal, run: runner.run))
    }

    private func writes(_ journal: InMemoryDiscoverCopyJournalStore) -> [String] {
        journal.events.filter { $0 != "entries" }
    }

    // MARK: The script text

    func testTheDeletingScriptHoldsTheHexThePreambleAndNoName() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        let preamble = discoverCopyLookupPreamble(hex: hex)
        XCTAssertTrue(script.hasPrefix(preamble), "the lookup comes first")
        XCTAssertEqual(script.components(separatedBy: preamble).count - 1, 2,
                       "looked up before the delete and again after it")
        XCTAssertTrue(script.contains("\"\(hex)\""))
        XCTAssertFalse(script.contains(title))
        XCTAssertFalse(script.contains("name of"), "no name is read or matched")
        XCTAssertFalse(script.contains("whose"))
        let commands = script.replacingOccurrences(of: "return \"deleted\"", with: "")
        XCTAssertEqual(commands.components(separatedBy: "delete").count - 1, 1, "exactly one delete")
        XCTAssertTrue(script.contains("delete pl"))
    }

    func testTheDeleteComesAfterTheGoneAndSparedChecks() throws {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        let gone = try XCTUnwrap(script.range(of: "if pl is missing value then return \"gone\""))
        let spared = try XCTUnwrap(script.range(of:
            "if currentID is \"\(hex)\" and stateText is not \"stopped\" then return \"spared\""))
        let delete = try XCTUnwrap(script.range(of: "delete pl"))
        XCTAssertLessThan(gone.lowerBound, spared.lowerBound)
        XCTAssertLessThan(spared.upperBound, delete.lowerBound)
        XCTAssertTrue(script.hasSuffix("if pl is missing value then return \"deleted\"\nreturn \"still\""))
    }

    func testAnUnreadableStateCountsAsActive() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        XCTAssertTrue(script.contains("set stateText to \"\(unreadablePlayerStateFallback)\""))
        XCTAssertNotEqual(unreadablePlayerStateFallback, "stopped")
    }

    func testThePreexistingScriptHasNoDeleteInIt() {
        let script = discoverCopyEndScript(hex: hex, delete: false)
        XCTAssertFalse(script.contains("delete"))
        XCTAssertTrue(script.hasPrefix(discoverCopyLookupPreamble(hex: hex)))
        XCTAssertTrue(script.hasSuffix("return \"kept\""))
        XCTAssertFalse(script.contains(title))
    }

    // MARK: Which entries run a script at all

    func testIntentUncertainAndClosedRunNoScript() {
        for state in [DiscoverCopyState.intent, .uncertain, .closed] {
            let (journal, runner, deleter) = rig(state, hex: hex, answers: ["deleted"])
            XCTAssertEqual(deleter.end(txn: "A"), .kept, "\(state)")
            XCTAssertEqual(runner.scripts, [], "\(state)")
            XCTAssertEqual(journal.stored, [entry(state, hex: hex)], "\(state)")
            XCTAssertEqual(writes(journal), [], "\(state)")
        }
    }

    func testNoHexRunsNoScript() {
        for state in [DiscoverCopyState.owned, .listening, .preexisting] {
            let (journal, runner, deleter) = rig(state, hex: nil, answers: ["deleted"])
            XCTAssertEqual(deleter.end(txn: "A"), .kept, "\(state)")
            XCTAssertEqual(runner.scripts, [], "\(state)")
            XCTAssertEqual(writes(journal), [], "\(state)")
        }
    }

    func testAHexOfTheWrongShapeRunsNoScript() {
        for bad in ["", "00112233aabbccdd", "00112233AABBCCD", "00112233AABBCCDD0", "\" & (name of pl) & \""] {
            let (journal, runner, deleter) = rig(.listening, hex: bad, answers: ["gone"])
            XCTAssertEqual(deleter.end(txn: "A"), .kept, bad)
            XCTAssertEqual(runner.scripts, [], bad)
            XCTAssertEqual(journal.stored[0].state, .listening, bad)
        }
    }

    func testAnUnknownTxnRunsNoScript() {
        let (journal, runner, deleter) = rig(.listening, hex: hex, answers: ["deleted"])
        XCTAssertEqual(deleter.end(txn: "nobody"), .kept)
        XCTAssertEqual(runner.scripts, [])
        XCTAssertEqual(writes(journal), [])
    }

    func testAnUnreadableJournalRunsNoScript() {
        final class Unreadable: DiscoverCopyJournalStore {
            func entries() throws -> [DiscoverCopyEntry] { throw DiscoverCopyJournalError.unreadable }
            func insert(_ entry: DiscoverCopyEntry) throws { XCTFail("no write") }
            func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
                XCTFail("no write")
                throw DiscoverCopyJournalError.unreadable
            }
        }
        let runner = Runner(["deleted"])
        let deleter = DiscoverCopyDeleter(journal: Unreadable(), run: runner.run)
        XCTAssertEqual(deleter.end(txn: "A"), .failed)
        XCTAssertEqual(runner.scripts, [])
    }

    // MARK: Owned and listening

    func testOwnedAndListeningRunTheDeletingScriptAndCloseOnDeleted() {
        for state in [DiscoverCopyState.owned, .listening] {
            let (journal, runner, deleter) = rig(state, hex: hex, answers: ["deleted"])
            XCTAssertEqual(deleter.end(txn: "A"), .deleted, "\(state)")
            XCTAssertEqual(runner.scripts, [discoverCopyEndScript(hex: hex, delete: true)], "\(state)")
            XCTAssertEqual(journal.stored[0].state, .closed, "\(state)")
            XCTAssertFalse(journal.stored[0].watching, "\(state)")
            XCTAssertEqual(writes(journal), ["update:A"], "\(state)")
        }
    }

    func testSparedWhenCurrentAndNotStoppedLeavesTheEntryAlone() {
        let (journal, runner, deleter) = rig(.listening, hex: hex, answers: ["spared"])
        XCTAssertEqual(deleter.end(txn: "A"), .spared)
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertEqual(journal.stored, [entry(.listening, hex: hex)])
        XCTAssertEqual(writes(journal), [])
    }

    func testGoneTwiceInARowIsTwoAlreadyGone() {
        let (journal, runner, deleter) = rig(.listening, hex: hex, answers: ["gone"])
        XCTAssertEqual(deleter.end(txn: "A"), .alreadyGone)
        XCTAssertEqual(journal.stored[0].state, .closed)
        XCTAssertFalse(journal.stored[0].watching)
        XCTAssertEqual(runner.scripts.count, 1)

        // Closed now: the second end runs no script and still deletes nothing.
        XCTAssertEqual(deleter.end(txn: "A"), .kept)
        XCTAssertEqual(runner.scripts.count, 1)

        // Two ends that both find it gone while the entry is still open (the
        // closing write failed in between) are two `.alreadyGone`.
        let (stuck, again, second) = rig(.listening, hex: hex, answers: ["gone"])
        stuck.failWrites = { $0 == "update:A:closed" }
        XCTAssertEqual(second.end(txn: "A"), .alreadyGone)
        XCTAssertEqual(second.end(txn: "A"), .alreadyGone)
        XCTAssertEqual(again.scripts.count, 2)
        XCTAssertEqual(stuck.stored[0].state, .listening)
    }

    func testStillPresentAfterTheDeleteIsFailedAndTheEntryIsUnchanged() {
        let (journal, _, deleter) = rig(.listening, hex: hex, answers: ["still"])
        XCTAssertEqual(deleter.end(txn: "A"), .failed)
        XCTAssertEqual(journal.stored, [entry(.listening, hex: hex)])
        XCTAssertEqual(writes(journal), [])
    }

    func testAFailedScriptIsFailedAndTheEntryIsUnchanged() {
        for answer in [nil, "", "error", "kept", "DELETED?"] as [String?] {
            let (journal, _, deleter) = rig(.owned, hex: hex, answers: [answer])
            XCTAssertEqual(deleter.end(txn: "A"), .failed, "\(String(describing: answer))")
            XCTAssertEqual(journal.stored, [entry(.owned, hex: hex)])
            XCTAssertEqual(writes(journal), [])
        }
    }

    func testTheEntryClosesOnlyOnDeletedOrGone() {
        let closing: [String?: Bool] = ["deleted": true, "gone": true, "spared": false,
                                        "still": false, "kept": false, nil: false]
        for (answer, closes) in closing {
            let (journal, _, deleter) = rig(.listening, hex: hex, answers: [answer])
            _ = deleter.end(txn: "A")
            XCTAssertEqual(journal.stored[0].state == .closed, closes, "\(String(describing: answer))")
            XCTAssertEqual(journal.stored[0].watching, !closes, "\(String(describing: answer))")
        }
    }

    // MARK: Preexisting

    func testPreexistingRunsAScriptWithNoDeleteAndIsKept() {
        let (journal, runner, deleter) = rig(.preexisting, hex: hex, answers: ["kept"])
        XCTAssertEqual(deleter.end(txn: "A"), .kept)
        XCTAssertEqual(runner.scripts, [discoverCopyEndScript(hex: hex, delete: false)])
        XCTAssertFalse(runner.scripts[0].contains("delete"))
        XCTAssertEqual(journal.stored, [entry(.preexisting, hex: hex)], "the deleter leaves it; the handler closes it")
    }

    func testPreexistingAnsweringDeletedIsNotBelieved() {
        let (journal, _, deleter) = rig(.preexisting, hex: hex, answers: ["deleted"])
        XCTAssertEqual(deleter.end(txn: "A"), .failed)
        XCTAssertEqual(journal.stored, [entry(.preexisting, hex: hex)])
    }

    func testPreexistingGoneClosesAndSparedDoesNot() {
        let (gone, _, first) = rig(.preexisting, hex: hex, answers: ["gone"])
        XCTAssertEqual(first.end(txn: "A"), .alreadyGone)
        XCTAssertEqual(gone.stored[0].state, .closed)
        let (spared, _, second) = rig(.preexisting, hex: hex, answers: ["spared"])
        XCTAssertEqual(second.end(txn: "A"), .spared)
        XCTAssertEqual(spared.stored[0].state, .preexisting)
    }

    // MARK: discoverCopyHandleEnd

    private func handle(_ journal: InMemoryDiscoverCopyJournalStore, _ runner: Runner)
        -> (restored: [String], readopted: [String]) {
        var restored: [String] = []
        var readopted: [String] = []
        discoverCopyHandleEnd(txn: "A", deleter: DiscoverCopyDeleter(journal: journal, run: runner.run),
                              journal: journal,
                              restoreModes: { restored.append($0) },
                              readopt: { readopted.append("\($0):\($1)") })
        return (restored, readopted)
    }

    func testHandleEndSparedReadoptsAndRestoresNothing() {
        let (journal, runner, _) = rig(.listening, hex: hex, answers: ["spared"])
        let result = handle(journal, runner)
        XCTAssertEqual(result.readopted, ["A:\(hex)"])
        XCTAssertEqual(result.restored, [])
        XCTAssertEqual(journal.stored, [entry(.listening, hex: hex)])
    }

    func testHandleEndDeletedRestoresAndCloses() {
        let (journal, runner, _) = rig(.listening, hex: hex, answers: ["deleted"])
        let result = handle(journal, runner)
        XCTAssertEqual(result.restored, ["A"])
        XCTAssertEqual(result.readopted, [])
        XCTAssertEqual(journal.stored[0].state, .closed)
        XCTAssertFalse(journal.stored[0].watching)
    }

    func testHandleEndAlreadyGoneRestoresAndCloses() {
        let (journal, runner, _) = rig(.owned, hex: hex, answers: ["gone"])
        let result = handle(journal, runner)
        XCTAssertEqual(result.restored, ["A"])
        XCTAssertEqual(journal.stored[0].state, .closed)
        XCTAssertFalse(journal.stored[0].watching)
    }

    func testHandleEndPreexistingKeptRestoresAndClosesWithoutDeleting() {
        let (journal, runner, _) = rig(.preexisting, hex: hex, answers: ["kept"])
        let result = handle(journal, runner)
        XCTAssertEqual(result.restored, ["A"])
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertFalse(runner.scripts[0].contains("delete"))
        XCTAssertEqual(journal.stored[0].state, .closed)
        XCTAssertFalse(journal.stored[0].watching)
        XCTAssertEqual(journal.stored[0].hex, hex)
    }

    func testHandleEndUncertainStopsWatchingAndStaysUncertain() {
        let (journal, runner, _) = rig(.uncertain, hex: hex, answers: ["deleted"])
        let result = handle(journal, runner)
        XCTAssertEqual(runner.scripts, [])
        XCTAssertEqual(result.restored, ["A"])
        XCTAssertEqual(journal.stored[0].state, .uncertain)
        XCTAssertFalse(journal.stored[0].watching)
    }

    func testHandleEndFailedDoesNothing() {
        for answer in [nil, "still"] as [String?] {
            let (journal, runner, _) = rig(.listening, hex: hex, answers: [answer])
            let result = handle(journal, runner)
            XCTAssertEqual(result.restored, [])
            XCTAssertEqual(result.readopted, [])
            XCTAssertEqual(journal.stored, [entry(.listening, hex: hex)], "the journal keeps it for reconcile")
            XCTAssertEqual(writes(journal), [])
        }
    }

    func testAnEndHandledForAnEntryAlreadyClosedRunsNoScript() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [entry(.closed, hex: hex, watching: false)])
        let runner = Runner(["deleted"])
        let result = handle(journal, runner)
        XCTAssertEqual(runner.scripts, [])
        XCTAssertEqual(result.readopted, [])
        XCTAssertEqual(journal.stored, [entry(.closed, hex: hex, watching: false)])
        XCTAssertEqual(writes(journal), [], "nothing is written for an entry already closed and unwatched")
    }
}
