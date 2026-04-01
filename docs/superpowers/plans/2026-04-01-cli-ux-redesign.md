# CLI UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the music CLI with smart positional shortcuts, domain-specific result caches, and interactive TUI for browsing commands.

**Architecture:** Three new modules added to the existing Swift package: `ResultCache` (read/write domain-specific JSON caches), `TerminalUI` (raw-mode TUI primitives using ANSI + termios), and `SmartParser` (positional arg interpretation for speaker/play/add). Existing command structs are refactored to use smart parsing when invoked with positional args, falling through to interactive TUI when bare + TTY.

**Tech Stack:** Swift 5.9, swift-argument-parser 1.3+, macOS 14+, POSIX termios, ANSI escape codes

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `Sources/Models/ResultCache.swift` | Read/write `last-songs.json` and `last-speakers.json` |
| `Sources/TUI/Terminal.swift` | Raw mode, ANSI escape helpers, signal handler, cleanup |
| `Sources/TUI/ListPicker.swift` | Single-select navigable list (playlists) |
| `Sources/TUI/MultiSelectList.swift` | Multi-select list with action keys (songs, speakers) |
| `Sources/TUI/VolumeMixer.swift` | Per-speaker volume bars with left/right adjust |
| `Sources/Commands/RemoveCommand.swift` | New top-level `remove` command |
| `Tests/MusicTests/ResultCacheTests.swift` | Unit tests for cache read/write/lookup |
| `Tests/MusicTests/SmartParserTests.swift` | Unit tests for positional arg interpretation |

### Modified Files

| File | Changes |
|---|---|
| `Sources/Music.swift` | Add `Remove` subcommand |
| `Sources/Commands/SpeakerCommands.swift` | Replace subcommand routing with smart positional parser + TUI |
| `Sources/Commands/PlaybackCommands.swift` | Add positional args to `Play` (index, shuffle keyword) |
| `Sources/Commands/VolumeCommands.swift` | Add interactive TUI when bare + TTY |
| `Sources/Commands/SearchCommand.swift` | Write to songs cache after results |
| `Sources/Commands/DiscoveryCommands.swift` | Write to songs cache, add interactive TUI for bare similar/suggest |
| `Sources/Commands/AddCommand.swift` | Add index lookup from cache, add `--to` flag for playlist shortcut |
| `Sources/Commands/PlaylistCommands.swift` | Add index-based create/add, interactive TUI for bare `playlist` |

---

### Task 1: Result Cache Module

**Files:**
- Create: `tools/music/Sources/Models/ResultCache.swift`
- Create: `tools/music/Tests/MusicTests/ResultCacheTests.swift`

- [ ] **Step 1: Write failing tests for ResultCache**

```swift
// Tests/MusicTests/ResultCacheTests.swift
import XCTest
@testable import music

final class ResultCacheTests: XCTestCase {
    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("music-test-\(UUID().uuidString)")

    override func setUp() {
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
    }

    func testWriteAndReadSongs() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs: [SongResult] = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let loaded = try cache.readSongs()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].title, "Alpha")
        XCTAssertEqual(loaded[1].catalogId, "id2")
    }

    func testWriteAndReadSpeakers() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers: [SpeakerResult] = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
            SpeakerResult(index: 2, name: "MacBook Pro", selected: false, volume: 15),
        ]
        try cache.writeSpeakers(speakers)
        let loaded = try cache.readSpeakers()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Kitchen")
        XCTAssertEqual(loaded[1].volume, 15)
    }

    func testLookupSongByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let song = try cache.lookupSong(index: 2)
        XCTAssertEqual(song.title, "Beta")
    }

    func testLookupSongOutOfRange() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.lookupSong(index: 1)) { error in
            XCTAssertTrue(error is CacheError)
        }
    }

    func testLookupSpeakerByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
        ]
        try cache.writeSpeakers(speakers)
        let speaker = try cache.lookupSpeaker(index: 1)
        XCTAssertEqual(speaker.name, "Kitchen")
    }

    func testMissingCacheFileThrows() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.readSongs()) { error in
            XCTAssertTrue(error is CacheError)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/music && swift test --filter ResultCacheTests 2>&1 | head -30`
Expected: Compilation errors — `ResultCache`, `SongResult`, `SpeakerResult`, `CacheError` not defined.

- [ ] **Step 3: Implement ResultCache**

```swift
// Sources/Models/ResultCache.swift
import Foundation

struct SongResult: Codable, Equatable {
    let index: Int
    let title: String
    let artist: String
    let album: String
    let catalogId: String
}

struct SpeakerResult: Codable, Equatable {
    let index: Int
    let name: String
    let selected: Bool
    let volume: Int
}

enum CacheError: Error, LocalizedError {
    case noCache(String)
    case indexOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .noCache(let domain): return "No cached \(domain) results. Run a search or list command first."
        case .indexOutOfRange(let i): return "Index \(i) is out of range."
        }
    }
}

struct ResultCache {
    let directory: String

    init(directory: String? = nil) {
        if let dir = directory {
            self.directory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.directory = "\(home)/.config/music"
        }
    }

    private var songsPath: String { "\(directory)/last-songs.json" }
    private var speakersPath: String { "\(directory)/last-speakers.json" }

    // MARK: - Songs

    func writeSongs(_ songs: [SongResult]) throws {
        let data = try JSONEncoder().encode(songs)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: songsPath))
    }

    func readSongs() throws -> [SongResult] {
        guard FileManager.default.fileExists(atPath: songsPath) else {
            throw CacheError.noCache("songs")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: songsPath))
        return try JSONDecoder().decode([SongResult].self, from: data)
    }

    func lookupSong(index: Int) throws -> SongResult {
        let songs = try readSongs()
        guard let song = songs.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return song
    }

    // MARK: - Speakers

    func writeSpeakers(_ speakers: [SpeakerResult]) throws {
        let data = try JSONEncoder().encode(speakers)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: speakersPath))
    }

    func readSpeakers() throws -> [SpeakerResult] {
        guard FileManager.default.fileExists(atPath: speakersPath) else {
            throw CacheError.noCache("speakers")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: speakersPath))
        return try JSONDecoder().decode([SpeakerResult].self, from: data)
    }

    func lookupSpeaker(index: Int) throws -> SpeakerResult {
        let speakers = try readSpeakers()
        guard let speaker = speakers.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return speaker
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/music && swift test --filter ResultCacheTests 2>&1 | tail -20`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Models/ResultCache.swift tools/music/Tests/MusicTests/ResultCacheTests.swift
git commit -m "feat: add ResultCache module with domain-specific song/speaker caches"
```

---

### Task 2: Terminal Raw Mode and ANSI Helpers

**Files:**
- Create: `tools/music/Sources/TUI/Terminal.swift`

No automated tests — terminal raw mode requires a TTY. Verified manually in Task 8.

- [ ] **Step 1: Create Terminal.swift with raw mode and ANSI helpers**

```swift
// Sources/TUI/Terminal.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ANSICode {
    static let clearScreen = "\u{1B}[2J"
    static let cursorHome = "\u{1B}[H"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let altScreenOn = "\u{1B}[?1049h"
    static let altScreenOff = "\u{1B}[?1049l"
    static let clearLine = "\u{1B}[2K"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let inverse = "\u{1B}[7m"
    static let green = "\u{1B}[32m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }
}

