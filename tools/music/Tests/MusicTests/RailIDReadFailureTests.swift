// tools/music/Tests/MusicTests/RailIDReadFailureTests.swift
import XCTest
@testable import music

/// The rail needs only names; the persistent IDs are an addition for `m`. An
/// ID read that fails, or that cannot be proven to pair with the names, takes
/// that class's IDs away (the rows come back in the two-field `U<US>name`
/// shape, which the parser reads as nil IDs). It never takes the rail down.
/// Every AppleScript goes to a fake interpreter; nothing here reaches Music or
/// osascript. The fake cannot run the script's `try`, so the reply shapes the
/// script emits are pinned here, and the script's text is pinned separately.
final class RailIDReadFailureTests: XCTestCase {
    private let fs = "\u{1F}"

    private func withIDs(_ kind: String, _ pid: String, _ name: String) -> String {
        [kind, pid, name].joined(separator: fs)
    }

    private func withoutID(_ kind: String, _ name: String) -> String {
        [kind, name].joined(separator: fs)
    }

    private func fake(reply: String, exitCode: Int32 = 0) -> AppleScriptBackend {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let replyPath = dir.appendingPathComponent("rail-idfail-reply-\(id).txt").path
        try? reply.write(toFile: replyPath, atomically: true, encoding: .utf8)
        let scriptPath = dir.appendingPathComponent("rail-idfail-fake-\(id).sh").path
        let body = """
            #!/bin/sh
            if [ \(exitCode) -ne 0 ]; then exit \(exitCode); fi
            cat "\(replyPath)"
            """
        try? body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return AppleScriptBackend(executable: scriptPath)
    }

    // MARK: - The reply shapes the script emits when a class loses its IDs

    /// A failed user-ID read: the user rows arrive as `U<US>name`, the
    /// subscription rows keep `S<US>id<US>name`. Every name loads.
    func testFailedUserIDReadLoadsEveryNameWithNilUserIDsAndKeepsSubscriptionIDs() {
        let reply = [withoutID("U", "Chill"), withoutID("U", "Focus"),
                     withIDs("S", "00000000000000A2", "Replay 2022")].joined(separator: "\n")
        XCTAssertEqual(fetchUserPlaylistNames(backend: fake(reply: reply)),
                       .success(names: ["Chill", "Focus", "Replay 2022"], subscription: ["Replay 2022"],
                                persistentIDs: [nil, nil, "00000000000000A2"]))
    }

    /// The same, with the subscription class the one that lost its IDs.
    func testFailedSubscriptionIDReadLoadsEveryNameWithNilSubscriptionIDsAndKeepsUserIDs() {
        let reply = [withIDs("U", "00000000000000A1", "Chill"), withIDs("U", "00000000000000A3", "Focus"),
                     withoutID("S", "Replay 2022"), withoutID("S", "Loops")].joined(separator: "\n")
        XCTAssertEqual(fetchUserPlaylistNames(backend: fake(reply: reply)),
                       .success(names: ["Chill", "Focus", "Replay 2022", "Loops"],
                                subscription: ["Replay 2022", "Loops"],
                                persistentIDs: ["00000000000000A1", "00000000000000A3", nil, nil]))
    }

    /// An ID re-read that differs from the first read drops that class's IDs
    /// for this refresh; the rail loads, it does not fail.
    func testIDReReadMismatchLoadsTheClassWithNilIDsAndTheRailDoesNotFail() {
        let reply = [withoutID("U", "Chill"), withoutID("U", "Chill"),
                     withIDs("S", "00000000000000A2", "Loops")].joined(separator: "\n")
        let read = fetchUserPlaylistNames(backend: fake(reply: reply))
        XCTAssertEqual(read, .success(names: ["Chill", "Chill", "Loops"], subscription: ["Loops"],
                                      persistentIDs: [nil, nil, "00000000000000A2"]))
        XCTAssertNotEqual(read, .failure)
    }

