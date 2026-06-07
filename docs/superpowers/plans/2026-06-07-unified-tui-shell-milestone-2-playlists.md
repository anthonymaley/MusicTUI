# Unified TUI Shell — Milestone 2 (Playlists Scene) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the v1.8.0 playlist browser into the shell as a `Playlists` scene, switchable via the `2` key / `Tab`, sharing the persistent live now-playing bar and global transport keys.

**Architecture:** Extract the playlist data sources (name list + the three AppleScript-backed closures `onMeta`/`onPreview`/`onTracks`) into one reusable factory used by both the standalone `music playlist` command and the shell. Add a `capturesAllInput` flag to the `Scene` protocol so a scene in text-entry mode (filter) receives raw keys before the shell resolves globals. Build `PlaylistsScene` by relocating the existing browser's state + render logic (currently nested closures in `runPlaylistBrowser`) into a `Scene` class that draws into the shell's body region. Wire it into the shell as a lazily-built second tab.

**Tech Stack:** Swift 5, AppleScript via `osascript`, XCTest, raw-mode terminal.

**Reference spec:** `docs/superpowers/specs/2026-06-07-unified-tui-shell-design.md`
**Builds on:** Milestone 1 (committed `98b1d30…e0fa3cb`): the shell loop, `Scene` protocol, `Router`, `ShellFrame`, `NowPlayingScene`, poller/store, persistent bar.

**Working location:** directly on `main` (project convention). Commit per task; push after each.

## Scope

**In:** data-source factory; `capturesAllInput` protocol+shell support; `PlaylistsScene` with full browse/filter/preview/track-list/play parity; wire as shell tab #2.

**Out (deferred, noted not dropped):**
- **Playlist-context Now Playing.** Playing from the Playlists scene starts playback and switches to the Now Playing scene showing the album/history timeline from the poller — NOT the full-playlist timeline the old `runNowPlayingWithContext` showed. Porting playlist context into the poller is a separate effort.
- **Retiring `music playlist`.** The standalone `runPlaylistBrowser` + `PlaylistBrowse.run()` loop stay as-is (zero-regression fallback). Routing `music playlist` into the shell and deleting `runPlaylistBrowser` is a cleanup follow-up after this scene is verified live.
- **Speakers scene** (Milestone 2b, separate plan).

---

## File Structure

New:
- `Sources/TUI/PlaylistDataSources.swift` — `PlaylistDataSources` struct + `fetchUserPlaylistNames(backend:)` + `makePlaylistDataSources(backend:names:)`. Single source for the playlist name list and the three closures.
- `Sources/TUI/Shell/PlaylistsScene.swift` — `PlaylistsScene: Scene`, relocating the browser's state and render logic to draw into a `ShellFrame` body region.
- `Tests/MusicTests/PlaylistDataSourcesTests.swift` — parse tests for the meta/preview result formats.
- `Tests/MusicTests/SceneInputModeTests.swift` — `capturesAllInput` default + routing decision.

Modified:
- `Sources/TUI/Shell/Scene.swift` — add `capturesAllInput` to the protocol with a default-`false` extension.
- `Sources/TUI/Shell/Shell.swift` — input routing honors `capturesAllInput`; delegate `Esc` to the scene (scene returns `.pop`); lazily build + register the Playlists tab.
- `Sources/Commands/PlaylistCommands.swift:33-152` — `PlaylistBrowse.run()` uses the new factory instead of inline name-fetch + closures (behavior identical).

---

## Task 1: Extract playlist data sources into a reusable factory

**Files:**
- Create: `tools/music/Sources/TUI/PlaylistDataSources.swift`
- Modify: `tools/music/Sources/Commands/PlaylistCommands.swift:33-163`
- Test: `tools/music/Tests/MusicTests/PlaylistDataSourcesTests.swift`

The closures currently inline in `PlaylistBrowse.run()` (`PlaylistCommands.swift:55-152`) move verbatim into a factory. The result-parsing logic is pure and gets unit tests. `escapeAppleScriptString`, `PlaylistPreview`, and `AppleScriptBackend` already exist.

- [ ] **Step 1: Write the failing test for the parse helpers**