enum KeyPress {
    case up, down, left, right
    case enter, space, escape
    case char(Character)

    static func read() -> KeyPress? {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = Darwin.read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { return nil }

        if n == 1 {
            switch buf[0] {
            case 0x0A, 0x0D: return .enter
            case 0x20: return .space
            case 0x1B: return .escape
            case 0x71: return .char("q")  // q
            case 0x70: return .char("p")  // p
            case 0x61: return .char("a")  // a
            case 0x63: return .char("c")  // c
            default:
                if let scalar = Unicode.Scalar(buf[0]) {
                    return .char(Character(scalar))
                }
                return nil
            }
        }

        // Escape sequences: ESC [ A/B/C/D
        if n == 3, buf[0] == 0x1B, buf[1] == 0x5B {
            switch buf[2] {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            default: return nil
            }
        }
        return nil
    }
}

class TerminalState {
    private var originalTermios: termios?
    private var isRaw = false

    static let shared = TerminalState()

    func enterRawMode() {
        guard !isRaw else { return }
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        print(ANSICode.altScreenOn + ANSICode.hideCursor, terminator: "")
        fflush(stdout)

        // Register signal handler for cleanup on Ctrl-C
        signal(SIGINT) { _ in
            TerminalState.shared.exitRawMode()
            exit(0)
        }
    }

    func exitRawMode() {
        guard isRaw, var original = originalTermios else { return }
        isRaw = false
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        print(ANSICode.showCursor + ANSICode.altScreenOff, terminator: "")
        fflush(stdout)
        signal(SIGINT, SIG_DFL)
    }
}

func isTTY() -> Bool {
    isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Terminal.swift
git commit -m "feat: add Terminal raw mode and ANSI helpers for TUI"
```

---

### Task 3: MultiSelectList TUI Component

**Files:**
- Create: `tools/music/Sources/TUI/MultiSelectList.swift`

- [ ] **Step 1: Create MultiSelectList**

This is the workhorse component — used by speaker picker, search results, and similar results.

```swift
// Sources/TUI/MultiSelectList.swift
import Foundation

struct MultiSelectItem {
    let label: String
    let sublabel: String
    var selected: Bool
}

enum MultiSelectAction {
    case confirmed([Int])     // Indices of selected items
    case played(Int)          // Index of highlighted item
    case addedToLibrary([Int]) // Indices to add
    case createPlaylist([Int]) // Indices for new playlist
    case cancelled
}

func runMultiSelectList(
    title: String,
    items: inout [MultiSelectItem],
    actions: [(key: Character, label: String, action: (Int, [Int]) -> MultiSelectAction)] = []
) -> MultiSelectAction {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    let pageSize = 20

    func selectedIndices() -> [Int] {
        items.enumerated().compactMap { $0.element.selected ? $0.offset : nil }
    }

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen
        out += "\(ANSICode.bold)\(title)\(ANSICode.reset)\n\n"

        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let item = items[i]
            let marker = item.selected ? "\(ANSICode.green)✓\(ANSICode.reset)" : " "
            let highlight = i == cursor ? ANSICode.inverse : ""
            let resetH = i == cursor ? ANSICode.reset : ""
            let sub = item.sublabel.isEmpty ? "" : " \(ANSICode.dim)— \(item.sublabel)\(ANSICode.reset)"
            out += " \(marker) \(highlight)\(i + 1). \(item.label)\(resetH)\(sub)\n"
        }

        let selected = selectedIndices()
        out += "\n\(ANSICode.dim)↑↓ navigate  ␣ select  "
        for a in actions {
            out += "\(a.key) \(a.label)  "
        }
        out += "q quit"
        if !selected.isEmpty {
            out += "  (\(selected.count) selected)"
        }
        out += "\(ANSICode.reset)"

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
        case .down:
            cursor = min(items.count - 1, cursor + 1)
        case .space:
            items[cursor].selected.toggle()
        case .char("q"), .escape:
            return .cancelled
        case .enter:
            let sel = selectedIndices()
            return .confirmed(sel.isEmpty ? [cursor] : sel)
        case .char(let c):
            for a in actions {
                if c == a.key {
                    return a.action(cursor, selectedIndices())
                }
            }
        default:
            break
        }
        render()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/MultiSelectList.swift
git commit -m "feat: add MultiSelectList TUI component"
```

---

### Task 4: ListPicker and VolumeMixer TUI Components

**Files:**
- Create: `tools/music/Sources/TUI/ListPicker.swift`
- Create: `tools/music/Sources/TUI/VolumeMixer.swift`

- [ ] **Step 1: Create ListPicker**

```swift
// Sources/TUI/ListPicker.swift
import Foundation

func runListPicker(title: String, items: [String]) -> Int? {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen
        out += "\(ANSICode.bold)\(title)\(ANSICode.reset)\n\n"

        let pageSize = 20
        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let highlight = i == cursor ? ANSICode.inverse : ""
            let resetH = i == cursor ? ANSICode.reset : ""
            out += " \(highlight) \(items[i]) \(resetH)\n"
        }

        out += "\n\(ANSICode.dim)↑↓ navigate  ⏎ select  q quit\(ANSICode.reset)"
        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(items.count - 1, cursor + 1)
        case .enter: return cursor
        case .char("q"), .escape: return nil
        default: break
        }
        render()
    }
}
```

- [ ] **Step 2: Create VolumeMixer**

```swift
// Sources/TUI/VolumeMixer.swift
import Foundation

struct MixerSpeaker {
    let name: String
    var volume: Int
}

