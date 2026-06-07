# Unified TUI Shell — Milestone 3 (Now Playing rework + Playlists polish) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Now Playing a real context view — the current track as the hero with its **actual album art**, and an **Up Next** list drawn from the current playlist/album from the current position onward — and use the existing screen real estate better in Playlists (taller preview, bigger art).

**Architecture:** The poller, on track change, fetches the **playback context** (`current playlist` tracks windowed around the current index, with the context name) and extracts the **current track's album art** (existing `extractArtwork` + `artworkToAscii`), publishing both in the snapshot. `NowPlayingScene` renders a hero (art + metadata) plus an Up Next list via the existing region-relative `renderTimelineRows`, with the cursor snapping to the current track on change. Playlists preview becomes height-driven; the hero art block scales to the hero zone.

**Tech Stack:** Swift 5, AppleScript via `osascript`, `chafa` (optional, with CoreGraphics fallback), XCTest, raw-mode terminal.

**Reference:** review feedback 2026-06-07 (context-is-king, current track is hero, up-next = playlist/album tracks).
**Builds on:** v1.9.0 (`8647b27`). Reuses `extractArtwork()`, `artworkToAscii(path:width:height:)`, `renderTimelineRows`, `playTrackInCurrentPlaylist`, `formatTime`, `TrackListEntry`, `pollAlbumTracks`/`pollSurroundingTracks` (as fallback), `meterBar`, `truncText`, `ANSICode`, `syncRun` — all in `NowPlayingTUI.swift`/`TUILayout.swift`.

**Working location:** `main`; commit per task, push after each.

## Scope

**In:** playback-context queue source; current-track art in the snapshot; Now Playing hero + Up Next rework with cursor-follows-current + Enter-to-jump; Playlists taller preview + bigger art; patch bump to 1.9.1.

**Out (deferred):** real *playlist* artwork in the Playlists hero (would need a representative-track fetch — separate); Search/Library/Queue scenes; retiring standalone commands.

---

## File Structure

New:
- `Sources/TUI/Shell/PlaybackContext.swift` — `ContextQueue` struct + `pollContextQueue(backend:)` (current-playlist window) + `currentTrackArtLines(width:height:)` helper.
- `Tests/MusicTests/PlaybackContextTests.swift` — parse test for the context-queue result format.

Modified:
- `Sources/TUI/Shell/NowPlayingStore.swift` — add `contextName: String` and `artLines: [String]` to `NowPlayingSnapshot` (defaulted, so existing constructions compile).
- `Sources/TUI/Shell/PlaybackPoller.swift` — on track change, populate context queue + art; publish them.
- `Sources/TUI/Shell/NowPlayingScene.swift` — hero (art + metadata) + Up Next list; cursor-follows-current; Enter → `playTrackInCurrentPlaylist`.
- `Sources/TUI/Shell/PlaylistsScene.swift` — preview fills pane height; enlarge hero gradient block.
- Version: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (×2), `tools/music/Sources/Music.swift:8` → `1.9.1`.

---

## Task 1: Context queue source + art helper + snapshot fields

**Files:**
- Create: `tools/music/Sources/TUI/Shell/PlaybackContext.swift`
- Modify: `tools/music/Sources/TUI/Shell/NowPlayingStore.swift`
- Test: `tools/music/Tests/MusicTests/PlaybackContextTests.swift`

