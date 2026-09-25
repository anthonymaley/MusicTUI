import XCTest
@testable import music

/// `music sync-plays`: what it prints and how it exits for every outcome of a
/// pass. The renderer is pure; the pass is always a stand-in here, so nothing
/// touches Music.app, Bridge or the real play-sync folder.
final class SyncPlaysOutputTests: XCTestCase {

    // MARK: Fixtures

    private func entry(_ title: String, _ artist: String, seq: Int = 1,
                       state: EntryState = .done, reason: String? = nil,
                       completedAt: Int = 1_790_300_187) -> PlaySyncEntry {
        PlaySyncEntry(
            ledgerID: "L", seq: seq, playID: "P\(seq)",
            alias: "596357614188841472", persistentID: "0846B01728D34A00",
            title: title, artist: artist, completedAt: completedAt,
            state: state, phase: .countAndDate,
            before: nil, target: nil, attempt: nil, observed: nil,
            barrierReplans: 0, reason: reason, reconciled: false, reported: false)
    }

    private func result(blocked: PlaySyncBlock? = nil,
                        fetch: PlaySyncFetchStatus = .ok(newPlays: 0),
                        musicRunning: Bool = true,
                        recorded: [PlaySyncEntry] = [],
                        outstanding: [PlaySyncEntry] = [],
                        unconfirmed: [PlaySyncEntry] = [],
                        waiting: Int = 0,
                        musicAccess: MusicAccessError? = nil) -> PlaySyncResult {
        PlaySyncResult(blocked: blocked, fetch: fetch, musicRunning: musicRunning,
                       recorded: recorded, newProblems: [], outstanding: outstanding,
                       unconfirmed: unconfirmed, waiting: waiting, musicAccess: musicAccess)
    }

    /// What the engine returns when the journal could not be read at the start.
    private func blockedAtStart(_ block: PlaySyncBlock) -> PlaySyncResult {
        PlaySyncResult(blocked: block, fetch: .skipped, musicRunning: false, recorded: [],
                       newProblems: [], outstanding: [], unconfirmed: [], waiting: 0)
    }

    // MARK: Recorded

    func testRecordedOne() {
        let out = renderSyncPlays(result(fetch: .ok(newPlays: 1),
                                         recorded: [entry("Teardrop", "Massive Attack")]), json: false)
        XCTAssertEqual(out.text, """
            Recorded 1 library play in Music.app.
              Teardrop — Massive Attack
            """)
        XCTAssertEqual(out.exit, 0)
    }

    func testRecordedThree() {
        let recorded = [entry("Teardrop", "Massive Attack", seq: 1),
                        entry("Angel", "Massive Attack", seq: 2),
                        entry("Roads", "Portishead", seq: 3)]
        let out = renderSyncPlays(result(fetch: .ok(newPlays: 3), recorded: recorded), json: false)
        XCTAssertEqual(out.text, """
            Recorded 3 library plays in Music.app.
              Teardrop — Massive Attack
              Angel — Massive Attack
              Roads — Portishead
            """)
        XCTAssertEqual(out.exit, 0)
    }

    // MARK: Nothing new

    func testNothingNew() {
        let out = renderSyncPlays(result(), json: false)
        XCTAssertEqual(out.text, "Nothing new to record.")
        XCTAssertEqual(out.exit, 0)
    }

    // MARK: Music.app not running