func runVolumeMixer(
    speakers: inout [MixerSpeaker],
    onVolumeChange: (String, Int) -> Void
) {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    let barWidth = 20

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen
        out += "\(ANSICode.bold)Volume Mixer\(ANSICode.reset)\n\n"

        let maxNameLen = speakers.map(\.name.count).max() ?? 0

        for (i, spk) in speakers.enumerated() {
            let highlight = i == cursor ? ANSICode.inverse : ""
            let resetH = i == cursor ? ANSICode.reset : ""
            let padded = spk.name.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let filled = Int(Double(spk.volume) / 100.0 * Double(barWidth))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
            out += " \(highlight)\(padded)  [\(bar)] \(String(format: "%3d", spk.volume))%\(resetH)\n"
        }

        out += "\n\(ANSICode.dim)↑↓ speaker  ←→ volume (±5%)  0-9 quick-set  q quit\(ANSICode.reset)"
        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    var digitBuffer = ""

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
            digitBuffer = ""
        case .down:
            cursor = min(speakers.count - 1, cursor + 1)
            digitBuffer = ""
        case .left:
            speakers[cursor].volume = max(0, speakers[cursor].volume - 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .right:
            speakers[cursor].volume = min(100, speakers[cursor].volume + 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .char(let c) where c.isNumber:
            digitBuffer.append(c)
            if digitBuffer.count >= 2 {
                if let vol = Int(digitBuffer) {
                    speakers[cursor].volume = min(100, max(0, vol))
                    onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
                }
                digitBuffer = ""
            }
        case .char("q"), .escape:
            return
        default:
            digitBuffer = ""
        }
        render()
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/TUI/ListPicker.swift tools/music/Sources/TUI/VolumeMixer.swift
git commit -m "feat: add ListPicker and VolumeMixer TUI components"
```

---

### Task 5: Speaker Command — Smart Positional Parser

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`
- Create: `tools/music/Tests/MusicTests/SmartParserTests.swift`

- [ ] **Step 1: Write failing tests for speaker arg parsing**

```swift
// Tests/MusicTests/SmartParserTests.swift
import XCTest
@testable import music

final class SpeakerParserTests: XCTestCase {
    func testBareNameAdds() {
        let result = SpeakerParser.parse(["kitchen"])
        XCTAssertEqual(result, .add(name: "kitchen"))
    }

    func testNameWithVolumeAddsAndSetsVolume() {
        let result = SpeakerParser.parse(["kitchen", "40"])
        XCTAssertEqual(result, .addWithVolume(name: "kitchen", volume: 40))
    }

    func testNameWithStopRemoves() {
        let result = SpeakerParser.parse(["kitchen", "stop"])
        XCTAssertEqual(result, .remove(name: "kitchen"))
    }

    func testNameWithOnlyExclusiveSelects() {
        let result = SpeakerParser.parse(["airpods", "only"])
        XCTAssertEqual(result, .exclusive(name: "airpods"))
    }

    func testAllIntegersAreIndices() {
        let result = SpeakerParser.parse(["1", "2", "5"])
        XCTAssertEqual(result, .indices([1, 2, 5]))
    }

    func testMultiWordSpeakerName() {
        let result = SpeakerParser.parse(["anthony's", "macbook", "pro"])
        XCTAssertEqual(result, .add(name: "anthony's macbook pro"))
    }

    func testMultiWordNameWithVolume() {
        let result = SpeakerParser.parse(["macbook", "pro", "50"])
        XCTAssertEqual(result, .addWithVolume(name: "macbook pro", volume: 50))
    }

    func testEmptyArgsIsInteractive() {
        let result = SpeakerParser.parse([])
        XCTAssertEqual(result, .interactive)
    }

    func testListKeyword() {
        let result = SpeakerParser.parse(["list"])
        XCTAssertEqual(result, .list)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/music && swift test --filter SpeakerParserTests 2>&1 | head -20`
Expected: Compilation error — `SpeakerParser` not defined.

- [ ] **Step 3: Add SpeakerParser to SpeakerCommands.swift**

Add this above the existing `Speaker` struct in `SpeakerCommands.swift`:

```swift
enum SpeakerAction: Equatable {
    case interactive
    case list
    case add(name: String)
    case addWithVolume(name: String, volume: Int)
    case remove(name: String)
    case exclusive(name: String)
    case indices([Int])
}

struct SpeakerParser {
    static func parse(_ args: [String]) -> SpeakerAction {
        guard !args.isEmpty else { return .interactive }

        // "list" keyword
        if args.count == 1 && args[0].lowercased() == "list" {
            return .list
        }

        // All integers → index references
        let ints = args.compactMap { Int($0) }
        if ints.count == args.count {
            return .indices(ints)
        }

        let lastArg = args.last!.lowercased()

        // Last arg is "stop" → remove
        if lastArg == "stop" {
            let name = args.dropLast().joined(separator: " ")
            return .remove(name: name)
        }

        // Last arg is "only" → exclusive select
        if lastArg == "only" {
            let name = args.dropLast().joined(separator: " ")
            return .exclusive(name: name)
        }

        // Last arg is integer → name + volume
        if let vol = Int(lastArg), (0...100).contains(vol), args.count >= 2 {
            let name = args.dropLast().joined(separator: " ")
            return .addWithVolume(name: name, volume: vol)
        }

        // Otherwise → add by name
        let name = args.joined(separator: " ")
        return .add(name: name)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/music && swift test --filter SpeakerParserTests 2>&1 | tail -15`
Expected: All 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift tools/music/Tests/MusicTests/SmartParserTests.swift
git commit -m "feat: add SpeakerParser with smart positional arg interpretation"
```

---

### Task 6: Rewrite Speaker Command to Use Smart Parser + TUI

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`

- [ ] **Step 1: Replace Speaker struct with smart routing**

Replace the entire `Speaker` struct (lines 4-10 of SpeakerCommands.swift) with a new struct that uses variadic args and routes through `SpeakerParser`. Keep `SpeakerList`, `SpeakerSet`, `SpeakerAdd`, `SpeakerRemove`, `SpeakerStop` as hidden subcommands for backwards compatibility.

Replace the full contents of `SpeakerCommands.swift` with:

```swift
import ArgumentParser
import Foundation

// MARK: - Smart parser (tested in SmartParserTests)

enum SpeakerAction: Equatable {
    case interactive
    case list
    case add(name: String)
    case addWithVolume(name: String, volume: Int)
    case remove(name: String)
    case exclusive(name: String)
    case indices([Int])
}

struct SpeakerParser {
    static func parse(_ args: [String]) -> SpeakerAction {
        guard !args.isEmpty else { return .interactive }
        if args.count == 1 && args[0].lowercased() == "list" { return .list }
        let ints = args.compactMap { Int($0) }
        if ints.count == args.count { return .indices(ints) }
        let lastArg = args.last!.lowercased()
        if lastArg == "stop" {
            return .remove(name: args.dropLast().joined(separator: " "))
        }
        if lastArg == "only" {
            return .exclusive(name: args.dropLast().joined(separator: " "))
        }
        if let vol = Int(lastArg), (0...100).contains(vol), args.count >= 2 {
            return .addWithVolume(name: args.dropLast().joined(separator: " "), volume: vol)
        }
        return .add(name: args.joined(separator: " "))
    }
}

// MARK: - Main speaker command

struct Speaker: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage AirPlay speakers.",
        subcommands: [SpeakerList.self, SpeakerSet.self, SpeakerAdd.self, SpeakerRemove.self, SpeakerStop.self],
        defaultSubcommand: SpeakerSmart.self
    )
}

struct SpeakerSmart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "", abstract: "Smart speaker control.")
    @Argument(help: "Speaker name, index, volume, or keyword (stop/only/list)") var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let action = SpeakerParser.parse(args)
        let backend = AppleScriptBackend()

        switch action {
        case .interactive:
            guard isTTY() else {
                // Fall back to list when not a TTY
                try SpeakerList(json: json).run()
                return
            }
            try runSpeakerTUI()

        case .list:
            try SpeakerList(json: json).run()

        case .add(let name):
            let resolved = try resolveSpeakerName(name, backend: backend)
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
            }
            print("Added \(resolved).")

        case .addWithVolume(let name, let volume):
            let resolved = try resolveSpeakerName(name, backend: backend)
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
            }
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(resolved)\" to \(volume)")
            }
            print("Added \(resolved) [\(volume)].")

        case .remove(let name):
            let resolved = try resolveSpeakerName(name, backend: backend)
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to false")
            }
            print("Removed \(resolved).")

        case .exclusive(let name):
            let resolved = try resolveSpeakerName(name, backend: backend)
            _ = try syncRun {
                try await backend.runMusic("""
                    set allDevices to every AirPlay device
                    repeat with d in allDevices
                        set selected of d to false
                    end repeat
                """)
            }
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
            }
            print("Switched to \(resolved) only.")

        case .indices(let idxs):
            let cache = ResultCache()
            for idx in idxs {
                let speaker = try cache.lookupSpeaker(index: idx)
                _ = try syncRun {
                    try await backend.runMusic("set selected of AirPlay device \"\(speaker.name)\" to true")
                }
                print("Added \(speaker.name).")
            }
        }
    }

    private func runSpeakerTUI() throws {
        let devices = try fetchDevices()
        var items = devices.map {
            MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
        }

        let result = runMultiSelectList(title: "AirPlay Speakers", items: &items)

        let backend = AppleScriptBackend()
        switch result {
        case .confirmed(let indices):
            // Apply the selection state
            for (i, item) in items.enumerated() {
                let name = item.label
                let shouldSelect = indices.contains(i)
                _ = try syncRun {
                    try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(shouldSelect)")
                }
            }
            // Write updated state to speaker cache
            let cache = ResultCache()
            let speakerResults = items.enumerated().map { (i, item) in
                SpeakerResult(index: i + 1, name: item.label, selected: indices.contains(i), volume: 0)
            }
            try? cache.writeSpeakers(speakerResults)
            let activeNames = indices.map { items[$0].label }
            print("Active: \(activeNames.joined(separator: ", "))")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func fetchDevices() throws -> [[String: Any]] {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                set deviceList to every AirPlay device
                set output to ""
                repeat with d in deviceList
                    if output is not "" then set output to output & linefeed
                    set output to output & name of d & "|" & selected of d & "|" & sound volume of d & "|" & kind of d
                end repeat
                return output
            """)
        }
        let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        return lines.compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 4 else { return nil }
            return [
                "name": parts[0],
                "selected": parts[1] == "true",
                "volume": Int(parts[2]) ?? 0,
                "kind": parts[3]
            ]
        }
    }
}

// MARK: - Speaker name resolution (case-insensitive prefix match)

func resolveSpeakerName(_ input: String, backend: AppleScriptBackend) throws -> String {
    let result = try syncRun {
        try await backend.runMusic("get name of every AirPlay device")
    }
    let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    let lower = input.lowercased()

    // Exact match first
    if let exact = names.first(where: { $0.lowercased() == lower }) {
        return exact
    }

    // Prefix match
    if let prefix = names.first(where: { $0.lowercased().hasPrefix(lower) }) {
        return prefix
    }

    // Contains match
    if let contains = names.first(where: { $0.lowercased().contains(lower) }) {
        return contains
    }

    return input // Fall through to AppleScript which will error with the actual device name
}

// MARK: - Hidden subcommands (backwards compatibility)

struct SpeakerList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List AirPlay devices.", shouldDisplay: false)
    @Flag(name: .long, help: "Output JSON") var json = false

    init() {}
    init(json: Bool) { self._json = Flag(wrappedValue: json) }

    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                set deviceList to every AirPlay device
                set output to ""
                repeat with d in deviceList
                    if output is not "" then set output to output & linefeed
                    set output to output & name of d & "|" & selected of d & "|" & sound volume of d & "|" & kind of d
                end repeat
                return output
            """)
        }
        let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        let devices: [[String: Any]] = lines.compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 4 else { return nil }
            return [
                "name": parts[0],
                "selected": parts[1] == "true",
                "volume": Int(parts[2]) ?? 0,
                "kind": parts[3]
            ]
        }

        // Write to speaker cache
        let cache = ResultCache()
        let speakerResults = devices.enumerated().map { (i, d) in
            SpeakerResult(
                index: i + 1,
                name: d["name"] as! String,
                selected: d["selected"] as! Bool,
                volume: d["volume"] as! Int
            )
        }
        try? cache.writeSpeakers(speakerResults)

        if json {
            let output = OutputFormat(mode: .json)
            print(output.render(["devices": devices]))
        } else {
            for (i, d) in devices.enumerated() {
                let sel = (d["selected"] as? Bool == true) ? "▶" : " "
                print("\(sel) \(i + 1). \(d["name"]!) [\(d["volume"]!)]")
            }
        }
    }
}

struct SpeakerSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Switch to a single speaker.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try SpeakerSmart(args: [name, "only"], json: false).run()
    }
}

struct SpeakerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add speaker to group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try SpeakerSmart(args: [name], json: false).run()
    }
}

struct SpeakerRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove speaker from group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try SpeakerSmart(args: [name, "stop"], json: false).run()
    }
}

struct SpeakerStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Remove speaker (alias).", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try SpeakerSmart(args: [name, "stop"], json: false).run()
    }
}
```

**Note:** The `SpeakerSmart` struct needs an initializer that accepts args for the hidden alias delegation. Add this to `SpeakerSmart`:

```swift
init() {}
init(args: [String], json: Bool) {
    self._args = Argument(wrappedValue: args)
    self._json = Flag(wrappedValue: json)
}
```

- [ ] **Step 2: Verify it compiles and existing parser tests still pass**

Run: `cd tools/music && swift build 2>&1 | tail -5 && swift test --filter SpeakerParserTests 2>&1 | tail -10`
Expected: Build succeeds, all parser tests pass.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift
git commit -m "feat: rewrite speaker command with smart parser, TUI, and hidden aliases"
```

---

### Task 7: Search and Discovery Commands — Write to Songs Cache

**Files:**
- Modify: `tools/music/Sources/Commands/SearchCommand.swift`
- Modify: `tools/music/Sources/Commands/DiscoveryCommands.swift`

- [ ] **Step 1: Add cache writing to Search command**

In `SearchCommand.swift`, after the results are printed (before the closing `}`), add cache writing:

```swift
// After the songs are fetched and before printing, write to cache
let cache = ResultCache()
let songResults = songs.enumerated().map { (i, song) in
    SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
}
try? cache.writeSongs(songResults)
```

Insert this right after `let songs = try syncRun { ... }` and the empty check, before the output block.

- [ ] **Step 2: Add cache writing to Similar command**

In `DiscoveryCommands.swift`, in the `Similar.run()` method, before the output block, add:

```swift
let cache = ResultCache()
let songResults = similar.prefix(limit).enumerated().map { (i, song) in
    SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
}
try? cache.writeSongs(songResults)
```

- [ ] **Step 3: Add cache writing to Suggest command**

In the `Suggest.run()` method, before the output block, add the same pattern:

```swift
let cache = ResultCache()
let songResults = suggestions.enumerated().map { (i, song) in
    SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
}
try? cache.writeSongs(songResults)
```

- [ ] **Step 4: Add cache writing to NewReleases command**

Same pattern in `NewReleases.run()`:

```swift
let cache = ResultCache()
let songResults = releases.prefix(limit).enumerated().map { (i, r) in
    SongResult(index: i + 1, title: r.title, artist: r.artist, album: r.album, catalogId: r.id)
}
try? cache.writeSongs(songResults)
```

- [ ] **Step 5: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add tools/music/Sources/Commands/SearchCommand.swift tools/music/Sources/Commands/DiscoveryCommands.swift
git commit -m "feat: write search/similar/suggest/new-releases results to songs cache"
```

---

### Task 8: Play Command — Index Lookup and Shuffle Keyword

**Files:**
- Modify: `tools/music/Sources/Commands/PlaybackCommands.swift`

- [ ] **Step 1: Add positional args to Play command**

Replace the `Play` struct in `PlaybackCommands.swift` with:

```swift
struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Play or resume music.")

    @Argument(help: "Playlist name, result index, or 'shuffle'") var args: [String] = []
    @Option(name: .long, help: "Playlist name") var playlist: String?
    @Option(name: .long, help: "Song name") var song: String?
    @Option(name: .long, help: "Artist name") var artist: String?
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()
        let output = OutputFormat(mode: json ? .json : .human)

        // Existing flag-based behavior takes priority
        if let playlist = playlist {
            let result = try syncRun {
                try await backend.runMusic("""
                    set shuffle enabled to true
                    play playlist "\(playlist)"
                    return name of current track & "|" & artist of current track
                """)
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1]), "playlist": playlist]))
            }
            return
        }

        if let song = song {
            let artistFilter = artist.map { " and artist contains \"\($0)\"" } ?? ""
            let result = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name contains "\(song)"\(artistFilter))
                    if (count of results) > 0 then
                        play item 1 of results
                        return name of current track & "|" & artist of current track
                    else
                        return "NOT_FOUND"
                    end if
                """)
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "NOT_FOUND" {
                print("No tracks found matching '\(song)'")
                throw ExitCode.failure
            }
            let parts = trimmed.split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
            }
            return
        }

        // Smart positional args
        if !args.isEmpty {
            // Single integer → play from cache
            if args.count == 1, let index = Int(args[0]) {
                let cache = ResultCache()
                let song = try cache.lookupSong(index: index)
                // Search library for the track, play it
                let escapedTitle = song.title.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedArtist = song.artist.replacingOccurrences(of: "\"", with: "\\\"")
                let result = try syncRun {
                    try await backend.runMusic("""
                        set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                        if (count of results) = 0 then
                            set results to (every track of playlist "Library" whose name contains "\(escapedTitle)")
                        end if
                        if (count of results) > 0 then
                            play item 1 of results
                            return name of current track & "|" & artist of current track
                        else
                            return "NOT_FOUND"
                        end if
                    """)
                }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "NOT_FOUND" {
                    print("'\(song.title)' not in library. Run: music add \(index)")
                    throw ExitCode.failure
                }
                let parts = trimmed.split(separator: "|")
                if parts.count >= 2 {
                    print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
                }
                return
            }

            // Check for trailing "shuffle" keyword
            let hasShuffle = args.last?.lowercased() == "shuffle"
            let nameArgs = hasShuffle ? Array(args.dropLast()) : args
            let playlistName = nameArgs.joined(separator: " ")

            if hasShuffle {
                _ = try syncRun {
                    try await backend.runMusic("set shuffle enabled to true")
                }
            }

            let result = try syncRun {
                try await backend.runMusic("""
                    play playlist "\(playlistName)"
                    return name of current track & "|" & artist of current track
                """)
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1]), "playlist": playlistName]))
            }
            return
        }

        // No args → resume
        let result = try syncRun {
            try await backend.runMusic("""
                play
                return name of current track & "|" & artist of current track
            """)
        }
        let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        if parts.count >= 2 {
            print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Commands/PlaybackCommands.swift
git commit -m "feat: add index lookup and shuffle keyword to play command"
```

---

### Task 9: Add Command — Index Lookup and --to Playlist Flag

**Files:**
- Modify: `tools/music/Sources/Commands/AddCommand.swift`

- [ ] **Step 1: Rewrite Add command with index support and --to flag**

Replace the full contents of `AddCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library, or add to a playlist.")
    @Argument(help: "Search query or result index") var query: [String] = []
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Option(name: .long, help: "Add to playlist(s)") var to: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        // Determine what to add
        var songToAdd: CatalogSong?
        var trackTitle: String?
        var trackArtist: String?

        if let catalogID = id {
            try syncRun { try await api.addToLibrary(songIDs: [catalogID]) }
            if to.isEmpty {
                print(json ? "{\"added\":\"\(catalogID)\"}" : "Added (id: \(catalogID)).")
                return
            }
            // For playlist add, we need the track info — skip to playlist section
            trackTitle = nil // Will use catalog ID path below
        } else if query.count == 1, let index = Int(query[0]) {
            // Index from cache
            let cache = ResultCache()
            let song = try cache.lookupSong(index: index)
            songToAdd = CatalogSong(id: song.catalogId, title: song.title, artist: song.artist, album: song.album)
        } else if !query.isEmpty {
            // Search query
            let searchQuery = query.joined(separator: " ")
            let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
            guard let song = songs.first else {
                print("No results for '\(searchQuery)'")
                throw ExitCode.failure
            }
            songToAdd = song
        } else if !to.isEmpty {
            // No query, no index → current song
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & \"|\" & artist of current track")
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                trackTitle = String(parts[0])
                trackArtist = String(parts[1])
            }
        } else {
            print("Usage: music add <query>, music add <index>, or music add --to <playlist>")
            throw ExitCode.failure
        }

        // Add to library if we have a catalog song
        if let song = songToAdd {
            print("Found: \(song.title) — \(song.artist) [\(song.album)]")
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
            trackTitle = song.title
            trackArtist = song.artist

            if to.isEmpty {
                if json {
                    let output = OutputFormat(mode: .json)
                    print(output.render(["added": true, "track": song.title, "artist": song.artist, "id": song.id]))
                } else {
                    print("Added to library.")
                }
                return
            }
        }

        // Add to playlist(s) if --to specified
        if !to.isEmpty, let title = trackTitle, let artist = trackArtist {
            let backend = AppleScriptBackend()
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedArtist = artist.replacingOccurrences(of: "\"", with: "\\\"")

            // Wait for library sync if we just added
            if songToAdd != nil {
                try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            }

            for pl in to {
                _ = try syncRun {
                    try await backend.runMusic("""
                        set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                        if (count of results) = 0 then
                            set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                        end if
                        if (count of results) > 0 then
                            duplicate item 1 of results to playlist "\(pl)"
                        end if
                    """)
                }
                print("Added to '\(pl)'.")
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Commands/AddCommand.swift
git commit -m "feat: add index lookup and --to playlist flag to add command"
```

---

### Task 10: New Top-Level Remove Command

**Files:**
- Create: `tools/music/Sources/Commands/RemoveCommand.swift`
- Modify: `tools/music/Sources/Music.swift`

- [ ] **Step 1: Create RemoveCommand.swift**

```swift
// Sources/Commands/RemoveCommand.swift
import ArgumentParser
import Foundation

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove current song from a playlist.")
    @Argument(help: "Playlist name, or 'all' to remove from all playlists") var target: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()

        // Get current track
        let trackResult = try syncRun {
            try await backend.runMusic("return name of current track & \"|\" & artist of current track")
        }
        let parts = trackResult.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count >= 2 else {
            print("Nothing playing.")
            throw ExitCode.failure
        }
        let title = String(parts[0])
        let artist = String(parts[1])
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")

        if target.isEmpty {
            // Remove from currently playing playlist
            let playlistResult = try syncRun {
                try await backend.runMusic("""
                    if exists current playlist then
                        return name of current playlist
                    else
                        return "NO_PLAYLIST"
                    end if
                """)
            }
            let playlistName = playlistResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if playlistName == "NO_PLAYLIST" {
                print("Not playing from a playlist.")
                throw ExitCode.failure
            }
            _ = try syncRun {
                try await backend.runMusic("""
                    set t to (first track of playlist "\(playlistName)" whose name contains "\(escapedTitle)")
                    delete t
                """)
            }
            print("Removed '\(title)' from '\(playlistName)'.")

        } else if target.count == 1 && target[0].lowercased() == "all" {
            // Remove from all playlists
            let allPlaylists = try syncRun {
                try await backend.runMusic("get name of every user playlist")
            }
            let names = allPlaylists.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var removedFrom: [String] = []
            for pl in names {
                let checkResult = try? syncRun {
                    try await backend.runMusic("""
                        set matches to (every track of playlist "\(pl)" whose name contains "\(escapedTitle)")
                        return (count of matches) as text
                    """)
                }
                if let count = checkResult, Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0 {
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set t to (first track of playlist "\(pl)" whose name contains "\(escapedTitle)")
                            delete t
                        """)
                    }
                    removedFrom.append(pl)
                }
            }
            if removedFrom.isEmpty {
                print("'\(title)' not found in any playlist.")
            } else {
                print("Removed '\(title)' from: \(removedFrom.joined(separator: ", "))")
            }

        } else {
            // Remove from named playlist
            let playlistName = target.joined(separator: " ")
            _ = try syncRun {
                try await backend.runMusic("""
                    set t to (first track of playlist "\(playlistName)" whose name contains "\(escapedTitle)")
                    delete t
                """)
            }
            print("Removed '\(title)' from '\(playlistName)'.")
        }
    }
}
```

- [ ] **Step 2: Add Remove to Music.swift subcommands**

In `Sources/Music.swift`, add `Remove.self` after `Add.self` in the subcommands array:

```swift
Add.self,
Remove.self,
```

- [ ] **Step 3: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/Commands/RemoveCommand.swift tools/music/Sources/Music.swift
git commit -m "feat: add top-level remove command for playlist track removal"
```

---

### Task 11: Discovery Interactive TUI (Similar/Suggest)

**Files:**
- Modify: `tools/music/Sources/Commands/DiscoveryCommands.swift`

- [ ] **Step 1: Add interactive mode to Similar command**

In the `Similar` struct, replace the output section (the `if json { ... } else { ... }` block at the end) with TUI-aware rendering:

```swift
// Write to cache
let cache = ResultCache()
let songResults = similar.prefix(limit).enumerated().map { (i, s) in
    SongResult(index: i + 1, title: s.title, artist: s.artist, album: s.album, catalogId: s.id)
}
try? cache.writeSongs(songResults)

let output = OutputFormat(mode: json ? .json : .human)
if json {
    print(output.render(similar.prefix(limit).map { $0.toDict() }))
} else if title == nil && artist == nil && limit == 10 && !json && isTTY() {
    // Bare "music similar" with TTY → interactive (default limit means bare invocation)
    var items = Array(similar.prefix(limit)).map {
        MultiSelectItem(label: "\($0.title) — \($0.artist)", sublabel: $0.album, selected: false)
    }
    let songsCopy = Array(similar.prefix(limit))
    let action = runMultiSelectList(
        title: "Similar to: \(song.title) — \(song.artist)",
        items: &items,
        actions: [
            (key: "p", label: "play", action: { cursor, _ in .played(cursor) }),
            (key: "a", label: "add", action: { cursor, selected in
                .addedToLibrary(selected.isEmpty ? [cursor] : selected)
            }),
            (key: "c", label: "create playlist", action: { _, selected in
                .createPlaylist(selected)
            }),
        ]
    )
    try handleSongAction(action, songs: songsCopy, api: api)
} else {
    print("Similar to: \(song.title) — \(song.artist)")
    for (i, s) in similar.prefix(limit).enumerated() {
        print("\(i + 1). \(s.title) — \(s.artist) [\(s.album)]")
    }
}
```

- [ ] **Step 2: Add handleSongAction helper function**

Add this as a free function at the bottom of `DiscoveryCommands.swift`:

```swift
func handleSongAction(_ action: MultiSelectAction, songs: [CatalogSong], api: RESTAPIBackend) throws {
    let backend = AppleScriptBackend()
    switch action {
    case .played(let idx):
        let song = songs[idx]
        let escapedTitle = song.title.replacingOccurrences(of: "\"", with: "\\\"")
        let result = try syncRun {
            try await backend.runMusic("""
                set results to (every track of playlist "Library" whose name contains "\(escapedTitle)")
                if (count of results) > 0 then
                    play item 1 of results
                    return "OK"
                else
                    return "NOT_FOUND"
                end if
            """)
        }
        if result.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
            // Add to library first, then play
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
            try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            _ = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name contains "\(escapedTitle)")
                    if (count of results) > 0 then play item 1 of results
                """)
            }
        }
        print("Playing: \(song.title) — \(song.artist)")

    case .addedToLibrary(let indices):
        let ids = indices.map { songs[$0].id }
        try syncRun { try await api.addToLibrary(songIDs: ids) }
        print("Added \(ids.count) track(s) to library.")

    case .createPlaylist(let indices):
        guard !indices.isEmpty else {
            print("No tracks selected.")
            return
        }
        // Use timestamp-based name, user can rename later
        let name = "New Playlist \(Int(Date().timeIntervalSince1970) % 100000)"
        let ids = indices.map { songs[$0].id }
        try syncRun { try await api.addToLibrary(songIDs: ids) }
        _ = try syncRun {
            try await backend.runMusic("make new playlist with properties {name:\"\(name)\"}")
        }
        try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
        for idx in indices {
            let s = songs[idx]
            let et = s.title.replacingOccurrences(of: "\"", with: "\\\"")
            let ea = s.artist.replacingOccurrences(of: "\"", with: "\\\"")
            _ = try? syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                    if (count of results) = 0 then
                        set results to (every track of playlist "Library" whose name contains "\(et)")
                    end if
                    if (count of results) > 0 then
                        duplicate item 1 of results to playlist "\(name)"
                    end if
                """)
            }
        }
        print("Created '\(name)' with \(indices.count) tracks.")

    case .confirmed, .cancelled:
        break
    }
}
```

- [ ] **Step 3: Apply same interactive pattern to Suggest**

In `Suggest.run()`, replace the output section with the same TUI-aware pattern. Bare `suggest` (no `from` flag, TTY) goes interactive:

```swift
// Write to cache
let cache = ResultCache()
let songResults = suggestions.enumerated().map { (i, song) in
    SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
}
try? cache.writeSongs(songResults)

