// tools/music/Tests/MusicTests/MarkedSetPlaylistIDTests.swift
import XCTest
@testable import music

/// A marked playlist is captured by its persistent ID at mark time, from the
/// Playlists rail's own bulk read, so a playlist renamed after the mark, or
/// another taking its name, can never be played in its place. Every
/// AppleScript goes to a fake interpreter (a temp shell script); nothing here
/// reaches Music, osascript, the SpanDAC socket or ~/.config/music.
final class MarkedSetPlaylistIDTests: XCTestCase {
    private let fs = "\u{1F}"
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    private func line(_ kind: String, _ pid: String, _ name: String) -> String {
        [kind, pid, name].joined(separator: fs)
    }

    // MARK: - The rail read carries each row's ID

    func testRailParseCarriesEachRowsPersistentIDInRailOrder() {
        let raw = [line("U", "00000000000000A1", "Working Vibes"),
                   line("S", "00000000000000a2", "Loops"),
                   line("U", "00000000000000A3", "__queue__ leftover"),
                   line("U", "00000000000000A4", "Chill"),
                   line("U", "00000000000000A5", "Chill")].joined(separator: "\n") + "\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Working Vibes", "Loops", "Chill", "Chill"])
        XCTAssertEqual(parsed.persistentIDs, ["00000000000000A1", "00000000000000A2", "00000000000000A4",
                                              "00000000000000A5"],
                       "one ID per kept row, in the same order, upper-cased; a hidden temp row takes its ID with it")
        XCTAssertEqual(parsed.subscription, ["Loops"])
    }

    /// A malformed ID is never kept, and never guessed: the row stays on the
    /// rail (every other consumer still sees it) with no ID, so it cannot be
    /// marked. The name is never taken from the ID's field.
    func testRailParseOfAMalformedIDFailsClosedToNoID() {
        let raw = [line("U", "not-an-id", "Mix"),
                   line("U", "", "Empty ID"),
                   line("U", "0123456789ABCDE", "Short"),
                   line("U", "0123456789ABCDEF0", "Long"),
                   line("S", "missing value", "Apple One"),
                   line("U", "00000000000000B1", "Good")].joined(separator: "\n")
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Mix", "Empty ID", "Short", "Long", "Apple One", "Good"])
        XCTAssertEqual(parsed.persistentIDs, [nil, nil, nil, nil, nil, "00000000000000B1"])
        XCTAssertEqual(parsed.subscription, ["Apple One"])
    }

    /// A line in the old two-field shape still gives its name, with no ID.
    func testRailParseOfALineWithoutAnIDKeepsTheNameAndHasNoID() {
        let parsed = parseRailPlaylistNames("U\u{1F}Real One\nS\u{1F}Loops\n")
        XCTAssertEqual(parsed.names, ["Real One", "Loops"])
        XCTAssertEqual(parsed.persistentIDs, [nil, nil])
        XCTAssertEqual(parsed.subscription, ["Loops"])
    }

    /// The rail read is bulk: per class, one count, one get of every
    /// persistent ID and one of every name, coerced to lists, then a loop over
    /// lists already in memory. No per-row Apple Event, and it only reads.
    func testRailScriptIsBulkAndOnlyReads() {
        let script = railPlaylistNamesScript
        for cls in ["user playlist", "subscription playlist"] {
            // Two ID gets per class: the read, and the re-read after the names that proves the pairing.
            XCTAssertEqual(script.components(separatedBy: "persistent ID of every \(cls)\n").count - 1, 2, cls)
            XCTAssertEqual(script.components(separatedBy: "name of every \(cls)\n").count - 1, 1, cls)
            XCTAssertTrue(script.contains("count of \(cls)s"), "\(cls): the guard against an empty class")
        }
        for column in ["uIDs", "uNames", "sIDs", "sNames"] {
            XCTAssertTrue(script.contains("set \(column) to \(column) as list"), "\(column): a one-playlist get is a bare value")
        }
        XCTAssertFalse(script.contains("repeat with p in"), "no per-row reference loop")
        XCTAssertFalse(script.contains("of p"), "no per-row property get")
        for line in script.components(separatedBy: "\n") where line.contains("repeat with") {
            XCTAssertTrue(line.contains("repeat with i from 1 to"), "unexpected loop: \(line)")
        }
        XCTAssertTrue(script.contains("\"U\" & fs & (item i of uIDs) & fs & (item i of uNames)"), script)
        XCTAssertTrue(script.contains("\"S\" & fs & (item i of sIDs) & fs & (item i of sNames)"), script)
        for word in ["make new", "duplicate", "delete", "set name"] {
            XCTAssertFalse(script.contains(word), word)
        }
        for word in ["before", "after", "active", "left"] {
            XCTAssertNil(script.range(of: "set \(word) to"), "reserved word as a variable: \(word)")
        }
    }

    /// A fake interpreter answering one canned reply and logging each script.
    private final class FakeInterpreter {
        let backend: AppleScriptBackend
        private let logPath: String
        init(reply: String, exitCode: Int32 = 0) {
            let dir = FileManager.default.temporaryDirectory
            let id = UUID().uuidString
            logPath = dir.appendingPathComponent("rail-ids-log-\(id).txt").path
            let replyPath = dir.appendingPathComponent("rail-ids-reply-\(id).txt").path
            try? reply.write(toFile: replyPath, atomically: true, encoding: .utf8)
            let scriptPath = dir.appendingPathComponent("rail-ids-fake-\(id).sh").path
            let body = """
                #!/bin/sh
                printf '%s\\n=====\\n' "$2" >> "\(logPath)"
                if [ \(exitCode) -ne 0 ]; then exit \(exitCode); fi
                cat "\(replyPath)"
                """
            try? body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            backend = AppleScriptBackend(executable: scriptPath)
        }
        var scripts: [String] {
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            return log.components(separatedBy: "\n=====\n").filter { !$0.isEmpty }
        }
    }

    func testFetchUserPlaylistNamesCarriesTheIDsInOneScript() {
        let fake = FakeInterpreter(reply: [line("U", "00000000000000A1", "Chill"),
                                           line("S", "00000000000000A2", "Replay 2022"),
                                           line("U", "bogus", "Focus")].joined(separator: "\n"))
        XCTAssertEqual(fetchUserPlaylistNames(backend: fake.backend),
                       .success(names: ["Chill", "Replay 2022", "Focus"], subscription: ["Replay 2022"],
                                persistentIDs: ["00000000000000A1", "00000000000000A2", nil]))
        XCTAssertEqual(fake.scripts.count, 1, "one script for the whole rail")
        XCTAssertTrue(fake.scripts.first?.contains("set uIDs to persistent ID of every user playlist") ?? false,
                      "the rail read is the ID-carrying script: \(fake.scripts)")

        XCTAssertEqual(fetchUserPlaylistNames(backend: FakeInterpreter(reply: "", exitCode: 1).backend), .failure,
                       "a failed read is still its own case, never an empty list")
    }

    // MARK: - `m` records the row's ID

    private func musicAppRouting() -> RoutingCoordinator {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.musicApp)
        return RoutingCoordinator(store: modeStore, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) })
    }

    /// The Shell's own shape: built with no names, the rail read lands off the
    /// tick thread with its IDs, and `m` records the highlighted row's ID.
    func testMOnARailRowFromTheAsyncReadRecordsItsID() {
        let marks = MarkedSetStore()
        let status = StatusStore()
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Chill", "Chill", "Focus"]
        spy.persistentIDs = ["00000000000000F1", "00000000000000F2", "00000000000000F3"]
        let s = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: musicAppRouting(),
                               playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                               makeSources: { spy.makeSources($0) },
                               warmUpSleep: { _ in }, screenWidth: { 160 }, marks: marks)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Chill", "Chill", "Focus"] }, "\(s.railNamesForTest)")
        _ = s.handle(.down)
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        guard case .playlist(let id, let name)? = marks.items.first, marks.count == 1 else {
            return XCTFail("\(marks.items)")
        }
        XCTAssertEqual(id, "00000000000000F2", "the second 'Chill' is its own playlist")
        XCTAssertEqual(name, "Chill")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertEqual(out.components(separatedBy: "\(markedRowGlyph) Chill").count - 1, 1,
                       "only the marked one of the two namesakes shows the mark")
    }

    /// Every rail consumer reads the names exactly as before the IDs: the
    /// rail's rows, the data sources it builds from them, the subscription
    /// badge set and the render.
    func testRailConsumersAreUnchangedByTheIDs() {
        let status = StatusStore()
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Chill", "Replay 2022"]
        spy.subscription = ["Replay 2022"]
        spy.persistentIDs = ["00000000000000F1", "00000000000000F2"]
        var built: [[String]] = []
        let s = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: musicAppRouting(),
                               playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                               makeSources: { built.append($0); return spy.makeSources($0) },
                               warmUpSleep: { _ in }, screenWidth: { 160 })
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Chill", "Replay 2022"] })
        XCTAssertEqual(built, [["Chill", "Replay 2022"]], "the data sources are built from the names alone")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Chill") && out.contains("Replay 2022"), out)
        XCTAssertFalse(out.contains("00000000000000F1"), "an ID reached the screen")
    }

    /// On SpanDAC data the mark records the row's own SpanDAC id (a marked
    /// play from SpanDAC data still refuses before reading anything).
    func testMOnASpanDACRowRecordsItsID() {
        let page = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
         "items":[{"id":"pl1","title":"SpanDAC Playlist","kind":"playlist"}],
         "next_cursor":null}
        """
        let marks = MarkedSetStore()
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true),
                                   wire: BridgeLibraryReadsWire(["slice.libraryPlaylists": [page]]),
                                   spy: PlaylistAppleScriptSpy(), status: status, marks: marks)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["SpanDAC Playlist"] }, "\(s.railNamesForTest)")
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        guard case .playlist(let id, let name)? = marks.items.first else { return XCTFail("\(marks.items)") }
        XCTAssertEqual(id, "pl1")
        XCTAssertEqual(name, "SpanDAC Playlist")
        XCTAssertEqual(marks.listSource, .bridge)
    }
}
