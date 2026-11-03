// tools/music/Tests/MusicTests/PersistentIDReadTests.swift
import XCTest
@testable import music

/// Combined play, step 2: bulk reads that return each track's persistent ID, so
/// a later step can build one queue addressed by identity
/// (`persistentIDQueueEntry`). Parsers are pure; the fetch and album tests drive
/// an injected fake interpreter and never reach Music or the real osascript.
final class PersistentIDReadTests: XCTestCase {
    private let fs = "\u{1F}"

    /// A fake interpreter: logs every script it is handed and answers with a
    /// canned reply. A script containing `artist is` (the strict album clause)
    /// gets `strictReply`; any other script gets `otherReply`.
    private final class FakeInterpreter {
        let dir: String
        let scriptPath: String
        let logPath: String
        init(strictReply: String, otherReply: String? = nil, exitCode: Int32 = 0, stderr: String = "") {
            dir = NSTemporaryDirectory() + "pid-read-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            scriptPath = dir + "/fake.sh"
            logPath = dir + "/log.txt"
            let strictPath = dir + "/strict.txt"
            let otherPath = dir + "/other.txt"
            try? strictReply.write(toFile: strictPath, atomically: true, encoding: .utf8)
            try? (otherReply ?? strictReply).write(toFile: otherPath, atomically: true, encoding: .utf8)
            let body = """
                #!/bin/sh
                printf '%s\\n=====\\n' "$2" >> "\(logPath)"
                if [ \(exitCode) -ne 0 ]; then printf '%s' '\(stderr)' >&2; exit \(exitCode); fi
                case "$2" in
                  *"artist is"*) cat "\(strictPath)" ;;
                  *) cat "\(otherPath)" ;;
                esac
                """
            try? body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        }
        var backend: AppleScriptBackend { AppleScriptBackend(executable: scriptPath) }
        var scripts: [String] {
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            return log.components(separatedBy: "\n=====\n").filter { !$0.isEmpty }
        }
        deinit { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func playlistRow(_ pid: String, _ name: String, _ artist: String, _ album: String) -> String {
        [pid, name, artist, album].joined(separator: fs)
    }

    private func albumRow(_ pid: String, _ idx: Int, _ name: String, status: String = "subscription",
                          disc: Int, track: Int, albumArtist: String = "AA", album: String = "Alb") -> String {
        [String(idx), name, "Art", albumArtist, status, String(disc), String(track), album, pid].joined(separator: fs)
    }

    // MARK: - playlist read

    private let chillID = "00000000000000F1"

    func testPlaylistIDReadIsOneBulkScript() {
        let script = playlistTrackIDsScript(playlistID: chillID)
        // Four bulk column reads over the playlist's tracks, and the identity re-read.
        XCTAssertEqual(script.components(separatedBy: "of every track of pl\n").count - 1, 5,
                       "persistent ID, name, artist and album: one bulk get each, then the IDs again: \(script)")
        XCTAssertTrue(script.contains("persistent ID of every track of pl"))
        // `tracks 1 thru n` answers a bare value for a one-track playlist (probed live), so it is not used.
        XCTAssertFalse(script.contains("thru"))
        // No per-track Apple Events: no iteration over tracks, no per-track property gets.
        XCTAssertFalse(script.contains("repeat with t"))
        XCTAssertFalse(script.contains("of track i"))
        XCTAssertFalse(script.contains("of item i of tracks"))
        XCTAssertFalse(script.contains("repeat with i in"))
        // The only loop indexes in-memory lists, never `tracks`.
        for line in script.components(separatedBy: "\n") where line.contains("repeat with") {
            XCTAssertTrue(line.contains("repeat with i from 1 to total"), "unexpected loop: \(line)")
        }
        for word in ["make new", "duplicate", "delete", "set name"] {
            XCTAssertFalse(script.contains(word), word)
        }
        for word in ["before", "after", "active", "left"] {
            XCTAssertNil(script.range(of: "set \(word) to"), "reserved word as a variable: \(word)")
        }
    }

    /// The four column reads are four Apple Events: the IDs are read again at
    /// the end and must equal the first read, or the script errors, so a
    /// playlist edited between the gets never yields a reply.
    func testPlaylistIDReadRereadsTheIdentitiesAndComparesThem() {
        let script = playlistTrackIDsScript(playlistID: chillID)
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.firstIndex(of: "set pids to persistent ID of every track of pl")
        let again = lines.firstIndex(of: "set recheck to persistent ID of every track of pl")
        XCTAssertNotNil(first, script)
        XCTAssertNotNil(again, script)
        if let first, let again {
            XCTAssertGreaterThan(again, first)
            for column in ["ns", "ars", "als"] {
                let at = lines.firstIndex { $0.hasPrefix("set \(column) to ") && $0.hasSuffix("of every track of pl") }
                XCTAssertNotNil(at, column)
                if let at { XCTAssertLessThan(at, again, "\(column) is read inside the bracket") }
            }
        }
        // One track can answer a bare value, not a list: both reads are coerced
        // to lists, so a one-track playlist compares item to item.
        XCTAssertTrue(lines.contains("set pids to pids as list"), script)
        XCTAssertTrue(lines.contains("set recheck to recheck as list"), script)
        XCTAssertTrue(lines.contains("if recheck is not pids then error \"\(playlistIDsChangedError)\" number 1002"),
                      script)
        XCTAssertTrue(script.contains("considering case"), "IDs compare exactly, never case-folded")
    }

    /// The read is addressed by the playlist's own persistent ID, the one its
    /// mark captured from the rail, so a playlist renamed, or another taking
    /// its name, is never read by mistake.
    func testPlaylistIDReadIsAddressedByThePlaylistsOwnID() {
        let script = playlistTrackIDsScript(playlistID: chillID)
        XCTAssertTrue(script.contains("set pl to (first playlist whose persistent ID is \"\(chillID)\")"), script)
        XCTAssertFalse(script.contains("playlist \"Chill\""))
        XCTAssertFalse(script.contains("whose name is"), "no name addressing in the read")
        XCTAssertEqual(script.components(separatedBy: "whose persistent ID is").count - 1, 1,
                       "the playlist is resolved once, then every read goes through that reference")
    }

    func testPlaylistIDParseKeepsOrder() throws {
        let raw = "3\n"
            + playlistRow("00000000000000AB", "Third alphabetically", "Z", "Zed") + "\n"
            + playlistRow("FFFFFFFFFFFFFFFF", "Alpha", "A", "") + "\n"
            + playlistRow("0123456789ABCDEF", "Mid", "M", "Em") + "\n"
        let rows = try XCTUnwrap(parsePlaylistTrackIDs(raw))
        XCTAssertEqual(rows.map(\.name), ["Third alphabetically", "Alpha", "Mid"], "playlist order, not sorted")
        XCTAssertEqual(rows.map { persistentIDOfQueueEntry($0.index) },
                       ["00000000000000AB", "FFFFFFFFFFFFFFFF", "0123456789ABCDEF"])
        XCTAssertEqual(rows[0].artist, "Z")
        XCTAssertEqual(rows[0].album, "Zed")
        XCTAssertEqual(rows[1].album, "", "an empty album stays an empty album")
        XCTAssertTrue(rows.allSatisfy { !$0.isCurrent })
    }

    func testPlaylistIDParseOfEmptyPlaylistIsEmptyNotNil() {
        XCTAssertEqual(parsePlaylistTrackIDs("0\n"), [])
        XCTAssertEqual(parsePlaylistTrackIDs("0"), [])
    }

    func testUnparsableIDFailsClosed() {
        let good = playlistRow("0123456789ABCDEF", "N", "A", "B")
        // Malformed identity: too short, too long, not hex, empty.
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + playlistRow("0123456789ABCDE", "N", "A", "B")))
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + playlistRow("0123456789ABCDEF0", "N", "A", "B")))
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + playlistRow("0123456789ABCDEG", "N", "A", "B")))
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + playlistRow("", "N", "A", "B")))
        // One bad row spoils the whole list: no partial list.
        XCTAssertNil(parsePlaylistTrackIDs("2\n" + good + "\n" + playlistRow("nope", "N", "A", "B")))
        // Torn reply: fewer rows than the header promised.
        XCTAssertNil(parsePlaylistTrackIDs("3\n" + good + "\n" + good))
        // More rows than the header promised.
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + good + "\n" + good))
        // Cut mid-row (missing fields).
        XCTAssertNil(parsePlaylistTrackIDs("2\n" + good + "\n" + "0123456789ABCDEF" + fs + "Name"))
        // No header / garbage header / empty reply.
        XCTAssertNil(parsePlaylistTrackIDs(good))
        XCTAssertNil(parsePlaylistTrackIDs("x\n" + good))
        XCTAssertNil(parsePlaylistTrackIDs(""))
        // A stray field separator inside a name shifts the columns: refuse.
        XCTAssertNil(parsePlaylistTrackIDs("1\n" + playlistRow("0123456789ABCDEF", "N" + fs + "x", "A", "B")))
    }

    func testFetchPlaylistTrackIDsReturnsRowsAndFailsClosedOnTornReplyOrScriptError() throws {
        let good = playlistRow("0123456789ABCDEF", "N", "A", "B")
        let ok = FakeInterpreter(strictReply: "1\n" + good + "\n")
        let read = try XCTUnwrap(fetchPlaylistTrackIDs(backend: ok.backend, playlistID: chillID))
        guard case .tracks(let rows) = read else { return XCTFail("\(read)") }
        XCTAssertEqual(rows.map(\.name), ["N"])
        XCTAssertEqual(ok.scripts.count, 1, "one script run for the whole playlist")
        XCTAssertTrue(ok.scripts.first?.contains("whose persistent ID is \"\(chillID)\"") ?? false)

        let torn = FakeInterpreter(strictReply: "2\n" + good + "\n")
        XCTAssertNil(fetchPlaylistTrackIDs(backend: torn.backend, playlistID: chillID))

        let failing = FakeInterpreter(strictReply: "", exitCode: 1)
        XCTAssertNil(fetchPlaylistTrackIDs(backend: failing.backend, playlistID: chillID))
    }

    /// No playlist has the ID any more: the script says so in its own reply,
    /// told apart from a failed read, and resolves no other playlist. Only the
    /// "no such object" error counts as gone; any other error still fails.
    func testAPlaylistIDThatIsGoneIsMissingNotAFailure() throws {
        let script = playlistTrackIDsScript(playlistID: chillID)
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let at = try XCTUnwrap(lines.firstIndex(of: "set pl to (first playlist whose persistent ID is \"\(chillID)\")"),
                               script)
        XCTAssertEqual(lines[at - 1], "try", script)
        XCTAssertEqual(lines[at + 1], "on error number -1728", script)
        XCTAssertEqual(lines[at + 2], "return \"\(playlistMissingReply)\"", script)
        XCTAssertEqual(lines[at + 3], "end try", script)
        XCTAssertFalse(script.contains("whose name is"), "never falls back to a name")

        XCTAssertEqual(parsePlaylistTrackIDsRead(playlistMissingReply + "\n"), .missing)
        XCTAssertEqual(parsePlaylistTrackIDsRead(playlistMissingReply), .missing)
        XCTAssertEqual(parsePlaylistTrackIDsRead("0\n"), .tracks([]))
        XCTAssertNil(parsePlaylistTrackIDsRead(""))
        XCTAssertNil(parsePlaylistTrackIDsRead("missing\n" + playlistRow("0123456789ABCDEF", "N", "A", "B")),
                     "a missing reply with rows after it is torn, not missing")
        XCTAssertNil(parsePlaylistTrackIDs(playlistMissingReply), "the rows parser never reads it as an empty list")

        let gone = FakeInterpreter(strictReply: playlistMissingReply + "\n")
        XCTAssertEqual(fetchPlaylistTrackIDs(backend: gone.backend, playlistID: chillID), .missing)
        XCTAssertEqual(gone.scripts.count, 1, "one script, no second lookup")
    }

    func testTheComparisonErrorFailsClosed() {
        // The script's own error, as osascript reports it: on stderr, exit 1.
        let changed = FakeInterpreter(strictReply: "", exitCode: 1,
                                      stderr: "execution error: \(playlistIDsChangedError) (1002)")
        XCTAssertNil(fetchPlaylistTrackIDs(backend: changed.backend, playlistID: chillID))
        // The same text reaching stdout is never a reply either.
        XCTAssertNil(parsePlaylistTrackIDs(playlistIDsChangedError))
        XCTAssertNil(parsePlaylistTrackIDs("execution error: \(playlistIDsChangedError) (1002)\n"))
        let echoed = FakeInterpreter(strictReply: playlistIDsChangedError + "\n")
        XCTAssertNil(fetchPlaylistTrackIDs(backend: echoed.backend, playlistID: chillID))
    }

    func testAnIDThatIsNotAPersistentIDNeverReachesAScript() {
        let fake = FakeInterpreter(strictReply: "0\n")
        for bad in ["", "Chill", "0123456789ABCDE", "0123456789ABCDEFA", "x\" & (do shell script \"id\") & \""] {
            XCTAssertNil(fetchPlaylistTrackIDs(backend: fake.backend, playlistID: bad), bad)
        }
        XCTAssertEqual(fake.scripts, [], "a malformed playlist ID ran a script")
        // A valid one is escaped all the same.
        XCTAssertTrue(playlistTrackIDsScript(playlistID: chillID).contains("\"\(escapeAppleScriptString(chillID))\""))
    }

    // MARK: - album read

    func testAlbumIDScriptAddsOnlyThePersistentIDColumn() {
        let clause = "album is \"A\" and (artist is \"B\" or album artist is \"B\")"
        let plain = libraryAlbumRowsScript(whereClause: clause)
        let withIDs = libraryAlbumRowsScript(whereClause: clause, persistentIDs: true)
        XCTAssertFalse(plain.contains("persistent ID"), "the existing album read must be unchanged")
        XCTAssertTrue(withIDs.contains("persistent ID of every track of playlist \"Library\" whose \(clause)"))
    }

    func testAlbumIDReadKeepsAlbumOrderAndPlayableFilter() throws {
        // Library-position order (as the `whose` read yields it) is NOT album order:
        // disc 2 first, track 3 before track 1, plus a pre-release track and a removed one.
        let raw = [
            albumRow("00000000000000D2", 40, "Disc2 T1", disc: 2, track: 1),
            albumRow("0000000000000003", 41, "D1 T3", disc: 1, track: 3),
            albumRow("0000000000000099", 42, "Pre", status: "prerelease", disc: 1, track: 2),
            albumRow("0000000000000001", 43, "D1 T1", disc: 1, track: 1),
            albumRow("0000000000000098", 44, "Gone", status: "removed", disc: 2, track: 2),
        ].joined(separator: "\n") + "\n"
        let fake = FakeInterpreter(strictReply: raw)
        let res = resolveAlbumPlaybackTrackIDs(backend: fake.backend, title: "Alb", artist: "Art")
        XCTAssertFalse(res.readFailed)
        XCTAssertEqual(res.matched, 5, "matched keeps the pre-filter count")
        XCTAssertEqual(res.tracks.map(\.name), ["D1 T1", "D1 T3", "Disc2 T1"])
        XCTAssertEqual(res.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["0000000000000001", "0000000000000003", "00000000000000D2"])
        XCTAssertEqual(res.tracks.first?.album, "Alb")
        XCTAssertEqual(fake.scripts.count, 1, "the strict clause matched, so no fallback read")
        XCTAssertTrue(fake.scripts[0].contains("album is \"Alb\" and (artist is \"Art\" or album artist is \"Art\")"))
    }

    func testAlbumIDReadFallsBackToTitleOnlyAndDisambiguatesByArtist() throws {
        let raw = [
            albumRow("0000000000000011", 1, "Mine 2", disc: 1, track: 2, albumArtist: "Right Artist"),
            albumRow("0000000000000012", 2, "Mine 1", disc: 1, track: 1, albumArtist: "Right Artist"),
            albumRow("0000000000000021", 3, "Other", disc: 1, track: 1, albumArtist: "Wrong Artist"),
        ].joined(separator: "\n") + "\n"
        let fake = FakeInterpreter(strictReply: "", otherReply: raw)
        let res = resolveAlbumPlaybackTrackIDs(backend: fake.backend, title: "Alb", artist: "Right Artist")
        XCTAssertEqual(fake.scripts.count, 2, "strict read, then the title-only fallback")
        XCTAssertFalse(fake.scripts[1].contains("artist is"))
        XCTAssertEqual(res.tracks.map(\.name), ["Mine 1", "Mine 2"])
        XCTAssertEqual(res.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["0000000000000012", "0000000000000011"])
    }

    func testAlbumIDReadFailsClosedOnMalformedIDTornRowOrScriptError() {
        let good = albumRow("0000000000000001", 1, "T", disc: 1, track: 1)
        let badID = albumRow("000000000000000", 2, "U", disc: 1, track: 2)   // fifteen digits
        let torn = [String(3), "V", "Art"].joined(separator: fs)            // cut mid-row

        for reply in [good + "\n" + badID + "\n", good + "\n" + torn] {
            let fake = FakeInterpreter(strictReply: reply)
            let res = resolveAlbumPlaybackTrackIDs(backend: fake.backend, title: "Alb", artist: "Art")
            XCTAssertTrue(res.readFailed, "a partial album must not be returned")
            XCTAssertTrue(res.tracks.isEmpty)
        }
        let failing = FakeInterpreter(strictReply: "", exitCode: 1)
        XCTAssertTrue(resolveAlbumPlaybackTrackIDs(backend: failing.backend, title: "Alb", artist: "Art").readFailed)
    }

    func testParseAlbumRowsWithIDs() throws {
        let raw = albumRow("00000000000000AA", 7, "Name", disc: 2, track: 5, albumArtist: "AA", album: "Alb") + "\n"
        let rows = try XCTUnwrap(parseLibraryAlbumRowsWithIDs(raw))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].persistentID, "00000000000000AA")
        XCTAssertEqual(rows[0].disc, 2)
        XCTAssertEqual(rows[0].track, 5)
        XCTAssertEqual(rows[0].album, "Alb")
        XCTAssertEqual(parseLibraryAlbumRowsWithIDs(""), [], "no match is an empty list, not a failure")
        // The eight-field shape has no identity: refuse rather than guess.
        let eight = [String(1), "N", "A", "AA", "subscription", "1", "1", "Alb"].joined(separator: fs)
        XCTAssertNil(parseLibraryAlbumRowsWithIDs(eight + "\n"))
    }
}