let output = OutputFormat(mode: json ? .json : .human)
if json {
    print(output.render(suggestions.map { $0.toDict() }))
} else if from == nil && !json && isTTY() && count == 10 {
    // Bare "music suggest" with TTY → interactive (default count means bare invocation)
    var items = suggestions.map {
        MultiSelectItem(label: "\($0.title) — \($0.artist)", sublabel: $0.album, selected: false)
    }
    let songsCopy = Array(suggestions)
    let action = runMultiSelectList(
        title: "Suggestions",
        items: &items,
        actions: [
            (key: "p", label: "play", action: { cursor, _ in .played(cursor) }),
            (key: "a", label: "add", action: { cursor, selected in
                .addedToLibrary(selected.isEmpty ? [cursor] : selected)
            }),
            (key: "c", label: "create playlist", action: { _, selected in
                .createPlaylist(selected)
            }),
        ]
    )
    try handleSongAction(action, songs: songsCopy, api: api)
} else {
    for (i, s) in suggestions.enumerated() {
        print("\(i + 1). \(s.title) — \(s.artist) [\(s.album)]")
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/DiscoveryCommands.swift
git commit -m "feat: add interactive TUI to similar and suggest commands"
```

---

### Task 12: Playlist Command — Index-Based Add/Create and Interactive TUI

**Files:**
- Modify: `tools/music/Sources/Commands/PlaylistCommands.swift`

- [ ] **Step 1: Update PlaylistCreate to accept result indices**

In `PlaylistCreate`, change the `name` argument to required and add optional indices:

```swift
struct PlaylistCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Argument(help: "Result indices to add (from last search/similar)") var indices: [Int] = []
    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        let body: [String: Any] = ["attributes": ["name": name]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try syncRun { try await api.post("/v1/me/library/playlists", body: bodyData) }
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }

        if indices.isEmpty {
            print("Created playlist '\(name)'.")
            return
        }

        // Add indexed songs from cache
        let cache = ResultCache()
        var addedCount = 0
        var ids: [String] = []
        for idx in indices {
            if let song = try? cache.lookupSong(index: idx) {
                ids.append(song.catalogId)
            }
        }

        if !ids.isEmpty {
            try syncRun { try await api.addToLibrary(songIDs: ids) }
            try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }

            for idx in indices {
                if let song = try? cache.lookupSong(index: idx) {
                    let et = song.title.replacingOccurrences(of: "\"", with: "\\\"")
                    let ea = song.artist.replacingOccurrences(of: "\"", with: "\\\"")
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                            if (count of results) = 0 then
                                set results to (every track of playlist "Library" whose name contains "\(et)")
                            end if
                            if (count of results) > 0 then
                                duplicate item 1 of results to playlist "\(name)"
                            end if
                        """)
                    }
                    addedCount += 1
                    print("  + \(song.title) — \(song.artist)")
                }
            }
        }

        print("Created '\(name)' with \(addedCount) tracks.")
    }
}
```

- [ ] **Step 2: Update PlaylistAdd to accept result indices**

Replace `PlaylistAdd`:

```swift
struct PlaylistAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add track(s) to playlist.")
    @Argument(help: "Playlist name") var playlist: String
    @Argument(help: "Song title or result indices") var items: [String] = []
    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        // Check if items are all integers (index mode)
        let ints = items.compactMap { Int($0) }
        if ints.count == items.count && !ints.isEmpty {
            // Index mode: add from cache
            let cache = ResultCache()
            var ids: [String] = []
            var songs: [SongResult] = []
            for idx in ints {
                if let song = try? cache.lookupSong(index: idx) {
                    ids.append(song.catalogId)
                    songs.append(song)
                }
            }

            if !ids.isEmpty {
                try syncRun { try await api.addToLibrary(songIDs: ids) }
                try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }

                for song in songs {
                    let et = song.title.replacingOccurrences(of: "\"", with: "\\\"")
                    let ea = song.artist.replacingOccurrences(of: "\"", with: "\\\"")
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                            if (count of results) = 0 then
                                set results to (every track of playlist "Library" whose name contains "\(et)")
                            end if
                            if (count of results) > 0 then
                                duplicate item 1 of results to playlist "\(playlist)"
                            end if
                        """)
                    }
                    print("  + \(song.title) — \(song.artist)")
                }
                print("Added \(songs.count) track(s) to '\(playlist)'.")
            }
            return
        }

        // Legacy mode: title [artist] as positional args
        let title = items.first ?? ""
        let artist: String? = items.count > 1 ? items.dropFirst().joined(separator: " ") : nil

        var searchQuery = title
        if let artist = artist { searchQuery += " \(artist)" }

        let foundSongs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
        guard let song = foundSongs.first else {
            print("No results for '\(searchQuery)'")
            throw ExitCode.failure
        }
        print("Found: \(song.title) — \(song.artist)")

        try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
        try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }

        let escapedTitle = song.title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedArtist = song.artist.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try syncRun {
            try await backend.runMusic("""
                set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                if (count of results) = 0 then
                    set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                end if
                if (count of results) > 0 then
                    duplicate item 1 of results to playlist "\(playlist)"
                end if
            """)
        }
        print("Added to '\(playlist)'.")
    }
}
```

- [ ] **Step 3: Add interactive TUI to bare `music playlist`**

Add a default subcommand to the `Playlist` struct that launches the TUI when bare + TTY:

```swift
struct Playlist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage playlists.",
        subcommands: [
            PlaylistBrowse.self,
            PlaylistList.self,
            PlaylistTracks.self,
            PlaylistCreate.self,
            PlaylistDelete.self,
            PlaylistAdd.self,
            PlaylistRemove.self,
            PlaylistShare.self,
            PlaylistTemp.self,
            PlaylistCreateFrom.self,
            PlaylistCleanup.self,
        ],
        defaultSubcommand: PlaylistBrowse.self
    )
}