```swift
// tools/music/Tests/MusicTests/PlaylistDataSourcesTests.swift
import XCTest
@testable import music

final class PlaylistDataSourcesTests: XCTestCase {
    func testParseMetaLine() {
        // "idx|count|durationSeconds|smart|specialKind"
        let parsed = parsePlaylistMetaLine("3|42|9000.0|true|none")
        XCTAssertEqual(parsed?.index, 3)
        XCTAssertEqual(parsed?.count, 42)
        XCTAssertEqual(parsed?.durationSec, 9000)
        XCTAssertEqual(parsed?.isSmart, true)
        XCTAssertEqual(parsed?.specialKind, "none")
    }
    func testParseMetaLineRejectsMalformed() {
        XCTAssertNil(parsePlaylistMetaLine("garbage"))
        XCTAssertNil(parsePlaylistMetaLine("x|1|2|true|none"))   // non-int index
    }
    func testParseTracksResultSplitsCountAndLines() {
        let r = parsePlaylistTracksResult("57|Song A — Artist A\nSong B — Artist B")
        XCTAssertEqual(r.count, 57)
        XCTAssertEqual(r.lines, ["Song A — Artist A", "Song B — Artist B"])
    }
    func testParseTracksResultEmptyBody() {
        let r = parsePlaylistTracksResult("0|")
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.lines, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter PlaylistDataSourcesTests`
Expected: FAIL — `parsePlaylistMetaLine` / `parsePlaylistTracksResult` undefined.

- [ ] **Step 3: Write the factory + pure parse helpers**

```swift
// tools/music/Sources/TUI/PlaylistDataSources.swift
import Foundation

/// The three AppleScript-backed closures the playlist browser/scene needs,
/// plus shared caches captured inside them. Built once per browse session.
struct PlaylistDataSources {
    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)]
    let onPreview: (Int) -> [String]?
    let onTracks: (Int) -> PlaylistPreview?
}

/// Parse one `onMeta` result line: "idx|count|durationSeconds|smart|specialKind".
func parsePlaylistMetaLine(_ line: Substring) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    let f = line.split(separator: "|", maxSplits: 4).map(String.init)
    guard f.count == 5, let idx = Int(f[0]) else { return nil }
    let count = Int(f[1]) ?? 0
    let dur = Int(Double(f[2]) ?? 0)
    let smart = f[3].trimmingCharacters(in: .whitespaces) == "true"
    return (idx, count, dur, smart, f[4].trimmingCharacters(in: .whitespaces))
}

func parsePlaylistMetaLine(_ line: String) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    parsePlaylistMetaLine(Substring(line))
}

/// Parse the `onTracks` result: "totalCount|line\nline\n...".
func parsePlaylistTracksResult(_ result: String) -> (count: Int, lines: [String]) {
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "|", maxSplits: 1)
    let count = Int(parts.first ?? "0") ?? 0
    let lines = parts.count > 1
        ? String(parts[1]).components(separatedBy: "\n").filter { !$0.isEmpty }
        : []
    return (count, lines)
}

/// Fetch the user's playlist names (one instant AppleScript call).
func fetchUserPlaylistNames(backend: AppleScriptBackend) -> [String] {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            set output to ""
            repeat with p in (every user playlist)
                if output is not "" then set output to output & linefeed
                set output to output & name of p
            end repeat
            return output
        """)
    }) else { return [] }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Build the three data-source closures over a fixed `names` list. Each closure
/// owns its own cache. Bulk `tracks 1 thru n` fetches (never per-element) per the
/// performance lesson in docs/playbook.md.
func makePlaylistDataSources(backend: AppleScriptBackend, names: [String]) -> PlaylistDataSources {
    var trackCache: [Int: PlaylistPreview] = [:]
    var previewCacheLight: [Int: [String]] = [:]

    let onTracks: (Int) -> PlaylistPreview? = { idx in
        if let cached = trackCache[idx] { return cached }
        guard idx >= 0, idx < names.count else { return nil }
        let plName = names[idx]
        let escapedPlName = escapeAppleScriptString(plName)
        guard let trackResult = try? syncRun({
            try await backend.runMusic("""
                set total to count of tracks of playlist "\(escapedPlName)"
                set n to total
                if n > 200 then set n to 200
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(escapedPlName)"
                    set ars to artist of tracks 1 thru n of playlist "\(escapedPlName)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " — " & (item i of ars)
                    end repeat
                end if
                return (total as text) & "|" & output
            """)
        }) else { return nil }
        let parsed = parsePlaylistTracksResult(trackResult)
        let preview = PlaylistPreview(name: plName, trackCount: parsed.count, tracks: parsed.lines)
        trackCache[idx] = preview
        return preview
    }

    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)] = { indices in
        guard !indices.isEmpty else { return [:] }
        var clauses = ""
        for idx in indices where idx >= 0 && idx < names.count {
            let esc = escapeAppleScriptString(names[idx])
            clauses += """
            set p to playlist "\(esc)"
            set output to output & "\(idx)|" & (count of tracks of p) & "|" & (duration of p) & "|" & (smart of p) & "|" & (special kind of p as text) & linefeed

            """
        }
        guard let result = try? syncRun({
            try await backend.runMusic("""
                set output to ""
                \(clauses)
                return output
            """)
        }) else { return [:] }
        var out: [Int: (Int, Int, Bool, String)] = [:]
        for line in result.split(separator: "\n") {
            if let p = parsePlaylistMetaLine(line) {
                out[p.index] = (p.count, p.durationSec, p.isSmart, p.specialKind)
            }
        }
        return out
    }

    let onPreview: (Int) -> [String]? = { idx in
        if let c = previewCacheLight[idx] { return c }
        guard idx >= 0, idx < names.count else { return nil }
        let esc = escapeAppleScriptString(names[idx])
        guard let res = try? syncRun({
            try await backend.runMusic("""
                set total to count of tracks of playlist "\(esc)"
                set n to total
                if n > 8 then set n to 8
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(esc)"
                    set ars to artist of tracks 1 thru n of playlist "\(esc)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " \u{2014} " & (item i of ars)
                    end repeat
                end if
                return output
            """)
        }) else { return nil }
        let lines = res.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").map(String.init)
        previewCacheLight[idx] = lines
        return lines
    }

    return PlaylistDataSources(onMeta: onMeta, onPreview: onPreview, onTracks: onTracks)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter PlaylistDataSourcesTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Refactor `PlaylistBrowse.run()` to use the factory**

In `tools/music/Sources/Commands/PlaylistCommands.swift`, replace the body from the name-fetch through the three closure definitions (`PlaylistCommands.swift:33-152`, i.e. from `let backend = AppleScriptBackend()` down to the end of the `onPreview` closure, just before `var browserState: BrowserState? = nil`) with:

```swift
        let backend = AppleScriptBackend()
        let names = fetchUserPlaylistNames(backend: backend)

        guard !names.isEmpty else {
            print("No playlists found.")
            return
        }

        let sources = makePlaylistDataSources(backend: backend, names: names)
        let onMeta = sources.onMeta
        let onPreview = sources.onPreview
        let onTracks = sources.onTracks
