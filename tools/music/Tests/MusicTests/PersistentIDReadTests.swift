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
        init(strictReply: String, otherReply: String? = nil, exitCode: Int32 = 0) {
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
                if [ \(exitCode) -ne 0 ]; then exit \(exitCode); fi
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

    func testPlaylistIDReadIsOneBulkScript() {
        let script = playlistTrackIDsScript(playlist: "Chill")
        // Four bulk column reads over the playlist's tracks.
        XCTAssertEqual(script.components(separatedBy: "of every track of playlist").count - 1, 4,
                       "persistent ID, name, artist and album: one bulk get each")
        XCTAssertTrue(script.contains("persistent ID of every track of playlist"))
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
        let rows = try XCTUnwrap(fetchPlaylistTrackIDs(backend: ok.backend, playlist: "Chill"))
        XCTAssertEqual(rows.map(\.name), ["N"])
        XCTAssertEqual(ok.scripts.count, 1, "one script run for the whole playlist")

        let torn = FakeInterpreter(strictReply: "2\n" + good + "\n")
        XCTAssertNil(fetchPlaylistTrackIDs(backend: torn.backend, playlist: "Chill"))

        let failing = FakeInterpreter(strictReply: "", exitCode: 1)
        XCTAssertNil(fetchPlaylistTrackIDs(backend: failing.backend, playlist: "Chill"))
    }

    func testPlaylistNameIsEscaped() {
        let name = "He said \"hi\" \\ then left"
        let script = playlistTrackIDsScript(playlist: name)
        let esc = escapeAppleScriptString(name)
        XCTAssertNotEqual(esc, name)
        XCTAssertTrue(script.contains("playlist \"\(esc)\""))
        XCTAssertFalse(script.contains("playlist \"\(name)\""), "the raw name reached the script")
        // A name built to close the string and inject a statement stays inside the literal.
        let hostile = "x\" & (do shell script \"id\") & \""
        let hostileScript = playlistTrackIDsScript(playlist: hostile)
        XCTAssertFalse(hostileScript.contains("playlist \"\(hostile)\""))
        XCTAssertTrue(hostileScript.contains(escapeAppleScriptString(hostile)))
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
