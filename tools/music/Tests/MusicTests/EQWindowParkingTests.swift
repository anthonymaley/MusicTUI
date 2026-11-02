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

    // MARK: - No fallback (Codex r1, 2026-11-02)

    /// `reopen` restores Music's main window, which breaks the ruling by
    /// construction, so it is gone entirely, not kept as a fallback.
    func testNothingEverReopensMusic() throws {
        XCTAssertFalse(try toggleScript().contains("reopen"))
        XCTAssertFalse(try presetScript().contains("reopen"))
    }

    /// Closing windows by name could close a person's own Music window.
    func testNoWindowIsEverClosed() throws {
        let script = try toggleScript()
        XCTAssertFalse(script.contains("AXCloseButton"))
        XCTAssertFalse(script.contains("windowNamesBeforeReopen"))
    }

    /// A window that did not appear after the plain click is an error the
    /// person can act on, raised before any control is touched.
    func testAWindowThatDidNotOpenIsAnErrorBeforeTheBody() throws {
        let scriptLines = lines(try toggleScript())
        let refusal = try XCTUnwrap(scriptLines.firstIndex {
            $0.hasPrefix(#"if not (exists window "Equalizer") then error"#)
                && $0.contains("Equalizer didn't open without bringing Music forward")
        }, "a window that did not open must raise, not fall back")
        let control = try XCTUnwrap(scriptLines.firstIndex(of: controlBlock))
        XCTAssertLessThan(refusal, control)
    }

    /// A park that fails raises instead of being swallowed, so the body never
    /// toggles a window that may be on screen.
    func testAFailedParkRaisesInsteadOfRunningTheBody() throws {
        let scriptLines = lines(try toggleScript())
        let park = try XCTUnwrap(scriptLines.firstIndex(of: parkLine))
        let tryEnd = try XCTUnwrap(scriptLines[park...].firstIndex(of: "end try"), "the park sits in a try")
        let handler = scriptLines[(park + 1)..<tryEnd]
        XCTAssertTrue(handler.contains { $0.hasPrefix("on error") }, "a failed park is handled")
        XCTAssertTrue(handler.contains { $0.hasPrefix("error ") }, "and the handler raises")
        XCTAssertLessThan(tryEnd, try XCTUnwrap(scriptLines.firstIndex(of: controlBlock)))
    }

    /// The missing-preset path used `key code 53`, an Escape sent to the
    /// FRONTMOST app, which is the person's terminal now that Music stays
    /// behind. It must close Music's own popup menu instead.
    func testAMissingPresetSendsNoKeystroke() throws {
        let script = try presetScript()
        XCTAssertFalse(script.contains("key code"))
        XCTAssertFalse(script.contains("keystroke"))
        XCTAssertTrue(script.contains(#"perform action "AXCancel" of menu 1"#),
                      "the popup is closed through Music's own menu")
    }

    // MARK: - An Accessibility denial at the click (Codex r2, 2026-11-02)

    /// The menu click's `try` swallowed every error, so a denial there became
    /// "the Equalizer didn't open" and lost the permission hint. The handler
    /// must re-raise a denial, classified by the same signals
    /// `isAssistiveAccessDenial` uses, and ignore anything else as before.
    func testTheClickReRaisesAnAccessibilityDenial() throws {
        let scriptLines = lines(try toggleScript())
        let click = try XCTUnwrap(scriptLines.firstIndex(of: menuClick))
        let tryEnd = try XCTUnwrap(scriptLines[click...].firstIndex(of: "end try"), "the click sits in a try")
        let handler = scriptLines[(click + 1)..<tryEnd]
        XCTAssertTrue(handler.contains("on error clickErrorText number clickErrorNumber"),
                      "the click's failure is caught with its text and number")
        let reRaise = try XCTUnwrap(handler.firstIndex(of: "error clickErrorText number clickErrorNumber"),
                                    "a denial is raised again, number kept")
        let condition = try XCTUnwrap(handler[..<reRaise].last { $0.hasPrefix("if ") && $0.hasSuffix(" then") })
        for signal in ["-1719", "-25211", "assistive"] {
            XCTAssertTrue(condition.contains(signal), "the re-raise misses the \(signal) signal: \(condition)")
        }
        XCTAssertTrue(isAssistiveAccessDenial("assistive") && isAssistiveAccessDenial("-1719") && isAssistiveAccessDenial("-25211"),
                      "the script's signals must stay the Swift classifier's")
    }

    /// End to end through a fake that answers as a denial raised at the click
    /// would arrive: the person gets the Accessibility hint, not the
    /// not-opened sentence. (The fake cannot execute AppleScript, so the
    /// swallowing itself is pinned by the structural test above.)
    func testADenialAtTheClickSurfacesTheAccessibilityHint() throws {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let scriptPath = dir.appendingPathComponent("eq-click-denial-fake-\(id).sh").path
        let fake = """
            #!/bin/sh
            printf '%s\\n' "0:301: execution error: System Events got an error: osascript is not allowed assistive access. (-1719)" >&2
            exit 1
            """
        try fake.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        let backend = AppleScriptBackend(executable: scriptPath)
        XCTAssertThrowsError(try eqSetEnabled(backend, true)) { error in
            XCTAssertEqual(error.localizedDescription,
                           AppleScriptBackend.ScriptError.executionFailed(eqAccessibilityHint).localizedDescription)
        }
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