```

Leave the `var browserState` line and the `while true { runPlaylistBrowser(...) }` loop below it unchanged — it already references `names`, `onMeta`, `onPreview`, `onTracks`.

- [ ] **Step 6: Build + confirm standalone path still compiles and tests pass**

Run: `cd tools/music && swift build && swift test`
Expected: Build succeeds; all tests pass (existing 71 + 4 new = 75).

- [ ] **Step 7: Commit**

```bash
git add tools/music/Sources/TUI/PlaylistDataSources.swift tools/music/Tests/MusicTests/PlaylistDataSourcesTests.swift tools/music/Sources/Commands/PlaylistCommands.swift
git diff --cached --stat   # confirm ONLY these three files; docs/playlist-browser-ui.md must NOT appear
git commit -m "$(printf 'refactor(playlist): extract reusable PlaylistDataSources factory\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 2: Add `capturesAllInput` to the Scene protocol + shell routing

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/Scene.swift`
- Modify: `tools/music/Sources/TUI/Shell/Shell.swift`
- Test: `tools/music/Tests/MusicTests/SceneInputModeTests.swift`

When a scene is in raw text-entry mode (playlist filter, future search), it must receive every key before the shell resolves globals/Tab/Esc. Add a `capturesAllInput` flag (default `false`) and a pure routing decision the shell uses.

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/SceneInputModeTests.swift
import XCTest
@testable import music

private final class StubScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Stub"
    var capturing = false
    var capturesAllInput: Bool { capturing }
    func tick(snapshot: NowPlayingSnapshot) {}
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String { "" }
    func handle(_ key: KeyPress) -> SceneAction { .none }
}

final class SceneInputModeTests: XCTestCase {
    func testDefaultIsFalse() {
        // NowPlayingScene does not override capturesAllInput.
        let s = NowPlayingScene(backend: AppleScriptBackend())
        XCTAssertFalse(s.capturesAllInput)
    }
    func testShellRoutesGlobalsWhenNotCapturing() {
        let s = StubScene(); s.capturing = false
        // q resolves as a global only when the scene is not capturing.
        XCTAssertTrue(shellShouldResolveGlobals(forSceneCapturing: s.capturesAllInput))
    }
    func testShellSkipsGlobalsWhenCapturing() {
        let s = StubScene(); s.capturing = true
        XCTAssertFalse(shellShouldResolveGlobals(forSceneCapturing: s.capturesAllInput))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter SceneInputModeTests`