    /// Names unreadable is the one failure the rail still reports.
    func testUnreadableNamesStillFailTheRail() {
        XCTAssertEqual(fetchUserPlaylistNames(backend: fake(reply: "", exitCode: 1)), .failure)
    }

    // MARK: - The script's own text

    private func between(_ script: String, from start: String, to end: String) -> String? {
        guard let a = script.range(of: start), let b = script.range(of: end, range: a.upperBound..<script.endIndex)
        else { return nil }
        return String(script[a.lowerBound..<b.upperBound])
    }

    /// Per class: the first ID get sits inside a `try` whose `on error` leaves
    /// no IDs, the names are read OUTSIDE any `try` (their failure still
    /// fails the script), and the IDs are read again after the names.
    func testScriptWrapsEachIDGetInTryRereadsAfterTheNamesAndComparesConsideringCase() {
        let script = railPlaylistNamesScript
        for (cls, ids, names, total) in [("user playlist", "uIDs", "uNames", "uTotal"),
                                         ("subscription playlist", "sIDs", "sNames", "sTotal")] {
            let firstGet = "set \(ids) to persistent ID of every \(cls)"
            let nameGet = "set \(names) to name of every \(cls)"
            let reGet = "set \(ids)Again to persistent ID of every \(cls)"
            guard let firstRange = script.range(of: firstGet), let nameRange = script.range(of: nameGet),
                  let reRange = script.range(of: reGet) else {
                XCTFail("\(cls): missing a get\n\(script)"); continue
            }
            XCTAssertLessThan(firstRange.lowerBound, nameRange.lowerBound, "\(cls): IDs first")
            XCTAssertLessThan(nameRange.lowerBound, reRange.lowerBound, "\(cls): the re-read is after the names")

            let guarded = between(script, from: "try\n        \(firstGet)", to: "end try")
            XCTAssertNotNil(guarded, "\(cls): the first ID get is inside try")
            XCTAssertTrue(guarded?.contains("on error") ?? false, "\(cls): the guarded ID get has an on error")
            XCTAssertFalse(guarded?.contains(nameGet) ?? true, "\(cls): the names are not inside that try")

            let reGuarded = between(script, from: "try\n            \(reGet)", to: "end try")
            XCTAssertNotNil(reGuarded, "\(cls): the re-read is inside try")
            XCTAssertTrue(reGuarded?.contains("set \(ids)Again to \(ids)Again as list") ?? false, "\(cls): coerced")
            XCTAssertTrue(reGuarded?.contains("considering case") ?? false, "\(cls): compared considering case")
            XCTAssertTrue(reGuarded?.contains("\(ids)Again is \(ids)") ?? false, "\(cls): compared to the first read")

            // The names are not wrapped: no `try` sits between the first ID
            // block's end and the name get.
            let afterIDs = script[script.range(of: "end try", range: firstRange.upperBound..<script.endIndex)!.upperBound..<nameRange.lowerBound]
            XCTAssertFalse(afterIDs.contains("try"), "\(cls): the name get is not inside a try")
            XCTAssertTrue(script.contains("if (count of \(names)) is not \(total) then error"), "\(cls): names still fail")
            XCTAssertFalse(script.contains("if (count of \(ids)) is not \(total) or"),
                           "\(cls): an ID count mismatch no longer fails the rail")
        }
        XCTAssertNil(script.range(of: "set uPaired to true\n"), "pairing is proven, not assumed")
    }

    /// Both line shapes come out of the script: with IDs when the class is
    /// proven, name-only otherwise.
    func testScriptEmitsBothLineShapesPerClass() {
        let script = railPlaylistNamesScript
        XCTAssertTrue(script.contains("\"U\" & fs & (item i of uIDs) & fs & (item i of uNames)"), script)
        XCTAssertTrue(script.contains("\"S\" & fs & (item i of sIDs) & fs & (item i of sNames)"), script)
        XCTAssertTrue(script.contains("\"U\" & fs & (item i of uNames)"), script)
        XCTAssertTrue(script.contains("\"S\" & fs & (item i of sNames)"), script)
    }
}