struct PlaylistBrowse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "", abstract: "Browse playlists interactively.")

    func run() throws {
        guard isTTY() else {
            try PlaylistList().run()
            return
        }

        // Fetch playlist names
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("get name of every user playlist")
        }
        let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard !names.isEmpty else {
            print("No playlists found.")
            return
        }

        if let selected = runListPicker(title: "Playlists", items: names) {
            let playlistName = names[selected]
            // Show tracks for selected playlist
            try PlaylistTracks(name: playlistName, json: false).run()
        }
    }
}
```

Note: `PlaylistTracks` needs an initializer. Add:

```swift
init() {}
init(name: String, json: Bool) {
    self._name = Argument(wrappedValue: name)
    self._json = Flag(wrappedValue: json)
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/PlaylistCommands.swift
git commit -m "feat: add index-based playlist add/create and interactive TUI browse"
```

---

### Task 13: Volume Command — Interactive TUI

**Files:**
- Modify: `tools/music/Sources/Commands/VolumeCommands.swift`

- [ ] **Step 1: Add interactive TUI to bare volume command**

In `VolumeCommands.swift`, replace the `args.isEmpty` block with TUI-aware code:

```swift
if args.isEmpty {
    if !json && isTTY() {
        // Interactive volume mixer
        let result = try syncRun {
            try await backend.runMusic("""
                set deviceList to every AirPlay device
                set output to ""
                repeat with d in deviceList
                    if selected of d then
                        if output is not "" then set output to output & linefeed
                        set output to output & name of d & "|" & sound volume of d
                    end if
                end repeat
                return output
            """)
        }
        let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        var speakers: [MixerSpeaker] = lines.compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count >= 2, let vol = Int(parts[1]) else { return nil }
            return MixerSpeaker(name: parts[0], volume: vol)
        }

        runVolumeMixer(speakers: &speakers) { name, volume in
            _ = try? syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(volume)")
            }
        }
        return
    }

    // Non-interactive: show current volumes
    let result = try syncRun {
        try await backend.runMusic("""
            set deviceList to every AirPlay device
            set output to ""
            repeat with d in deviceList
                if selected of d then
                    if output is not "" then set output to output & ","
                    set output to output & name of d & ":" & sound volume of d
                end if
            end repeat
            return output
        """)
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    let speakers = trimmed.split(separator: ",").map { pair -> [String: Any] in
        let kv = pair.split(separator: ":", maxSplits: 1)
        return ["name": String(kv[0]), "volume": Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0]
    }
    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["speakers": speakers]))
    } else {
        for s in speakers {
            print("\(s["name"]!) [\(s["volume"]!)]")
        }
    }
    return
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Commands/VolumeCommands.swift
git commit -m "feat: add interactive volume mixer TUI"
```

---

### Task 14: Build, Install, and Manual Smoke Test

**Files:**
- No new files — this is verification only.

- [ ] **Step 1: Build the full project**

Run: `cd tools/music && swift build -c release 2>&1 | tail -10`
Expected: Build succeeds with no errors or warnings.

- [ ] **Step 2: Run all unit tests**

Run: `cd tools/music && swift test 2>&1 | tail -20`
Expected: All tests pass (ResultCacheTests + SpeakerParserTests).

- [ ] **Step 3: Install the binary**

Run: `cp tools/music/.build/release/music ~/.local/bin/music`

- [ ] **Step 4: Manual smoke test — non-interactive commands**

Run these and verify expected output:

```bash
# Speaker shortcuts
music speaker list              # Should show numbered list with indices
music speaker kitchen           # Should add kitchen (or prefix match)
music speaker kitchen 40        # Should add and set volume
music speaker kitchen stop      # Should remove kitchen