Expected: FAIL — `capturesAllInput` / `shellShouldResolveGlobals` undefined.

- [ ] **Step 3: Add the protocol member + default + routing helper**

In `tools/music/Sources/TUI/Shell/Scene.swift`, add to the `Scene` protocol (after `var tabTitle: String { get }`):

```swift
    /// When true, the shell routes every key straight to `handle` without
    /// resolving globals, Tab, or Esc — for raw text entry (filter, search).
    var capturesAllInput: Bool { get }
```

And after the protocol's closing brace, add the default and the pure routing helper:

```swift
extension Scene {
    var capturesAllInput: Bool { false }
}

/// Pure decision: should the shell resolve global/navigation keys for the
/// active scene, or hand everything to the scene? Globals are skipped only when
/// the scene is capturing raw input.
func shellShouldResolveGlobals(forSceneCapturing capturing: Bool) -> Bool {
    !capturing
}
```

- [ ] **Step 4: Update the shell loop to honor capturing + delegate Esc**

In `tools/music/Sources/TUI/Shell/Shell.swift`, replace the input-handling section (from `guard let key = KeyPress.read(timeout: 0.1) else { continue }` through the end of the scene-delegation `switch`) with:

```swift
        guard let key = KeyPress.read(timeout: 0.1) else { continue }

        // Raw-input scenes (filter/search) get every key, unmediated.
        if !shellShouldResolveGlobals(forSceneCapturing: scene.capturesAllInput) {
            switch scene.handle(key) {
            case .none, .redraw: break
            case .push(let id): router.push(id)
            case .pop: router.pop()
            case .quit: return
            }
            continue
        }

        // 1) Globals (work in every non-capturing scene).
        if let action = resolveGlobalKey(key) {
            switch action {
            case .playPause:  _ = try? syncRun { try await backend.runMusic("playpause") }
            case .volumeUp:   _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume + 5)") }
            case .volumeDown: _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume - 5)") }
            case .next:       _ = try? syncRun { try await backend.runMusic("next track") }
            case .prev:       _ = try? syncRun { try await backend.runMusic("previous track") }
            case .shuffle:    _ = try? syncRun { try await backend.runMusic("set shuffle enabled to (not shuffle enabled)") }
            case .radio:      _ = startRadioStation(); router.switchTo(.nowPlaying)
            case .switchScene(let n): if n >= 1 && n <= tabs.count { router.switchTo(tabs[n - 1].id) }
            case .quit:       return
            }
            continue
        }

        // 2) Tab cycles scenes.
        if case .char("\t") = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                router.switchTo(tabs[(idx + 1) % tabs.count].id)
            }
            continue
        }

        // 3) Everything else (including Esc) goes to the scene; it decides whether
        //    Esc means an internal back (.redraw) or leaving the scene (.pop).
        switch scene.handle(key) {
        case .none, .redraw: break
        case .push(let id): router.push(id)
        case .pop: router.pop()
        case .quit: return
        }
```

Note: this removes Milestone 1's direct `Esc`→pop/quit shell handling. `Esc` is now delegated. `NowPlayingScene.handle` returns `.none` for `Esc` (unchanged), so on the root Now Playing scene Esc does nothing and `q` quits — consistent with the footer hint.

- [ ] **Step 5: Run tests**

Run: `cd tools/music && swift test --filter SceneInputModeTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Full build + test**

Run: `cd tools/music && swift build && swift test`
Expected: Build succeeds; all pass (75 + 3 = 78).

- [ ] **Step 7: Commit**

```bash
git add tools/music/Sources/TUI/Shell/Scene.swift tools/music/Sources/TUI/Shell/Shell.swift tools/music/Tests/MusicTests/SceneInputModeTests.swift
git diff --cached --stat   # confirm ONLY these three files
git commit -m "$(printf 'feat(shell): capturesAllInput for raw text-entry scenes; delegate Esc\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 3: PlaylistsScene

