import XCTest
@testable import music

/// Codex r1 (2026-11-02): when the Equalizer cannot open without bringing
/// Music forward, or cannot be parked, EQ refuses with a sentence the person
/// can act on, in the CLI and in the Output tab, rather than a raw AppleScript
/// error or a bare "Couldn't turn EQ on.".
///
/// A fake `osascript` fails every script with the given stderr; nothing here
/// reaches osascript or Music.
final class EQWindowRefusalTests: XCTestCase {

    static let notOpened =
        "Music's Equalizer didn't open without bringing Music forward. Open Music once (any window), then try again."
    static let notParked =
        "Couldn't move Music's Equalizer off-screen, so EQ was not changed."

    private func failingInterpreter(stderr: String) -> AppleScriptBackend {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let errPath = dir.appendingPathComponent("eq-refusal-stderr-\(id).txt").path
        let scriptPath = dir.appendingPathComponent("eq-refusal-fake-\(id).sh").path
        try? stderr.write(toFile: errPath, atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            cat "\(errPath)" >&2
            exit 1
            """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return AppleScriptBackend(executable: scriptPath)
    }

    private func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    func testTheCLIGetsTheNotOpenedSentence() {
        let backend = failingInterpreter(stderr:
            "0:812: execution error: System Events got an error: \(Self.notOpened) (-2700)\n")
        XCTAssertEqual(message { try eqSetEnabled(backend, true) }, Self.notOpened)
        XCTAssertEqual(message { try eqSetCurrent(backend, name: "Nightclub") }, Self.notOpened)
    }

    func testTheCLIGetsTheNotParkedSentence() {
        let backend = failingInterpreter(stderr:
            "0:900: execution error: System Events got an error: \(Self.notParked) Can't set position. (-10006)\n")
        XCTAssertEqual(message { try eqSetEnabled(backend, true) }, Self.notParked)
    }

    /// An Accessibility denial during the park keeps its number, so it is
    /// still reported as the Accessibility hint, not as a park failure.
    func testADeniedParkIsStillTheAccessibilityHint() {
        let backend = failingInterpreter(stderr:
            "0:900: execution error: System Events got an error: \(Self.notParked) osascript is not allowed assistive access. (-1719)\n")
        XCTAssertEqual(message { try eqSetEnabled(backend, true) },
                       AppleScriptBackend.ScriptError.executionFailed(eqAccessibilityHint).localizedDescription)
    }

    /// The Output tab's toast carries the same sentence.
    func testTheOutputTabToastsTheNotOpenedSentence() throws {
        let dir = NSTemporaryDirectory() + "eq-refusal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let status = StatusStore()
        let backend = failingInterpreter(stderr:
            "0:812: execution error: System Events got an error: \(Self.notOpened) (-2700)\n")
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, status: status, backend: backend)
        _ = s.handle(.char("e"))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && status.current() == nil { usleep(20_000) }
        XCTAssertEqual(status.current()?.text, Self.notOpened)
    }
}