# Play shortcuts
music play                      # Should resume
music search house              # Should show numbered results AND write cache

# Cache-based commands
music play 1                    # Should play result #1 from last search
music add 1                     # Should add result #1 to library
music add --to "Working Vibes"  # Should add current song to playlist

# Remove
music remove                    # Should remove current from current playlist

# Volume
music volume 40                 # Should set all to 40
music volume kitchen 60         # Should set kitchen to 60
```

- [ ] **Step 5: Manual smoke test — interactive TUI**

Run these and verify TUI renders correctly:

```bash
music speaker                   # TUI: speaker picker with toggle
music similar                   # TUI: results browser with p/a/c actions
music volume                    # TUI: volume mixer with bars
music playlist                  # TUI: playlist browser
```

Verify in each: arrow keys navigate, q quits, terminal restores cleanly.

- [ ] **Step 6: Verify Ctrl-C cleanup**

For each TUI command, press Ctrl-C during the interactive view. Terminal should restore correctly (cursor visible, not in alternate buffer).

- [ ] **Step 7: Verify pipe safety**

```bash
music speaker | cat             # Should print non-interactive list, not TUI
music similar | head -5         # Should print non-interactive results
```

- [ ] **Step 8: Commit any fixes from smoke testing**

If smoke tests reveal issues, fix them and commit:

```bash
git add -A
git commit -m "fix: smoke test fixes for CLI UX redesign"
```

---

### Task 15: Version Bump and Final Commit

**Files:**
- Modify: `tools/music/Sources/Music.swift` (version string)
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump version to 1.2.0 in all three locations**

In `tools/music/Sources/Music.swift`, change `version: "1.1.0"` to `version: "1.2.0"`.

In `.claude-plugin/plugin.json`, update the `version` field to `"1.2.0"`.

In `.claude-plugin/marketplace.json`, update both version fields:
- `metadata.version` → `"1.2.0"`
- `plugins[0].version` → `"1.2.0"`

- [ ] **Step 2: Rebuild and install with new version**

Run: `cd tools/music && swift build -c release && cp .build/release/music ~/.local/bin/music`

Verify: `music --version` outputs `1.2.0`.

- [ ] **Step 3: Commit and push**

```bash
git add tools/music/Sources/Music.swift .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump version to 1.2.0 for CLI UX redesign"
git push
```

---

## Implementation Notes for Workers

### Swift-Argument-Parser Initializer Pattern

When delegating from hidden subcommands to `SpeakerSmart` or calling `SpeakerList(json:)` programmatically, you need explicit initializers because property wrappers don't auto-generate them. Pattern:

```swift
init() {}
init(json: Bool) { self._json = Flag(wrappedValue: json) }
```

### TTY Detection

Always gate interactive TUI on `isTTY()` returning `true`. When stdout is piped, fall back to non-interactive output. This keeps the CLI scriptable.

### Terminal State Cleanup

The `TerminalState.shared` singleton with `defer { terminal.exitRawMode() }` plus the SIGINT handler ensures cleanup. Test this manually — automated tests can't verify terminal state restoration.

### Cache File Safety

`try? cache.writeSongs(...)` uses `try?` intentionally — cache writes are best-effort. Cache reads use `try` and surface `CacheError` to the user with actionable messages.

### Hidden Subcommand Pattern

Use `shouldDisplay: false` in `CommandConfiguration` to hide aliases from `--help` while keeping them functional. The skill and existing slash commands continue to use explicit subcommands.