**Files:**
- Create: `tools/music/Sources/TUI/Shell/PlaylistsScene.swift`

Relocates the browser's state (Task-source: `ListPicker.swift:54-66`) and render logic (`ListPicker.swift:113-313`) into a `Scene` class. Key adaptations from the standalone version:
- Renders into `frame.bodyY .. frame.bodyY+frame.bodyHeight-1` (a `ShellFrame` region), not full screen via `ScreenFrame.current()`. Drops `renderShell`/`clearBody` (shell owns chrome/bar).
- `tick()` runs one enrichment batch + one preview fetch per shell frame, guarded exactly as the old timeout branch (`ListPicker.swift:318-331`).
- Filter mode sets `capturesAllInput = true`; the `filtering` switch is reused verbatim.
- Tab-as-focus-toggle is dropped (the shell owns Tab); drill-in is Enter, back is Left/Esc.
- Play/shuffle/track-play call AppleScript inline (a brief, user-initiated stall is acceptable) then return `.push(.nowPlaying)`. No `BrowserResult`/`PlaybackContext` — the poller drives the now-playing view.

Reused existing symbols: `PlaylistMeta`, `playlistZones`, `PlaylistZones`, `playlistBadge`, `railName`, `gradientBlock`, `formatPlaylistDuration`, `nextEnrichmentBatch`, `truncText`, `ANSICode`, `escapeAppleScriptString`, `PlaylistPreview`, `syncRun`.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/PlaylistsScene.swift
import Foundation

final class PlaylistsScene: Scene {
    let id: SceneID = .playlists
    let tabTitle = "Playlists"
    var capturesAllInput: Bool { filtering }

    private let backend: AppleScriptBackend
    private let playlists: [String]
    private let sources: PlaylistDataSources

    private var focus: BrowserFocus = .playlists
    private var plCursor = 0
    private var plScroll = 0
    private var trCursor = 0
    private var trScroll = 0
    private var meta: [PlaylistMeta]
    private var loaded: Set<Int> = []
    private var fullCache: [Int: PlaylistPreview] = [:]
    private var previewLines: [Int: [String]] = [:]
    private var lastLoadedPl = -1
    private var filterText = ""
    private var filtering = false

    private let metaCol = 6
    private let enrichBatch = 5

    init(backend: AppleScriptBackend, playlists: [String], sources: PlaylistDataSources) {
        self.backend = backend
        self.playlists = playlists
        self.sources = sources
        self.meta = playlists.map { PlaylistMeta(name: $0) }
    }

    // MARK: filter helpers

    private func visibleIndices() -> [Int] {
        guard !filterText.isEmpty else { return Array(0..<meta.count) }
        let q = filterText.lowercased()
        return (0..<meta.count).filter { meta[$0].name.lowercased().contains(q) }
    }
    private func clampCursorToFilter() {
        let vis = visibleIndices()
        if !vis.contains(plCursor) { plCursor = vis.first ?? 0 }
        plScroll = 0
    }
    private func loadFull() {
        guard plCursor != lastLoadedPl else { return }
        lastLoadedPl = plCursor
        if fullCache[plCursor] == nil { fullCache[plCursor] = sources.onTracks(plCursor) }
        trCursor = 0; trScroll = 0
    }
    private func badgeText(_ m: PlaylistMeta) -> (String, String)? {
        switch playlistBadge(name: m.name, isSmart: m.isSmart ?? false, specialKind: m.specialKind ?? "none") {
        case .radio: return ("RADIO", ANSICode.amber)
        case .smart: return ("SMART", ANSICode.amber)
        case .recent: return ("RECENT", ANSICode.amber)
        case .none: return nil
        }
    }

    // MARK: Scene

