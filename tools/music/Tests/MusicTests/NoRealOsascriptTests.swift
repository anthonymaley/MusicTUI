import XCTest
@testable import music

/// The test process must never launch the real AppleScript interpreter. Two
/// reviewed harnesses (DiscoverLifecycleTests, SweepScriptExecutionTests) run
/// osascript directly on synthetic scripts that touch no application; nothing
/// else may. `AppleScriptBackend.runBlocking` refuses it under XCTest, and the
/// source audit below keeps a new direct launch from appearing unreviewed.
final class NoRealOsascriptTests: XCTestCase {
    private static let interpreter = "/usr/bin/" + "osascript"

    func testDefaultBackendRefusesTheRealInterpreterUnderXCTest() {
        let backend = AppleScriptBackend()
        XCTAssertThrowsError(try backend.runBlocking("return 1")) { error in
            guard case AppleScriptBackend.ScriptError.executionFailed(let msg) = error else {
                return XCTFail("expected executionFailed, got \(error)")
            }
            XCTAssertTrue(msg.contains("test process"), msg)
        }
    }

    func testDenyAlsoCatchesAnAliasOfTheRealInterpreter() throws {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("osa-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: Self.interpreter)
        defer { try? FileManager.default.removeItem(at: link) }
        let backend = AppleScriptBackend(executable: link.path)
        XCTAssertThrowsError(try backend.runBlocking("return 1"))
        XCTAssertThrowsError(try AppleScriptBackend(executable: "/usr/bin/../bin/osascript")
            .runBlocking("return 1"))
    }

    func testAsyncPathsAreDeniedToo() async {
        do {
            _ = try await AppleScriptBackend().run("return 1")
            XCTFail("should have thrown")
        } catch {}
        do {
            _ = try await AppleScriptBackend().runMusic("return 1")
            XCTFail("should have thrown")
        } catch {}
    }

    func testOnlyReviewedFilesNameTheRealInterpreter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = [
            "Sources/Backends/AppleScriptBackend.swift",
            "Tests/MusicTests/DiscoverLifecycleTests.swift",
            "Tests/MusicTests/SweepScriptExecutionTests.swift",
            "Tests/MusicTests/NoRealOsascriptTests.swift",
        ]
        var offenders: [String] = []
        var scanned = 0
        for dir in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(dir)
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return XCTFail("cannot enumerate \(base.path)")
            }
            for case let url as URL in en where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                let rel = dir + "/" + url.path.replacingOccurrences(of: base.path + "/", with: "")
                guard !allowed.contains(rel) else { continue }
                // The literal, or a spelled-out split of it.
                let squashed = text.replacingOccurrences(of: "\" + \"", with: "")
                    .replacingOccurrences(of: "\"+\"", with: "")
                if squashed.contains(Self.interpreter)
                    || (squashed.contains("\"/usr/bin\"") && squashed.contains("\"osascript\"")) {
                    offenders.append(rel)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "audit scanned too few files")
        XCTAssertEqual(offenders, [], "unreviewed direct reference to the real AppleScript interpreter")
    }
}
