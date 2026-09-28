// tools/music/Tests/MusicTests/NamingSweepTests.swift
//
// The naming rule: every string a person reads names the non-SpanDAC output
// "MusicTUI" and never says "Music.app". Where a sentence has to name Apple's
// own player as the mechanism, it says "Apple's Music player". Type, case and
// function names, AppleScript text, code comments, process paths and log
// lines may keep "Music.app"; that is internal.
//
// Pure: no playback, no AppleScript, no network, no stores on disk. The last
// test reads this package's own source files, nothing else.
import ArgumentParser
import XCTest
@testable import music

final class NamingSweepTests: XCTestCase {

    private func assertNoMusicApp(_ sentences: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(sentences.isEmpty, file: file, line: line)
        for sentence in Set(sentences) {
            XCTAssertFalse(sentence.contains("Music.app"), sentence, file: file, line: line)
        }
    }

    func testNoPersonFacingStringSaysMusicApp() {
        var sentences: [String] = []
        let modes: [PlaybackMode] = [.musicApp, .source, .networkSource("ipad")]

        // Every refusal the matrix can give, on both axes, from both surfaces.
        let selections: [EffectiveSelection] = [
            .consistent(data: .open, output: .musicApp),
            .consistent(data: .spandacMac, output: .musicApp),
            .consistent(data: .spandacMac, output: .source),
            .consistent(data: .spandacMac, output: .networkSource("ipad")),
            .outputBlocked(stored: .source),
            .outputBlocked(stored: .networkSource("ipad")),
        ]
        for action in MusicTUIAction.allCases {
            sentences.append(cliBridgeNotServedReason(action))
            for surface in InvocationSurface.allCases {
                for mode in modes {
                    if case .refused(let why) = routeAction(action, in: mode, from: surface) { sentences.append(why) }
                }
                for selection in selections {
                    let routed = routeAction(action, selection: selection, from: surface)
                    if case .refused(let why) = routed.sound { sentences.append(why) }
                    if case .refused(let why) = routed.data { sentences.append(why) }
                }
            }
        }
        for mode in modes { sentences.append(OutputLock.cliModeChangedMessage(now: mode)) }

        // Provenance: every origin, down both play paths, and the add refusal.
        let origins: [SongOrigin] = [.catalog, .library, .bridgeLibrary, .bridgeCatalog]
        for origin in origins {
            let row = SongResult(index: 3, title: "T3", artist: "A", album: "", catalogId: "",
                                 origin: origin, bridgeID: nil)
            sentences.append(String(describing: bridgeRef(forCachedRow: row, index: 3)))
            sentences.append(String(describing: musicAppIndexRoute(forCachedRow: row, index: 3)))
        }
        sentences.append(bridgeRowsRefusal([SongResult(index: 2, title: "T", artist: "A", album: "", catalogId: "",
                                                       origin: .bridgeCatalog, bridgeID: "1")]) ?? "")

        // Play sync, CLI and TUI.
        let accessErrors: [MusicAccessError] = [
            .notRunning, .timedOut, .failed(MusicAccessSentence.automationNotPermitted),
            .failed(MusicAccessSentence.libraryNotLoaded), .failed(MusicAccessSentence.noMatch), .failed("-10004"),
        ]
        for error in accessErrors {
            sentences += [SyncPlaysSentence.musicAccessFailed(error, waiting: 1),
                          SyncPlaysSentence.musicAccessFailed(error, waiting: 0),
                          PlaySyncWorker.musicAccessSentence(error)]
        }
        sentences += [SyncPlaysSentence.recorded(1), SyncPlaysSentence.recorded(3),
                      SyncPlaysSentence.musicNotRunning(waiting: 2), SyncPlaysSentence.unconfirmedHeader(2),
                      PlaySyncWorker.recordedSentence(1), PlaySyncWorker.recordedSentence(2),
                      MusicAccessSentence.automationNotPermitted, MusicAccessSentence.libraryNotLoaded,
                      PlaylistsScene.bridgeMissingNote]

        assertNoMusicApp(sentences)
        XCTAssertTrue(sentences.contains(OutputLock.cliModeChangedMessage(now: .musicApp)))
        XCTAssertEqual(OutputLock.cliModeChangedMessage(now: .musicApp),
                       "Output changed to MusicTUI while this command ran; nothing was changed.")
    }

    /// `--help`, for the root command and every subcommand at every depth.
    func testNoHelpTextSaysMusicApp() {
        var help: [String] = []
        func walk(_ command: ParsableCommand.Type) {
            help.append(Music.helpMessage(for: command, columns: 200))
            command.configuration.subcommands.forEach(walk)
        }
        walk(Music.self)
        XCTAssertGreaterThan(help.count, 10)
        assertNoMusicApp(help)
    }

    /// Belt and braces for strings no walk above reaches (footers, toasts,
    /// render labels): no string literal in the sources says "Music.app",
    /// except the internal ones listed here, each with why it is internal.
    func testNoSourceStringLiteralSaysMusicApp() throws {
        let internalLiterals: [(file: String, text: String)] = [
            // A process-path match, never shown.
            ("MusicAppPauseConfirm.swift", "\"/Music.app/Contents/MacOS/Music\""),
            ("MusicPlayCountWriter.swift", "\"/Music.app/Contents/MacOS/Music\""),
            // A unified-log line (`Logger.notice`), for diagnostics.
            ("MusicPlayCountWriter.swift", "\"more than one Music.app is running"),
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        let literal = try NSRegularExpression(pattern: #""[^"\n]*Music\.app[^"\n]*""#)
        var found: [String] = []
        for url in files {
            let name = url.lastPathComponent
            var inMultiline = false
            for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let fences = code.components(separatedBy: "\"\"\"").count - 1
                if inMultiline, code.contains("Music.app") { found.append("\(name): \(code)") }
                if fences % 2 == 1 { inMultiline.toggle() }
                if inMultiline { continue }
                let range = NSRange(code.startIndex..., in: code)
                for match in literal.matches(in: code, range: range) {
                    let text = String(code[Range(match.range, in: code)!])
                    if internalLiterals.contains(where: { $0.file == name && text.hasPrefix($0.text) }) { continue }
                    found.append("\(name): \(text)")
                }
            }
        }
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }
}