    func tick(snapshot: NowPlayingSnapshot) {
        // One enrichment batch per frame while metadata is incomplete.
        if loaded.count < meta.count {
            let vis = visibleIndices()
            // bodyY+2 .. body bottom approximates the on-screen rail rows; use a
            // generous window so off-screen-but-soon items still enrich.
            let onScreen = Array(vis.dropFirst(plScroll).prefix(40))
            let batch = nextEnrichmentBatch(total: meta.count, loaded: loaded, visible: onScreen, batchSize: enrichBatch)
            if !batch.isEmpty {
                let fetched = sources.onMeta(batch)
                for idx in batch {
                    if let (count, dur, smart, kind) = fetched[idx] {
                        meta[idx].trackCount = count
                        meta[idx].durationSec = dur
                        meta[idx].isSmart = smart
                        meta[idx].specialKind = kind
                    }
                    meta[idx].loaded = true
                    loaded.insert(idx)
                }
            }
        }
        // One preview fetch per frame when the preview pane is shown and empty.
        let z = playlistZones(width: ScreenFrame.current().width)
        if focus == .playlists, z.mode == .three, previewLines[plCursor] == nil {
            previewLines[plCursor] = sources.onPreview(plCursor) ?? []
        }
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        // Clear the body region first.
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        renderRail(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        renderHero(z, into: &out, bodyTop: bodyTop)
        if focus == .tracks {
            renderTrackList(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        } else {
            renderPreview(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        }
        if filtering || !filterText.isEmpty {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filterText)\(ANSICode.reset)\(filtering ? "\u{2588}" : "")"
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        let trackCount = fullCache[plCursor]?.tracks.count ?? 0

        if filtering {
            switch key {
            case .enter: filtering = false
            case .escape: filtering = false; filterText = ""; clampCursorToFilter()
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filterText.isEmpty { filterText.removeLast() }
                clampCursorToFilter()
            case .char(let c): filterText.append(c); clampCursorToFilter()
            default: break
            }
            return .redraw
        }

        switch key {
        case .up:
            if focus == .playlists {
                let vis = visibleIndices()
                if let pos = vis.firstIndex(of: plCursor), pos > 0 { plCursor = vis[pos - 1] }
            } else { trCursor = max(0, trCursor - 1) }
            return .redraw
        case .down:
            if focus == .playlists {
                let vis = visibleIndices()
                if let pos = vis.firstIndex(of: plCursor), pos < vis.count - 1 { plCursor = vis[pos + 1] }
            } else { trCursor = min(trackCount - 1, trCursor + 1) }
            return .redraw
        case .char("/"):
            filtering = true
            return .redraw
        case .enter:
            if focus == .playlists {
                loadFull(); focus = .tracks; trCursor = 0; trScroll = 0
                return .redraw
            } else {
                playTrack(trCursor)
                return .push(.nowPlaying)
            }
        case .left:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .escape:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .char("p"):
            playPlaylist(shuffle: false); return .push(.nowPlaying)
        case .char("s"):
            playPlaylist(shuffle: true); return .push(.nowPlaying)
        case .char("b"):
            return .push(.nowPlaying)
        default:
            return .none
        }
    }

    // MARK: playback (user-initiated; brief inline stall acceptable)

    private func playTrack(_ trackIndex: Int) {
        let esc = escapeAppleScriptString(playlists[plCursor])
        _ = try? syncRun { try await self.backend.runMusic("play track \(trackIndex + 1) of playlist \"\(esc)\"") }
    }
    private func playPlaylist(shuffle: Bool) {
        let esc = escapeAppleScriptString(playlists[plCursor])
        _ = try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }
        _ = try? syncRun { try await self.backend.runMusic("play playlist \"\(esc)\"") }
    }

    // MARK: render helpers (relocated from runPlaylistBrowser, region-relative)

    private func renderRail(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        let listY = bodyTop + 2
        let maxVisible = max(1, bodyBottom - listY)
        let vis = visibleIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX) + "\(ANSICode.dim)(no matches)\(ANSICode.reset)"
            return
        }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        if pos < plScroll { plScroll = pos }
        if pos >= plScroll + maxVisible { plScroll = pos - maxVisible + 1 }
        let end = min(vis.count, plScroll + maxVisible)
        let nameWidth = z.railWidth - 2 - metaCol - 1
        for p in plScroll..<end {
            let i = vis[p]
            let row = listY + (p - plScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let m = meta[i]
            let display = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
            let nm = railName(display, nameWidth: max(1, nameWidth))
            let metaCell: String
            if !m.loaded {
                metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol - 1))\u{00B7}\(ANSICode.reset)"
            } else if let (text, color) = badgeText(m) {
                let padded = String(repeating: " ", count: max(0, metaCol - text.count)) + text
                metaCell = "\(color)\(padded)\(ANSICode.reset)"
            } else {
                let c = "\(m.trackCount ?? 0)"
                let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
            }
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if i == plCursor {
                let mark = (focus == .playlists) ? ANSICode.cyan : ANSICode.dim
                out += "\(mark)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
            } else {
                out += "  \(ANSICode.white)\(padName)\(ANSICode.reset) \(metaCell)"
            }
        }
    }

    private func renderHero(_ z: PlaylistZones, into out: inout String, bodyTop: Int) {
        var y = bodyTop
        let m = meta[plCursor]
        let title = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(title, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        if m.loaded, let c = m.trackCount {
            let dur = m.durationSec.map { " \u{00B7} " + formatPlaylistDuration($0) } ?? ""
            out += "\(ANSICode.dim)\(c) tracks\(dur)\(ANSICode.reset)"
        }
        y += 2
        let gw = min(16, z.heroWidth)
        let block = gradientBlock(name: m.name, width: gw, height: 6)
        var seed = 0; for b in m.name.unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
        let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
        let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
        for line in block {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
            y += 1
        }
        y += 1
        if let (text, c) = badgeText(m) {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(c)\(text)\(ANSICode.reset)"
            y += 2
        } else { y += 1 }
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Browse   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    private func renderPreview(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Preview\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let lines = previewLines[plCursor] {
            if lines.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                for (i, line) in lines.prefix(8).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
    }

    private func renderTrackList(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        let tracks = fullCache[plCursor]?.tracks ?? []
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Tracks\(ANSICode.reset) \(ANSICode.dim)\(tracks.count)\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        let maxVis = max(1, bodyBottom - y)
        if trCursor < trScroll { trScroll = trCursor }
        if trCursor >= trScroll + maxVis { trScroll = trCursor - maxVis + 1 }
        let end = min(tracks.count, trScroll + maxVis)
        for i in trScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let text = truncText(tracks[i], to: max(2, z.rightWidth - 4))
            if i == trCursor {
                out += "\(ANSICode.cyan)\u{25B6}\(ANSICode.reset) \(ANSICode.brightWhite)\(idx) \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaylistsScene.swift
git diff --cached --stat   # confirm ONLY this file
git commit -m "$(printf 'feat(shell): PlaylistsScene (3-zone browser as a shell scene)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 4: Wire the Playlists tab into the shell (lazy build)

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/Shell.swift`

Register Playlists as tab #2. Build it lazily on first switch (so launching `music` doesn't pay the playlist-name fetch unless you open the tab). If the playlist list is empty, the switch falls back to staying on the current scene.

- [ ] **Step 1: Update `runShell()` scene registry + lazy construction**

In `tools/music/Sources/TUI/Shell/Shell.swift`, replace the scene/tab setup lines (Milestone 1):

```swift
    let router = Router(root: .nowPlaying)
    let scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend)]
    // v1 tab order; Milestone 1 ships only Now Playing.
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now")]
```

with:

```swift
    let router = Router(root: .nowPlaying)
    var scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend)]
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now"), (.playlists, "Playlists")]

    // Lazily build a scene the first time it's shown. Returns nil if it can't be
    // built (e.g. no playlists), so the caller can refuse the switch.
    func ensureScene(_ id: SceneID) -> Scene? {
        if let s = scenes[id] { return s }
        switch id {
        case .playlists:
            let names = fetchUserPlaylistNames(backend: backend)
            guard !names.isEmpty else { return nil }
            let scene = PlaylistsScene(backend: backend,
                                       playlists: names,
                                       sources: makePlaylistDataSources(backend: backend, names: names))
            scenes[id] = scene
            return scene
        default:
            return nil
        }
    }
```

- [ ] **Step 2: Guard scene access + route switches through `ensureScene`**

In the same file, the loop currently does `guard let scene = scenes[router.active] else { continue }`. Replace it with:

```swift
        guard let scene = ensureScene(router.active) ?? scenes[.nowPlaying] else { continue }
```

And replace BOTH scene-switch points so a failed lazy-build refuses the switch:
- In the globals switch, `case .switchScene(let n):`

```swift
            case .switchScene(let n):
                if n >= 1 && n <= tabs.count, ensureScene(tabs[n - 1].id) != nil { router.switchTo(tabs[n - 1].id) }
```

- In the Tab handler:

```swift
        if case .char("\t") = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                let nextId = tabs[(idx + 1) % tabs.count].id
                if ensureScene(nextId) != nil { router.switchTo(nextId) }
            }
            continue
        }