`pollContextQueue` reads `current playlist` (name, track count, current track index) and bulk-fetches a window of tracks around the current index. The parse is pure and unit-tested. Falls back to `pollAlbumTracks` when there's no playlist context.

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindow() {
        // Format: "name\ncurrentIndex\nwindowStart\nidx|title|artist\nidx|title|artist..."
        let raw = "Friday Mix\n3\n2\n2|Song B|Artist B\n3|Song C|Artist C\n4|Song D|Artist D"
        let q = parseContextQueue(raw, currentTitle: "Song C", currentArtist: "Artist C")
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[0].index, 2)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)        // Song C is current
        XCTAssertFalse(q.tracks[0].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("", currentTitle: "x", currentArtist: "y")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter PlaybackContextTests`
Expected: FAIL — `parseContextQueue` / `ContextQueue` undefined.

- [ ] **Step 3: Write the source + helpers**

```swift
// tools/music/Sources/TUI/Shell/PlaybackContext.swift
import Foundation

/// The current playback context: the name of what's playing (playlist or album)
/// and a window of its tracks around the current one, with the current marked.
struct ContextQueue {
    let name: String
    let tracks: [TrackListEntry]   // index = real position in the current playlist
}

/// Pure parse of the pollContextQueue result.
/// Format: line 1 = context name, line 2 = current index, line 3 = window start,
/// then "index|title|artist" rows.
func parseContextQueue(_ raw: String, currentTitle: String, currentArtist: String) -> ContextQueue {
    let lines = raw.components(separatedBy: "\n")
    guard lines.count >= 3 else { return ContextQueue(name: "", tracks: []) }
    let name = lines[0].trimmingCharacters(in: .whitespaces)
    var tracks: [TrackListEntry] = []
    for line in lines.dropFirst(3) where !line.isEmpty {
        let f = line.split(separator: "|", maxSplits: 2).map(String.init)
        guard f.count == 3, let idx = Int(f[0]) else { continue }
        tracks.append(TrackListEntry(
            index: idx, name: f[1], artist: f[2],
            isCurrent: f[1] == currentTitle && f[2] == currentArtist
        ))
    }
    return ContextQueue(name: name, tracks: tracks)
}

/// Fetch the current playlist's name + a window of tracks around the current
/// index (current-2 .. current+40, clamped). Returns an empty ContextQueue when
/// there is no usable playlist context (caller falls back to album tracks).
func pollContextQueue(np: NowPlayingState, backend: AppleScriptBackend = AppleScriptBackend()) -> ContextQueue {
    guard let raw = try? syncRun({
        try await backend.runMusic("""
            try
                set cp to current playlist
                set cpName to name of cp
                set ct to current track
                set idx to index of ct
                set total to count of tracks of cp
                set startIdx to idx - 2
                if startIdx < 1 then set startIdx to 1
                set endIdx to idx + 40
                if endIdx > total then set endIdx to total
                set output to cpName & linefeed & idx & linefeed & startIdx
                if endIdx >= startIdx then
                    set ns to name of tracks startIdx thru endIdx of cp
                    set ars to artist of tracks startIdx thru endIdx of cp
                    repeat with i from 1 to (count of ns)
                        set output to output & linefeed & (startIdx + i - 1) & "|" & (item i of ns) & "|" & (item i of ars)
                    end repeat
                end if
                return output
            end try
            return ""
        """)
    }) else { return ContextQueue(name: "", tracks: []) }
    return parseContextQueue(raw, currentTitle: np.track, currentArtist: np.artist)
}

/// Extract the current track's album art and render it to ANSI lines at the
/// given size (chafa true-color if available, CoreGraphics block fallback).
/// Empty array when no artwork is available.
func currentTrackArtLines(width: Int, height: Int) -> [String] {
    guard let path = extractArtwork() else { return [] }
    return artworkToAscii(path: path, width: width, height: height)
}
```

In `tools/music/Sources/TUI/Shell/NowPlayingStore.swift`, extend the snapshot (add the two fields with defaults so the existing default construction in `NowPlayingStore` still compiles):

```swift
struct NowPlayingSnapshot {
    var outcome: PollOutcome
    var history: [(track: String, artist: String)]
    var surrounding: [TrackListEntry]      // playback-context window (current playlist/album)
    var contextName: String = ""           // name of the current playlist/album
    var artLines: [String] = []            // current track album art, rendered
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter PlaybackContextTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaybackContext.swift tools/music/Sources/TUI/Shell/NowPlayingStore.swift tools/music/Tests/MusicTests/PlaybackContextTests.swift
git diff --cached --stat   # confirm ONLY these three; docs/playlist-browser-ui.md must NOT appear
git commit -m "$(printf 'feat(shell): playback-context queue source + current-track art + snapshot fields\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 2: Poller publishes context queue + art on track change

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/PlaybackPoller.swift`

On track change, fetch the context queue (fall back to `pollAlbumTracks` when empty) and extract art. Both are off-main (poller thread), so the UI never stalls. Publish `contextName` and `artLines` in the snapshot.

- [ ] **Step 1: Add working fields + update the track-change block**

In `PlaybackPoller`, add to the thread-confined working state (after `private var surrounding`):

```swift
    private var contextName = ""
    private var artLines: [String] = []
```

Replace the track-change block inside `tick()`'s `.active` case (the `if np.track != lastTrack { ... }` body) with:

```swift
            if np.track != lastTrack {
                if !lastTrack.isEmpty {
                    if history.first.map({ $0.track != lastTrack || $0.artist != lastArtist }) ?? true {
                        history.insert((track: lastTrack, artist: lastArtist), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrack = np.track
                lastArtist = np.artist
                // Prefer the real playback context (current playlist); fall back to
                // album tracks when there's no playlist context.
                let ctx = pollContextQueue(np: np, backend: backend)
                if ctx.tracks.isEmpty {
                    surrounding = pollAlbumTracks(for: np, backend: backend)
                    contextName = np.album
                } else {
                    surrounding = ctx.tracks
                    contextName = ctx.name
                }
                artLines = currentTrackArtLines(width: 26, height: 13)
            }
```

Update the two `store.write(...)` calls in `tick()` to include the new fields. The `.active` write:

```swift
            store.write(NowPlayingSnapshot(outcome: .active(np), history: history, surrounding: surrounding, contextName: contextName, artLines: artLines))
```

The `.stopped` write:

```swift
            store.write(NowPlayingSnapshot(outcome: .stopped, history: history, surrounding: surrounding, contextName: contextName, artLines: artLines))
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaybackPoller.swift
git diff --cached --stat   # confirm ONLY this file
git commit -m "$(printf 'feat(shell): poller publishes playback-context queue + current-track art\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 3: Now Playing scene rework — hero + Up Next

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/NowPlayingScene.swift` (full replacement)

Hero = album art (left) + current track metadata (right). Up Next = the context window via `renderTimelineRows` below the hero. Cursor snaps to the current track when the track changes; the user can move it between changes. `Enter` jumps to the cursor's track in the current playlist.

- [ ] **Step 1: Replace the scene**

```swift
// tools/music/Sources/TUI/Shell/NowPlayingScene.swift
import Foundation

final class NowPlayingScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Now"

    private let backend: AppleScriptBackend
    private var cursor = 0
    private var scroll = 0
    private var rows: [TrackListEntry] = []
    private var lastCurrentKey = ""

    init(backend: AppleScriptBackend) { self.backend = backend }

    func tick(snapshot: NowPlayingSnapshot) {
        rows = snapshot.surrounding
        // Snap the cursor to the current track when the track changes; leave it
        // alone otherwise so the user can browse Up Next.
        if case .active(let np) = snapshot.outcome {
            let key = trackKey(title: np.track, artist: np.artist)
            if key != lastCurrentKey {
                lastCurrentKey = key
                if let i = rows.firstIndex(where: { $0.isCurrent }) { cursor = i }
            }
        }
        if cursor >= rows.count { cursor = max(0, rows.count - 1) }
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        guard frame.bodyHeight > 4, frame.width > 30 else { return out }

        guard case .active(let np) = snapshot.outcome else {
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3) + "\(ANSICode.dim)Nothing playing.\(ANSICode.reset)"
            return out
        }

        // --- Hero: art (left) + metadata (right) ---
        let artLines = snapshot.artLines
        let artW = 26
        let artRows = min(artLines.count, max(0, frame.bodyHeight - 2))
        for i in 0..<artRows {
            out += ANSICode.moveTo(row: frame.bodyY + i, col: 3) + "\(artLines[i])\(ANSICode.reset)"
        }
        let hasArt = artRows > 0
        let metaX = hasArt ? 3 + artW + 2 : 3
        let metaW = max(10, frame.width - metaX - 2)
        var my = frame.bodyY
        let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
        out += ANSICode.moveTo(row: my, col: metaX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
        my += 1
        out += ANSICode.moveTo(row: my, col: metaX) + truncText(np.artist, to: metaW)
        my += 1
        out += ANSICode.moveTo(row: my, col: metaX) + "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"
        my += 2
        // Progress
        let elapsed = formatTime(np.position)
        let total = formatTime(np.duration)
        let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
        let pbW = min(28, max(8, metaW - 14))
        let knob = max(0, min(pbW - 1, Int(ratio * Double(pbW - 1))))
        var bar = ""
        for i in 0..<pbW { bar += i == knob ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)" }
        out += ANSICode.moveTo(row: my, col: metaX) + "\(elapsed) \(bar) \(total)"
        my += 2
        if !snapshot.contextName.isEmpty {
            out += ANSICode.moveTo(row: my, col: metaX) + "\(ANSICode.dim)from \(truncText(snapshot.contextName, to: metaW - 5))\(ANSICode.reset)"
        }

        // --- Up Next list, below the hero ---
        let listY = frame.bodyY + max(artRows, 8) + 1
        let listBottom = frame.bodyY + frame.bodyHeight - 1
        if listY + 1 <= listBottom {
            // Adapt context entries to the timeline-row shape the shared renderer expects.
            let timeline = rows.map { e in
                TimelineRow(
                    id: trackKey(title: e.name, artist: e.artist),
                    kind: .playlist, index: e.index,
                    title: e.name, artist: e.artist,
                    label: "\(e.name) \u{2014} \(e.artist)",
                    isCurrent: e.isCurrent, wasPlayed: false, isReplayable: true
                )
            }
            out += renderTimelineRows(
                rows: timeline,
                header: "Up Next",
                x: 3,
                y: listY,
                width: frame.width - 6,
                visibleHeight: listBottom - listY + 1,
                cursorIndex: cursor,
                scrollOffset: &scroll
            )
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        switch key {
        case .up:
            guard !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 1); return .redraw
        case .down:
            guard !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 1); return .redraw
        case .enter:
            guard cursor < rows.count else { return .none }
            // Jump to the selected track within the current playlist by its real index.
            playTrackInCurrentPlaylist(backend: backend, index: rows[cursor].index)
            return .redraw
        case .left:
            _ = try? syncRun { try await self.backend.runMusic("set player position to (player position - 30)") }
            return .redraw
        case .right:
            _ = try? syncRun { try await self.backend.runMusic("set player position to (player position + 30)") }
            return .redraw
        default:
            return .none
        }
    }
}
```

Note: `‹`/`›` (prev/next track) and `Space` (play/pause) remain shell globals — they work here unchanged. Seek stays on Left/Right as before.

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/NowPlayingScene.swift
git diff --cached --stat   # confirm ONLY this file
git commit -m "$(printf 'feat(shell): Now Playing hero (real art) + Up Next from playback context\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 4: Playlists — taller preview + bigger hero art

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/PlaylistsScene.swift`

Use the available height for the preview (instead of a fixed 8) and enlarge the gradient hero block.

- [ ] **Step 1: Make the preview fill the pane height**

In `PlaylistsScene.renderPreview`, the loop currently uses `lines.prefix(8)`. Replace the rendering loop so it draws as many lines as fit in the pane:

```swift
        if let lines = previewLines[plCursor] {
            if lines.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                let maxLines = max(1, bodyBottom - y + 1)
                for (i, line) in lines.prefix(maxLines).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
```

- [ ] **Step 2: Fetch enough preview lines to fill the pane**

In `makePlaylistDataSources` (`Sources/TUI/PlaylistDataSources.swift`), the `onPreview` closure caps at 8 (`if n > 8 then set n to 8`). Raise the cap to 40 so the taller pane has data:

```swift
                set total to count of tracks of playlist "\(esc)"
                set n to total
                if n > 40 then set n to 40
```

(Change the single `if n > 8 then set n to 8` line to `if n > 40 then set n to 40`. The render only draws what fits, so over-fetch is bounded and cheap relative to the 200-track full fetch.)

- [ ] **Step 3: Enlarge the hero art block**

In `PlaylistsScene.renderHero`, the block is `width: min(16, z.heroWidth), height: 6`. Make it fill more of the hero zone:

```swift
        let gw = min(28, z.heroWidth)
        let gh = 10
        let block = gradientBlock(name: m.name, width: gw, height: gh)
```

(Change `let gw = min(16, z.heroWidth)` to `min(28, ...)` and `gradientBlock(..., height: 6)` to `height: gh` with `let gh = 10` above it.)

- [ ] **Step 4: Build + full test**

Run: `cd tools/music && swift build && swift test`
Expected: Build succeeds; all pass (80 + 2 from Task 1 = 82).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaylistsScene.swift tools/music/Sources/TUI/PlaylistDataSources.swift
git diff --cached --stat   # confirm ONLY these two files
git commit -m "$(printf 'feat(shell): Playlists preview fills pane + larger hero art block\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Task 5: Live verification + patch bump to 1.9.1

- [ ] **Step 1: Reinstall + run**

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh && music
```

- [ ] **Step 2: Verify (play a playlist first, then open the shell)**

Now Playing:
- The hero shows the **current track's real album art** (or a clean empty space if a track has none / `chafa` absent — the CoreGraphics fallback still renders blocks).
- Title/artist/album/progress beside the art; a `from <playlist/album>` line.
- **Up Next** lists the current playlist's tracks from the current position; the **current track is highlighted and the cursor is on it**; `↑↓` browse; `Enter` jumps to a track (it plays and the hero updates).
- When the track changes (or auto-advances), the cursor re-snaps to the new current track — no more drifting highlight.
- `Space`/`<`/`>` still control playback; `1`/`2`/`3` switch scenes.

Playlists:
- The preview pane fills its height (more than 8 tracks when the playlist has them).
- The hero art block is visibly larger.

Report any failure with the exact symptom.

- [ ] **Step 3: After verification passes — bump to 1.9.1**

Set all four version locations to `1.9.1`:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift:8` → `version: "1.9.1"`

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh && music --version   # expect 1.9.1
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json tools/music/Sources/Music.swift
git diff --cached --stat   # confirm ONLY these three files
git commit -m "$(printf 'chore: bump to 1.9.1 (Now Playing context rework + Playlists polish)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Self-Review

**Coverage (review feedback):**
- Now Playing: current track is the hero with real album art → Tasks 1-3. ✓
- Up Next = playlist/album tracks from current position (context = queue) → Tasks 1-3. ✓
- Cursor-follows-current bug fixed (snap on track change) → Task 3. ✓
- Dropped confusing history/library-album source; clear "Up Next" + "from <context>" labels → Tasks 2-3. ✓
- Playlists preview uses pane height → Task 4. ✓
- Playlists art enlarged → Task 4. ✓

**Placeholder scan:** No TBD/TODO; complete code in every code step; exact commands + expected output. ✓

**Type consistency:** `ContextQueue`(name/tracks), `parseContextQueue`, `pollContextQueue`, `currentTrackArtLines`, snapshot `contextName`/`artLines`. Reused symbols verified against source: `extractArtwork()->String?`, `artworkToAscii(path:width:height:)->[String]`, `renderTimelineRows(rows:header:x:y:width:visibleHeight:cursorIndex:scrollOffset:)`, `TimelineRow`(id/kind/index/title/artist/label/isCurrent/wasPlayed/isReplayable), `TimelineRowKind.playlist`, `TrackListEntry`(index/name/artist/isCurrent), `playTrackInCurrentPlaylist(backend:index:)`, `trackKey(title:artist:)`, `formatTime`, `pollAlbumTracks(for:backend:)`, `truncText`, `ANSICode`, `syncRun`. ✓

**Behavior-change notes (intentional):**
- Now Playing body source changes from library-album+history to current-playlist context; art added (off-main fetch in the poller, so no UI stall). Art extraction runs once per track change.
- Enter in Now Playing now jumps within the current playlist (`play track N of current playlist`) by real index, instead of a library title/artist search.
- `onPreview` over-fetches up to 40 (was 8); still cheap vs the 200-track full fetch; render draws only what fits.