    func testWaitingOneWithMusicNotRunning() {
        let out = renderSyncPlays(result(fetch: .ok(newPlays: 1), musicRunning: false, waiting: 1), json: false)
        XCTAssertEqual(out.text,
                       "1 play waiting: Music.app is not running. Open Music.app and run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testWaitingSeveralWithMusicNotRunning() {
        let out = renderSyncPlays(result(fetch: .ok(newPlays: 4), musicRunning: false, waiting: 4), json: false)
        XCTAssertEqual(out.text,
                       "4 plays waiting: Music.app is not running. Open Music.app and run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testMusicNotRunningWithNothingWaitingIsNotAFailure() {
        let out = renderSyncPlays(result(musicRunning: false, waiting: 0), json: false)
        XCTAssertEqual(out.text, "Nothing new to record.")
        XCTAssertEqual(out.exit, 0)
    }

    // MARK: Music.app running but a read or write failed

    func testLibraryNotLoadedIsNotMiscastAsCouldNotBeAccessed() {
        let out = renderSyncPlays(
            result(musicRunning: true, waiting: 1,
                  musicAccess: .failed(MusicAccessSentence.libraryNotLoaded)),
            json: false)
        XCTAssertEqual(out.text,
                       "1 play waiting: Music.app's library hasn't finished loading. Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testNoMatchAtWriteTimeIsNotMiscastAsCouldNotBeAccessed() {
        let out = renderSyncPlays(
            result(musicRunning: true, waiting: 1,
                  musicAccess: .failed(MusicAccessSentence.noMatch)),
            json: false)
        XCTAssertEqual(out.text,
                       "1 play waiting: the track could not be found in Music.app when it came time to write. "
                       + "Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testEveryOtherFailedDetailKeepsTheCouldNotBeAccessedForm() {
        let out = renderSyncPlays(
            result(musicRunning: true, waiting: 1,
                  musicAccess: .failed("some other AppleEvent failure.")),
            json: false)
        XCTAssertEqual(out.text,
                       "1 play waiting: Music.app could not be accessed (some other AppleEvent failure). "
                       + "Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    // MARK: Unconfirmed

    func testUnconfirmedAreListedAndDoNotFail() {
        let unconfirmed = [entry("Teardrop", "Massive Attack", state: .unresolved),
                           entry("Roads", "Portishead", seq: 2, state: .unresolved)]
        let out = renderSyncPlays(result(unconfirmed: unconfirmed), json: false)
        XCTAssertEqual(out.text, """
            Nothing new to record.
            Waiting for Music.app to confirm (2):
              Teardrop — Massive Attack
              Roads — Portishead
              These, and later plays of the same songs, are checked again on every sync.
            """)
        XCTAssertEqual(out.exit, 0)
    }

    // MARK: Bridge

    func testBridgeNotRunning() {
        let out = renderSyncPlays(result(fetch: .bridgeNotRunning), json: false)
        XCTAssertEqual(out.text, "Bridge is not running, so no new plays could be read.")
        XCTAssertEqual(out.exit, 1)
    }

    func testBridgeTooOld() {
        let out = renderSyncPlays(result(fetch: .bridgeTooOld), json: false)
        XCTAssertEqual(out.text,
                       "Bridge is older than this MusicTUI and does not record plays — update Bridge.")
        XCTAssertEqual(out.exit, 1)
    }

    func testLedgerReplacedIsReportedButDoesNotFail() {
        let out = renderSyncPlays(result(fetch: .ledgerReplaced), json: false)
        XCTAssertEqual(out.text,
                       "Bridge's play record was replaced; plays it held before could not all be read.")
        XCTAssertEqual(out.exit, 0)
    }

    func testLedgerReplacedAlongsideRecordedPlays() {
        let out = renderSyncPlays(result(fetch: .ledgerReplaced,
                                         recorded: [entry("Teardrop", "Massive Attack")]), json: false)
        XCTAssertEqual(out.text, """
            Recorded 1 library play in Music.app.
              Teardrop — Massive Attack
            Bridge's play record was replaced; plays it held before could not all be read.
            """)
        XCTAssertEqual(out.exit, 0)
    }

    func testFetchFailureFails() {
        let out = renderSyncPlays(result(fetch: .failed("Bridge did not answer in time")), json: false)
        XCTAssertEqual(out.text, "No new plays could be read: Bridge did not answer in time.")
        XCTAssertEqual(out.exit, 1)
    }

    func testFetchFailureKeepsItsOwnFullStop() {
        let out = renderSyncPlays(
            result(fetch: .failed("Bridge's play record was replaced again while it was being read.")),
            json: false)
        XCTAssertEqual(out.text,
                       "No new plays could be read: Bridge's play record was replaced again while it was being read.")
        XCTAssertEqual(out.exit, 1)
    }

    // MARK: Blocked

    func testLockBusy() {
        let out = renderSyncPlays(blockedAtStart(.lockBusy), json: false)
        XCTAssertEqual(out.text, "Another sync is running; try again in a moment.")
        XCTAssertEqual(out.exit, 1)
    }

    func testJournalUnreadable() {
        let path = "/tmp/playsync/journal.json"
        let out = renderSyncPlays(blockedAtStart(.journalUnreadable(path: path)), json: false)
        XCTAssertEqual(out.text,
                       "The play-sync journal at \(path) could not be read; nothing was changed. "
                       + "Keep this file: it is what stops plays being counted twice.")
        XCTAssertTrue(out.text.contains("Keep this file"))
        XCTAssertFalse(out.text.lowercased().contains("move"))
        XCTAssertFalse(out.text.lowercased().contains("aside"))
        XCTAssertEqual(out.exit, 1)
    }

    /// The engine reports a journal that could not be SAVED mid-pass the same
    /// way; by then Music.app may already have been written to, so the command
    /// must never claim nothing was changed.
    func testJournalNotSavedAfterMusicWasReached() {
        let path = "/tmp/playsync/journal.json"
        var r = blockedAtStart(.journalUnreadable(path: path))
        r.fetch = .ok(newPlays: 2)
        r.musicRunning = true
        let out = renderSyncPlays(r, json: false)
        XCTAssertEqual(out.text,
                       "The play-sync journal at \(path) could not be saved, so the sync stopped; "
                       + "nothing more was changed. Keep this file: it is what stops plays being counted twice.")
        XCTAssertFalse(out.text.contains("nothing was changed"))
        XCTAssertFalse(out.text.lowercased().contains("move"))
        XCTAssertFalse(out.text.lowercased().contains("aside"))
        XCTAssertEqual(out.exit, 1)
    }

    func testJournalNotSavedAfterFetchOnly() {
        let path = "/tmp/playsync/journal.json"
        var r = blockedAtStart(.journalUnreadable(path: path))
        r.fetch = .bridgeNotRunning
        let out = renderSyncPlays(r, json: false)
        XCTAssertFalse(out.text.contains("nothing was changed"))
        XCTAssertTrue(out.text.contains("could not be saved"))
        XCTAssertEqual(out.exit, 1)
    }

    func testJournalNotSavedStillListsWhatWasRecorded() {
        let path = "/tmp/playsync/journal.json"
        var r = blockedAtStart(.journalUnreadable(path: path))
        r.fetch = .ok(newPlays: 1)
        r.musicRunning = true
        r.recorded = [entry("Teardrop", "Massive Attack")]
        let out = renderSyncPlays(r, json: false)
        XCTAssertEqual(out.text, """
            Recorded 1 library play in Music.app.
              Teardrop — Massive Attack
            The play-sync journal at \(path) could not be saved, so the sync stopped; \
            nothing more was changed. Keep this file: it is what stops plays being counted twice.
            """)
        XCTAssertEqual(out.exit, 1)
    }

    func testJournalTooNew() {
        let out = renderSyncPlays(blockedAtStart(.journalTooNew), json: false)
        XCTAssertEqual(out.text,
                       "The play-sync journal was written by a newer MusicTUI; nothing was changed. "
                       + "Update MusicTUI to sync plays.")
        XCTAssertEqual(out.exit, 1)
    }

    func testDirectoryUnsafe() {
        let path = "/tmp/playsync"
        let out = renderSyncPlays(blockedAtStart(.directoryUnsafe(path: path)), json: false)
        XCTAssertEqual(out.text,
                       "The play-sync folder \(path) is not private (owner and mode 700 required); nothing was changed.")
        XCTAssertEqual(out.exit, 1)
    }

    // MARK: Outstanding problems

    func testOutstandingProblemsOfAllFourReasons() {
        let outstanding = [
            entry("A", "One", seq: 1, state: .unmatched, reason: "no_alias"),
            entry("B", "Two", seq: 2, state: .unmatched, reason: "bad_alias"),
            entry("C", "Three", seq: 3, state: .unmatched, reason: "not_found"),
            entry("D", "Four", seq: 4, state: .unmatched, reason: "ambiguous"),
            entry("E", "Five", seq: 5, state: .conflict, reason: "conflict"),
        ]
        let out = renderSyncPlays(result(outstanding: outstanding), json: false)
        XCTAssertEqual(out.text, """
            Nothing new to record.
            Not recorded (5):
              A — One: Bridge could not identify it in Music.app
              B — Two: Bridge could not identify it in Music.app
              C — Three: not in your Music.app library
              D — Four: matches more than one Music.app track
              E — Five: Music.app's play count changed during the write; left as it was
            """)
        XCTAssertEqual(out.exit, 0)
    }

    // MARK: JSON

    private func decode(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testJSONForRecordedProblemsAndUnconfirmed() throws {
        let r = result(
            fetch: .ok(newPlays: 3),
            recorded: [entry("Teardrop", "Massive Attack", seq: 1, completedAt: 1_790_300_187)],
            outstanding: [entry("Roads", "Portishead", seq: 2, state: .unmatched, reason: "not_found"),
                          entry("Angel", "Massive Attack", seq: 3, state: .conflict, reason: "conflict")],
            unconfirmed: [entry("Glory Box", "Portishead", seq: 4, state: .unresolved)],
            waiting: 1)
        let out = renderSyncPlays(r, json: true)
        XCTAssertEqual(out.exit, 0)
        let json = try decode(out.text)

        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["waiting"] as? Int, 1)
        XCTAssertEqual(json["music_running"] as? Bool, true)
        XCTAssertEqual(json["bridge"] as? String, "ok")
        XCTAssertTrue(json["error"] is NSNull)

        let recorded = try XCTUnwrap(json["recorded"] as? [[String: Any]])
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0]["title"] as? String, "Teardrop")
        XCTAssertEqual(recorded[0]["artist"] as? String, "Massive Attack")
        XCTAssertEqual(recorded[0]["completed_at"] as? Int, 1_790_300_187)

        let unconfirmed = try XCTUnwrap(json["unconfirmed"] as? [[String: Any]])
        XCTAssertEqual(unconfirmed.count, 1)
        XCTAssertEqual(unconfirmed[0]["title"] as? String, "Glory Box")
        XCTAssertEqual(unconfirmed[0]["artist"] as? String, "Portishead")

        let problems = try XCTUnwrap(json["problems"] as? [[String: Any]])
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0]["title"] as? String, "Roads")
        XCTAssertEqual(problems[0]["artist"] as? String, "Portishead")
        XCTAssertEqual(problems[0]["state"] as? String, "unmatched")
        XCTAssertEqual(problems[0]["reason"] as? String, "not_found")
        XCTAssertEqual(problems[1]["state"] as? String, "conflict")
        XCTAssertEqual(problems[1]["reason"] as? String, "conflict")
    }

    func testJSONCarriesTheFailureSentence() throws {
        let out = renderSyncPlays(result(fetch: .bridgeNotRunning), json: true)
        XCTAssertEqual(out.exit, 1)
        let json = try decode(out.text)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["bridge"] as? String, "not_running")
        XCTAssertEqual(json["error"] as? String, "Bridge is not running, so no new plays could be read.")
    }

    func testJSONBridgeValues() throws {
        let cases: [(PlaySyncFetchStatus, String)] = [
            (.ok(newPlays: 0), "ok"), (.bridgeNotRunning, "not_running"), (.bridgeTooOld, "too_old"),
            (.ledgerReplaced, "replaced"), (.failed("x"), "failed"),
        ]
        for (fetch, expected) in cases {
            let json = try decode(renderSyncPlays(result(fetch: fetch), json: true).text)
            XCTAssertEqual(json["bridge"] as? String, expected)
        }
    }

    func testJSONForABlockedPass() throws {
        let out = renderSyncPlays(blockedAtStart(.lockBusy), json: true)
        XCTAssertEqual(out.exit, 1)
        let json = try decode(out.text)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "Another sync is running; try again in a moment.")
        XCTAssertTrue(json["bridge"] is NSNull)
        XCTAssertEqual(json["music_running"] as? Bool, false)
    }