```

Also confirm the footer hint line in the render section mentions tab switching; replace the M1 footer hint string with:

```swift
            out += "\(ANSICode.dim)1 Now  2 Playlists  Tab Switch   \u{2191}\u{2193} Move  Enter Open  p Play  s Shuffle  / Filter  q Quit\(ANSICode.reset)"
```

- [ ] **Step 3: Full build + test**

Run: `cd tools/music && swift build && swift test`
Expected: Build succeeds; all tests pass (78).

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/TUI/Shell/Shell.swift
git diff --cached --stat   # confirm ONLY this file
git commit -m "$(printf 'feat(shell): wire Playlists as tab 2 (lazy-built)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 5: Live verification (human at terminal)

- [ ] **Step 1: Reinstall + run**

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh && music
```

- [ ] **Step 2: Verify (with music playing)**

- Tab strip now shows `Now` and `Playlists`; press `2` or `Tab` → Playlists scene appears in the body, now-playing bar still ticks at the bottom.
- Rail lists playlists; metadata (counts / SMART·RADIO·RECENT badges) fills in progressively without layout jumping; hero shows the selected playlist; preview pane shows 8 tracks on the right.
- `/` enters filter — typing narrows the list, and **digits/`q`/`z` go into the filter text** (not hijacked as globals); `Enter` confirms, `Esc` clears.
- `Enter` on a playlist opens its track list (right pane); `↑↓` move the track cursor; `Left`/`Esc` returns to the rail.
- `p` plays the playlist, `s` shuffles it, `Enter` on a track plays it — each starts playback and switches to the Now Playing scene; the bar reflects the new track within ~1s.
- While in Playlists, `Space`/`+`/`-`/`<`/`>` still control playback (globals work mid-browse).
- `1` switches back to Now Playing.
- `q` quits cleanly.
- `music playlist` (separate command) still opens the standalone browser unchanged.

