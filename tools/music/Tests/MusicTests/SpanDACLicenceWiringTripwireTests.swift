// tools/music/Tests/MusicTests/SpanDACLicenceWiringTripwireTests.swift
//
// Codex review 100, should-fix 3. The licence reprobe and the composition-time
// prime are proven by tests that build the helpers directly, so deleting their
// PRODUCTION call sites would leave those tests green. These read the source,
// as `OutputLockSwitchTests` does for the lock, and pin the two call sites:
//
// - the TUI shell constructs one `LicenceReprobe` over its live coordinator
//   and ticks it inside its main loop;
// - `RoutingCoordinator.live` primes through `primeLicenceAtComposition`
//   (bounded, off the TUI's launch path), never `primeLicence` directly, and
//   reads through the short-deadline `macLicencePrime` client.
//
// Brittle by nature (source shape, not behaviour): a rename here is a prompt to
// re-check the wiring, not a reason to delete the test.
import XCTest

final class SpanDACLicenceWiringTripwireTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        return try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The code of `text` with `//` comments removed, line by line, so a call
    /// that is commented out does not count.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    /// The braced body that starts at the first `{` at or after `start`,
    /// matched by counting braces outside string literals.
    private func body(of text: String, from start: String.Index) -> Substring? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, previous: Character = " "
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return text[open...index] }
                }
            }
            previous = ch
            index = text.index(after: index)
        }
        return nil
    }

    /// Review finding 7's wiring: one reprobe, over the shell's live
    /// coordinator, ticked inside the main `while true` loop.
    func testTheShellConstructsAndTicksTheLicenceReprobeInItsMainLoop() throws {
        let shell = code(try source("TUI/Shell/Shell.swift"))
        XCTAssertTrue(shell.contains("let routing = RoutingCoordinator.live(surface: .tui)"),
                      "the shell no longer composes its coordinator through live")

        let construction = "let licenceReprobe = LicenceReprobe(routing: routing)"
        let constructions = shell.components(separatedBy: "LicenceReprobe(routing:").count - 1
        XCTAssertEqual(constructions, 1, "the shell must construct exactly one reprobe")
        guard let built = shell.range(of: construction) else {
            return XCTFail("the shell does not construct the reprobe over its coordinator")
        }
        guard let loop = shell.range(of: "while true", range: built.upperBound..<shell.endIndex),
              let loopBody = body(of: shell, from: loop.lowerBound) else {
            return XCTFail("no main loop after the reprobe's construction")
        }
        XCTAssertTrue(loopBody.contains("licenceReprobe.tick()"),
                      "the reprobe is not ticked inside the main loop")
    }

    /// Review finding 8's wiring: `live` primes through the bounded
    /// composition helper, with the short-deadline client, and never calls
    /// the synchronous `primeLicence` itself.
    func testLivePrimesThroughTheCompositionHelper() throws {
        let coordinator = code(try source("TUI/RoutingCoordinator.swift"))
        guard let live = coordinator.range(of: "static func live("),
              let liveBody = body(of: coordinator, from: live.lowerBound) else {
            return XCTFail("no live composition")
        }
        XCTAssertTrue(liveBody.contains("routing.primeLicenceAtComposition("),
                      "live does not prime through primeLicenceAtComposition")
        XCTAssertFalse(liveBody.contains(".primeLicence("),
                       "live calls primeLicence directly, on the launch path")
        XCTAssertTrue(liveBody.contains("SourceAppClient.macLicencePrime(observing: licence)"),
                      "live's prime does not read through the short-deadline client")
        XCTAssertTrue(liveBody.contains("socketExists: licenceSocketExists"),
                      "live's prime ignores the socket check it is given")
    }
}