    // MARK: The command

    func testParsesWithJSON() throws {
        let command = try Music.parseAsRoot(["sync-plays", "--json"])
        let sync = try XCTUnwrap(command as? SyncPlays)
        XCTAssertTrue(sync.json)
    }

    func testParsesWithoutJSON() throws {
        let command = try Music.parseAsRoot(["sync-plays"])
        let sync = try XCTUnwrap(command as? SyncPlays)
        XCTAssertFalse(sync.json)
    }

    func testAbstract() {
        XCTAssertEqual(SyncPlays.configuration.commandName, "sync-plays")
        XCTAssertEqual(SyncPlays.configuration.abstract,
                       "Record library songs Bridge played to the end in Music.app's play counts.")
    }

    private final class RecordingRunner: PlaySyncRunning {
        var triggers: [PlaySyncTrigger] = []
        let answer: PlaySyncResult
        init(_ answer: PlaySyncResult) { self.answer = answer }
        func pass(_ trigger: PlaySyncTrigger) -> PlaySyncResult {
            triggers.append(trigger)
            return answer
        }
    }

    func testRunsOneExplicitPassAndRendersIt() {
        let runner = RecordingRunner(result(fetch: .bridgeNotRunning))
        let out = SyncPlays.perform(runner, json: false)
        XCTAssertEqual(runner.triggers, [.explicit])
        XCTAssertEqual(out.text, "Bridge is not running, so no new plays could be read.")
        XCTAssertEqual(out.exit, 1)
    }
}