Report any failure with the exact symptom.

- [ ] **Step 3: After verification passes — version bump for the unified shell (M1 + M2)**

Bump to **1.9.0** across all four locations (CLAUDE.md Version Strategy) — this is the single release for the unified shell:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift:8` → `version: "1.9.0"`

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh && music --version   # expect 1.9.0
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json tools/music/Sources/Music.swift
git diff --cached --stat   # confirm ONLY these three files
git commit -m "$(printf 'chore: bump to 1.9.0 (unified TUI shell: Now Playing + Playlists)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Self-Review

**Spec coverage (M2-Playlists scope):**
- Playlists as a shell scene reusing the v1.8.0 browser → Tasks 3, 4. ✓
- `Enter` → push to Now Playing (poller-driven) → Task 3 handle(). ✓
- Shared global keymap works mid-browse; filter mode exempt via `capturesAllInput` → Task 2. ✓
- Lazy tab build, no startup cost for unopened tabs → Task 4. ✓
- DRY: one data-source factory for standalone + shell → Task 1. ✓
- Deferred + flagged: playlist-context Now Playing; retiring `music playlist`/`runPlaylistBrowser`; Speakers scene. ✓

**Placeholder scan:** No TBD/TODO; complete code in every code step; exact commands + expected output. ✓

**Type consistency:** `PlaylistDataSources`(onMeta/onPreview/onTracks), `parsePlaylistMetaLine`, `parsePlaylistTracksResult`, `fetchUserPlaylistNames`, `makePlaylistDataSources`, `capturesAllInput`, `shellShouldResolveGlobals`, `PlaylistsScene`, `ensureScene` used consistently. Existing reused symbols verified against source: `PlaylistMeta`, `playlistZones`/`PlaylistZones`(railX/railWidth/heroX/heroWidth/rightX/rightWidth/mode), `playlistBadge`, `railName`, `gradientBlock`, `formatPlaylistDuration`, `nextEnrichmentBatch`, `BrowserFocus`, `PlaylistPreview`, `escapeAppleScriptString`, `truncText`, `ANSICode`, `syncRun`, `ScreenFrame.current`. ✓

**Behavior-change notes (intentional, in-plan):**
- Tab no longer toggles rail/track focus inside the browser (shell owns Tab); Enter drills in, Left/Esc backs out.
- Esc on the root Now Playing scene no longer quits (delegated; returns `.none`); `q` quits. Footer reflects this.
- Enrichment runs every 100ms frame (was adaptive 0.15s/60s); the existing `loaded.count < meta.count` / `previewLines[plCursor] == nil` guards keep it from redundant fetches. AppleScript fetches still run on the main thread, so a heavy fetch briefly delays a repaint — bar data stays fresh (poller thread), only the paint is deferred. Off-main scene fetching is a known future polish.
