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

    /// Music.app answers "Unknown object type" (-1731) to a script variable
    /// named `active`, so the delete never ran on the first live play (G1,
    /// 2026-10-03). The variable must not use that name.
    func testTheEndScriptNamesNoVariableActive() {
        for delete in [true, false] {
            let script = discoverCopyEndScript(hex: hex, delete: delete)
            XCTAssertNil(script.range(of: #"\bactive\b"#, options: .regularExpression), script)
        }
    }

    func testTheDeleteComesAfterTheGoneAndSparedChecks() throws {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        let gone = try XCTUnwrap(script.range(of: "if pl is missing value then return \"gone\""))
        let unreadable = try XCTUnwrap(script.range(of:
            "if playerActive and not currentReadable then return \"spared\""))
        let spared = try XCTUnwrap(script.range(of:
            "if playerActive and currentID is \"\(hex)\" then return \"spared\""))
        let delete = try XCTUnwrap(script.range(of: "delete pl"))
        XCTAssertLessThan(gone.lowerBound, unreadable.lowerBound)
        XCTAssertLessThan(unreadable.lowerBound, spared.lowerBound)
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

    // MARK: The script's decision, walked line by line
    //
    // The script is never run here. `walk` is a small reader of exactly the
    // line forms `discoverCopyEndScript` emits; it fails the test on any line
    // it does not know, so the script cannot drift away from it unnoticed. It
    // is a model of AppleScript, not AppleScript.

    private struct Player {
        var state: String?          // nil = the read fails
        var current: String?        // nil = the read fails
        var copyPresent = true
        var deleteWorks = true
    }

    private func walk(_ script: String, _ player: Player) -> (answer: String?, deleted: Bool) {
        var player = player
        var deleted = false
        var vars: [String: String] = [:]
        let lookup = discoverCopyLookupPreamble(hex: hex)
        let lines = script.replacingOccurrences(of: lookup, with: "LOOKUP")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        func quoted(_ text: String) -> String? {
            guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
            return String(text.dropFirst().dropLast())
        }
        func value(_ expression: String) -> String?? {      // .some(nil) = the read fails
            if let literal = quoted(expression) { return literal }
            switch expression {
            case "true", "false": return expression
            case "(player state as text)": return .some(player.state)
            case "(persistent ID of current playlist) as text": return .some(player.current)
            default: return nil
            }
        }
        func holds(_ condition: String) -> Bool? {
            var all = true
            for term in condition.components(separatedBy: " and ") {
                let one: Bool
                if term == "pl is missing value" { one = vars["pl"] == nil }
                else if term.hasPrefix("not "), let v = vars[String(term.dropFirst(4))] { one = v == "false" }
                else if let r = term.range(of: " is "), let v = vars[String(term[..<r.lowerBound])],
                        let literal = quoted(String(term[r.upperBound...])) { one = v == literal }
                else if let v = vars[term], v == "true" || v == "false" { one = v == "true" }
                else { return nil }
                all = all && one
            }
            return all
        }
        /// Runs one simple statement. Returns an answer when it is a `return`.
        func statement(_ line: String) -> (answer: String?, failed: Bool)? {
            if line == "delete pl" {
                deleted = true
                if player.deleteWorks { player.copyPresent = false }
                return (nil, false)
            }
            if line.hasPrefix("return "), let word = quoted(String(line.dropFirst(7))) { return (word, false) }
            if line.hasPrefix("set "), let r = line.range(of: " to ") {
                let name = String(line[line.index(line.startIndex, offsetBy: 4)..<r.lowerBound])
                guard let got = value(String(line[r.upperBound...])) else { return nil }
                guard let text = got else { return (nil, true) }
                vars[name] = text
                return (nil, false)
            }
            return nil
        }

        var inTry = false
        var skipping = false
        for line in lines {
            if line == "LOOKUP" { vars["pl"] = player.copyPresent ? "found" : nil; continue }
            if line == "try" { inTry = true; skipping = false; continue }
            if line == "end try" { inTry = false; skipping = false; continue }
            if skipping { continue }
            var body = line
            if line.hasPrefix("if "), let r = line.range(of: " then ") {
                guard let yes = holds(String(line[line.index(line.startIndex, offsetBy: 3)..<r.lowerBound])) else {
                    XCTFail("unknown condition: \(line)"); return (nil, deleted)
                }
                if !yes { continue }
                body = String(line[r.upperBound...])
            }
            guard let done = statement(body) else { XCTFail("unknown line: \(line)"); return (nil, deleted) }
            if done.failed {
                guard inTry else { XCTFail("a read failed outside a try: \(line)"); return (nil, deleted) }
                skipping = true
                continue
            }
            if let answer = done.answer { return (answer, deleted) }
        }
        XCTFail("the script ended without an answer")
        return (nil, deleted)
    }

    private let otherID = "FFEEDDCC00112233"

    func testActiveWithAnUnreadableCurrentPlaylistIsSparedAndNothingIsDeleted() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        for state in ["playing", "paused", "fast forwarding", "rewinding", nil] as [String?] {
            for current in [nil, "", "missing value"] as [String?] {
                let result = walk(script, Player(state: state, current: current))
                XCTAssertEqual(result.answer, "spared", "\(String(describing: state)) / \(String(describing: current))")
                XCTAssertFalse(result.deleted, "the delete command is never reached")
            }
        }
    }

    func testStoppedWithAnUnreadableCurrentPlaylistDeletes() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        for current in [nil, "", "missing value"] as [String?] {
            let result = walk(script, Player(state: "stopped", current: current))
            XCTAssertEqual(result.answer, "deleted")
            XCTAssertTrue(result.deleted)
        }
    }

    func testActiveInAnotherPlaylistDeletes() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        for state in ["playing", "paused"] {
            let result = walk(script, Player(state: state, current: otherID))
            XCTAssertEqual(result.answer, "deleted", state)
            XCTAssertTrue(result.deleted, state)
        }
    }

    func testTheRestOfTheDecisionTable() {
        let script = discoverCopyEndScript(hex: hex, delete: true)
        var result = walk(script, Player(state: "playing", current: hex))
        XCTAssertEqual(result.answer, "spared"); XCTAssertFalse(result.deleted)
        result = walk(script, Player(state: nil, current: hex))
        XCTAssertEqual(result.answer, "spared", "an unreadable state counts as active"); XCTAssertFalse(result.deleted)
        result = walk(script, Player(state: "stopped", current: hex))
        XCTAssertEqual(result.answer, "deleted"); XCTAssertTrue(result.deleted)
        result = walk(script, Player(state: "stopped", current: nil, copyPresent: false))
        XCTAssertEqual(result.answer, "gone"); XCTAssertFalse(result.deleted)
        result = walk(script, Player(state: "stopped", current: nil, deleteWorks: false))
        XCTAssertEqual(result.answer, "still"); XCTAssertTrue(result.deleted)

        let keeping = discoverCopyEndScript(hex: hex, delete: false)
        result = walk(keeping, Player(state: "stopped", current: nil))
        XCTAssertEqual(result.answer, "kept"); XCTAssertFalse(result.deleted)
        result = walk(keeping, Player(state: "playing", current: nil))
        XCTAssertEqual(result.answer, "spared"); XCTAssertFalse(result.deleted)
        result = walk(keeping, Player(state: "playing", current: otherID))
        XCTAssertEqual(result.answer, "kept"); XCTAssertFalse(result.deleted)
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

    func testHandleEndSparedReadoptsAndOffersTheRecord() {
        let (journal, runner, _) = rig(.listening, hex: hex, answers: ["spared"])
        let result = handle(journal, runner)
        XCTAssertEqual(result.readopted, ["A:\(hex)"])
        XCTAssertEqual(result.restored, ["A"], "offered; the guarded restore holds while the copy plays")
        XCTAssertEqual(journal.stored, [entry(.listening, hex: hex)])
    }

    func testHandleEndOffersTheRecordWhateverTheDeleteAnswered() {
        let cases: [(DiscoverCopyState, String?, DiscoverCopyDeleteResult)] = [
            (.listening, "deleted", .deleted), (.listening, "gone", .alreadyGone), (.listening, "spared", .spared),
            (.preexisting, "kept", .kept), (.listening, nil, .failed), (.listening, "still", .failed),
        ]
        for (state, answer, expected) in cases {
            let (journal, runner, _) = rig(state, hex: hex, answers: [answer])
            var order: [String] = []
            discoverCopyHandleEnd(txn: "A", deleter: DiscoverCopyDeleter(journal: journal, run: { script in
                                      order.append("script")
                                      return runner.run(script)
                                  }),
                                  journal: journal,
                                  restoreModes: { order.append("restore:\($0)") },
                                  readopt: { _, _ in })
            XCTAssertEqual(order, ["script", "restore:A"], "\(expected): the delete first, then one offer")
        }
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

    func testHandleEndFailedOffersTheRecordAndChangesNothingElse() {
        for answer in [nil, "still"] as [String?] {
            let (journal, runner, _) = rig(.listening, hex: hex, answers: [answer])
            let result = handle(journal, runner)
            XCTAssertEqual(result.restored, ["A"])
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
