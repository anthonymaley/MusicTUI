import XCTest
@testable import music

/// Anthony's ruling (2026-11-01): EQ stays only if it works inside the
/// terminal. Music's Equalizer window must not appear on screen or come
/// forward. The old open path ran `tell application "Music" to reopen` before
/// the Window-menu click, which restores Music's main window visibly.
///
/// These read the script every EQ action sends, through a fake interpreter
/// that logs it and runs nothing, so no test reaches osascript or Music.
final class EQWindowParkingTests: XCTestCase {

    private let parkLine = #"set position of window "Equalizer" to {-3000, -3000}"#
    private let menuClick = #"click menu item "Equalizer" of menu "Window" of menu bar 1"#
    private let openGuard = #"if not (exists window "Equalizer") then"#
    private let controlBlock = #"tell window "Equalizer""#

    /// A fake `osascript`: logs every script it is handed, NUL-separated, and
    /// prints "CLOSED" for the background poll's read-only script (so that read
    /// takes its scripting-layer branch), nothing for anything else.
    private func fakeInterpreter() -> (backend: AppleScriptBackend, logPath: String) {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let logPath = dir.appendingPathComponent("eq-parking-log-\(id).txt").path
        let scriptPath = dir.appendingPathComponent("eq-parking-fake-\(id).sh").path
        let script = """
            #!/bin/sh
            printf '%s\\0' "$2" >> "\(logPath)"
            case "$2" in
              *'return "CLOSED"'*) printf 'CLOSED\\n' ;;
            esac
            exit 0
            """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return (AppleScriptBackend(executable: scriptPath), logPath)
    }

    private func scripts(at logPath: String) -> [String] {
        let raw = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        return raw.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// The one script an EQ toggle sends (the Equalizer-window script).
    private func toggleScript() throws -> String {
        let fake = fakeInterpreter()
        try eqSetEnabled(fake.backend, true)
        let sent = scripts(at: fake.logPath)
        XCTAssertEqual(sent.count, 1, "an EQ toggle sends one script")
        return try XCTUnwrap(sent.first)
    }

    private func presetScript() throws -> String {
        let fake = fakeInterpreter()
        try eqSetCurrent(fake.backend, name: "Nightclub")
        return try XCTUnwrap(scripts(at: fake.logPath).first)
    }

    private func offset(of needle: String, in haystack: String, after start: String.Index? = nil) -> String.Index? {
        let from = start ?? haystack.startIndex
        return haystack.range(of: needle, range: from..<haystack.endIndex)?.lowerBound
    }

    private func lines(_ script: String) -> [String] {
        script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Line index of the `end if` closing the block `if` at `start`. Counts
    /// block ifs only (a line beginning `if ` and ending ` then`); a one-line
    /// `if ... then <statement>` does not open a block.
    private func matchingEndIf(_ scriptLines: [String], from start: Int) -> Int? {
        var depth = 0
        for index in start..<scriptLines.count {
            let line = scriptLines[index]
            if line.hasPrefix("if ") && line.hasSuffix(" then") { depth += 1 }
            if line == "end if" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    // MARK: - The first open path

    /// The first attempt is the bare menu click Anthony's probe proved
    /// (2026-11-01 22:49): no `reopen` before it.
    func testTheFirstOpenIsTheMenuClickWithoutReopen() throws {
        let script = try toggleScript()
        let firstClick = try XCTUnwrap(offset(of: menuClick, in: script), "the script opens the Equalizer from the Window menu")
        XCTAssertFalse(script[..<firstClick].contains("reopen"),
                       "reopen must not run before the first menu click; it restores Music's main window on screen")
    }

    /// The window is parked off-screen before any control is touched.
    func testTheEqualizerIsParkedOffScreenBeforeItsControlsAreTouched() throws {
        let script = try toggleScript()
        let control = try XCTUnwrap(offset(of: controlBlock, in: script))
        XCTAssertTrue(script[..<control].contains(parkLine),
                      "the Equalizer must be moved to {-3000, -3000} before the toggle")
    }

    /// A window that is already open (one an older MusicTUI left on screen) is
    /// parked too: the park sits after the open block, not inside it.
    func testAnAlreadyOpenEqualizerIsParkedToo() throws {
        let scriptLines = lines(try toggleScript())
        let guardLine = try XCTUnwrap(scriptLines.firstIndex(of: openGuard), "the open block is guarded on the window's absence")
        let blockEnd = try XCTUnwrap(matchingEndIf(scriptLines, from: guardLine))
        let control = try XCTUnwrap(scriptLines.firstIndex(of: controlBlock))
        XCTAssertTrue(scriptLines[(blockEnd + 1)..<control].contains(parkLine),
                      "the park must run whether or not this script opened the window")
    }

    // MARK: - The fallback

    /// `reopen` survives only as the fallback: after the first click, inside a
    /// second absence check, and followed by a second click.
    func testReopenIsOnlyTheFallbackAfterTheClickFailed() throws {
        let script = try toggleScript()
        let firstClick = try XCTUnwrap(offset(of: menuClick, in: script))
        let afterFirstClick = script.index(firstClick, offsetBy: menuClick.count)
        let recheck = try XCTUnwrap(offset(of: openGuard, in: script, after: afterFirstClick),
                                    "the fallback runs only when the window did not appear")
        let reopen = try XCTUnwrap(offset(of: #"tell application "Music" to reopen"#, in: script, after: recheck))
        XCTAssertNotNil(offset(of: menuClick, in: script, after: reopen), "the fallback clicks the menu again after reopen")
    }

    /// The fallback notes Music's windows before `reopen` and afterwards closes
    /// only the ones `reopen` brought back, by their close button, never the
    /// Equalizer.
    func testTheFallbackClosesOnlyTheWindowsReopenShowed() throws {
        let script = try toggleScript()
        let snapshot = try XCTUnwrap(offset(of: "set windowNamesBeforeReopen to name of every window", in: script))
        let reopen = try XCTUnwrap(offset(of: #"tell application "Music" to reopen"#, in: script))
        XCTAssertLessThan(snapshot, reopen, "the windows are noted before reopen shows any")
        let secondClick = try XCTUnwrap(offset(of: menuClick, in: script, after: reopen))
        let close = try XCTUnwrap(offset(of: #"whose subrole is "AXCloseButton""#, in: script, after: secondClick),
                                  "the windows reopen showed are closed again")
        let closeLoop = script[secondClick..<close]
        XCTAssertTrue(closeLoop.contains("windowNamesBeforeReopen does not contain"),
                      "only windows absent before reopen are closed")
        XCTAssertTrue(closeLoop.contains(#"is not "Equalizer""#), "the Equalizer itself is never closed")
    }

    // MARK: - Every Equalizer-window action shares the path

    func testPresetSelectionOpensAndParksTheSameWay() throws {
        let script = try presetScript()
        let firstClick = try XCTUnwrap(offset(of: menuClick, in: script))
        XCTAssertFalse(script[..<firstClick].contains("reopen"))
        let control = try XCTUnwrap(offset(of: controlBlock, in: script))
        XCTAssertTrue(script[..<control].contains(parkLine))
    }

    /// The background poll still never opens, reopens, or moves the window.
    func testTheBackgroundReadNeverOpensReopensOrMovesTheWindow() throws {
        let fake = fakeInterpreter()
        _ = try fetchEQSnapshot(fake.backend, openWindow: false)
        let readOnly = try XCTUnwrap(scripts(at: fake.logPath).first { $0.contains(#"return "CLOSED""#) })
        XCTAssertFalse(readOnly.contains("click"))
        XCTAssertFalse(readOnly.contains("reopen"))
        XCTAssertFalse(readOnly.contains("set position"))
    }
}
