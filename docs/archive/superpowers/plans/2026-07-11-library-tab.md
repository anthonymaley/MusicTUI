# Library Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 4th TUI tab, "Library", that browses and plays your Apple Music library across three switchable sub-views — Albums, Artists, Songs.

**Architecture:** Browse data comes from the REST library API (`/v1/me/library/*`, paginated), rendered with the shipped playlist-browser 3-zone helpers. Navigation (sub-view + Artists drill levels) is a pure `(state, key, selection) → (state, action)` reducer, unit-tested in isolation. Playback reuses the existing AppleScript play path on the shell action queue.

**Tech Stack:** Swift, SwiftPM, XCTest. Apple Music REST API (`RESTAPIBackend`), AppleScript backend, the TUI `Scene`/`Router`/`Shell` framework.

**Reference spec:** `docs/superpowers/specs/2026-07-11-library-tab-design.md`
**Build order:** Albums (Tasks 1–3) → Songs (Task 4) → Artists (Task 5) → docs & live smoke (Task 6).

**Conventions to follow (read these first):**
- Pure parsers as free functions with fixtures — pattern in `Backends/RESTAPIBackend.swift` (`parseCatalogSongObject` etc.) and `Tests/MusicTests/SearchTests.swift`.
- Scene structure — mirror `TUI/Shell/PlaylistsScene.swift`; render helpers `playlistZones`/`gradientBlock`/`railName` at `TUI/PlaylistBrowserModel.swift:48-131`, colours `ANSICode` at `TUI/Terminal.swift:7`.
- Off-thread fetch → `NSLock` inbox → drain in `tick()` — pattern in `TUI/Shell/SpeakersScene.swift:63-147`.
- `Scene` protocol at `TUI/Shell/Scene.swift:16-42`; `SceneID` already has `.library` (`Router.swift:5`).
- SwiftPM globs `Sources/` — new files need no `Package.swift` edit.
- Run tests: `swift test` in `tools/music`. **The XCTest summary is NOT in `tail`** — grep the full output for `Executed [0-9]+ tests`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Backends/RESTAPIBackend.swift` (modify) | Add `LibraryAlbum/Artist/Song` models, `parseLibrary*` free parsers, `libraryAlbumsPath/…` builders, and `libraryAlbums/Artists/Songs/artistAlbums` methods |
| `TUI/LibraryNav.swift` (create) | Pure navigation types + `libraryReduce` reducer — no I/O, no rendering |
| `TUI/LibraryDataSources.swift` (create) | Struct-of-closures over the REST methods + on-disk cache |
| `TUI/Shell/LibraryScene.swift` (create) | `Scene` conformance: owns `LibraryNav`, wires keys → reducer → data sources / action queue, renders via the shared helpers |
| `TUI/Shell/Shell.swift` (modify) | `tabs` array, `ensureScene` case, footer string |
| `Tests/MusicTests/LibraryAPITests.swift` (create) | Parser + path-builder tests |
| `Tests/MusicTests/LibraryNavTests.swift` (create) | Reducer tests |
| `skills/music/SKILL.md`, `docs/guide.md` (modify) | Document the Library tab |

---

## Task 1: REST library foundation (Albums)

**Files:**
- Modify: `tools/music/Sources/Backends/RESTAPIBackend.swift`
- Test: `tools/music/Tests/MusicTests/LibraryAPITests.swift` (create)

- [ ] **Step 1: Confirm the live response shape (the spec's flagged unknown)**

The library *list* endpoints differ from catalog search — they return resources under a top-level `data` array, not `results{<key>}{data}`. Before writing the parser, confirm it against the real library. Add a throwaway probe to a scratch main or use `curl` with the tokens the CLI already stores; the goal is to SEE one real album object.

Run (adapt to how tokens are stored — see `Auth/AuthManager.swift`):
```bash
# Dev + user tokens are what `music search --library` already uses successfully.
# Easiest: add a temporary debug print in a scratch build, or inspect via the
# existing get() plumbing. Confirm the JSON has: top-level "data":[{ "id", "attributes":{ "name","artistName" } }, ...]
```
Expected: an object shaped `{"data":[{"id":"l.xxx","attributes":{"name":"…","artistName":"…"}}], "meta":{"total":N}}`. **If the shape differs, adjust the parser in Step 3 to match what you actually see.** Record the confirmed shape in a comment above the parser.

- [ ] **Step 2: Write the failing parser + path test**

Create `tools/music/Tests/MusicTests/LibraryAPITests.swift`:
```swift
// tools/music/Tests/MusicTests/LibraryAPITests.swift
import XCTest
@testable import music

final class LibraryAPITests: XCTestCase {
    func testAlbumsPath() {
        XCTAssertEqual(libraryAlbumsPath(limit: 100, offset: 0),
                       "/v1/me/library/albums?limit=100&offset=0")
        XCTAssertEqual(libraryAlbumsPath(limit: 25, offset: 50),
                       "/v1/me/library/albums?limit=25&offset=50")
    }

    func testParsesLibraryAlbums() {
        let r = parseLibraryAlbums(from: Data(Self.albums.utf8))
        XCTAssertEqual(r.map(\.name), ["Kid A", "OK Computer"])
        XCTAssertEqual(r.first?.artist, "Radiohead")
        XCTAssertEqual(r.first?.id, "l.aaa")
    }

    func testParsesEmptyAndGarbage() {
        XCTAssertTrue(parseLibraryAlbums(from: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(parseLibraryAlbums(from: Data("nope".utf8)).isEmpty)
    }

    // Confirmed live in Task 1 Step 1: library list endpoints return top-level `data`.
    static let albums = """
    { "data": [
      { "id": "l.aaa", "attributes": { "name": "Kid A", "artistName": "Radiohead" } },
      { "id": "l.bbb", "attributes": { "name": "OK Computer", "artistName": "Radiohead" } }
    ] }
    """
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: compile error — `libraryAlbumsPath` / `parseLibraryAlbums` / `LibraryAlbum` undefined.

- [ ] **Step 4: Add the model, path builder, and parser**

In `RESTAPIBackend.swift`, next to the Task-D search helpers (before `enum APIError`):
```swift
// MARK: - Library browse (pure helpers)

struct LibraryAlbum { let id: String; let name: String; let artist: String
    func toDict() -> [String: Any] { ["id": id, "name": name, "artist": artist] } }
struct LibraryArtist { let id: String; let name: String
    func toDict() -> [String: Any] { ["id": id, "name": name] } }
struct LibrarySong { let id: String; let title: String; let artist: String; let album: String
    func toDict() -> [String: Any] { ["id": id, "title": title, "artist": artist, "album": album] } }

func libraryAlbumsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/albums?limit=\(limit)&offset=\(offset)"
}
func libraryArtistsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/artists?limit=\(limit)&offset=\(offset)"
}
func librarySongsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/songs?limit=\(limit)&offset=\(offset)"
}
func artistAlbumsPath(artistID: String) -> String {
    "/v1/me/library/artists/\(artistID)/albums?limit=100"
}

// Library list endpoints return resources under a top-level `data` array
// (confirmed live 2026-07-11), unlike catalog search's `results{<key>}{data}`.
func parseLibraryDataArray(from data: Data) -> [[String: Any]] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return json?["data"] as? [[String: Any]] ?? []
}

func parseLibraryAlbums(from data: Data) -> [LibraryAlbum] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibraryAlbum(id: obj["id"] as? String ?? "",
                            name: a["name"] as? String ?? "Unknown",
                            artist: a["artistName"] as? String ?? "Unknown")
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: `Executed N tests, with 0 failures` (N = previous count + 3).

- [ ] **Step 6: Add the `libraryAlbums` fetch method**

Inside `struct RESTAPIBackend`, next to `search`:
```swift
func libraryAlbums(limit: Int = 100, offset: Int = 0) async throws -> [LibraryAlbum] {
    guard userToken != nil else { throw AuthError.userTokenRequired }
    let (data, status) = try await get(libraryAlbumsPath(limit: limit, offset: offset))
    guard (200...299).contains(status) else {
        if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
        throw APIError.requestFailed(status)
    }
    return parseLibraryAlbums(from: data)
}
```

- [ ] **Step 7: Commit**

```bash
git add tools/music/Sources/Backends/RESTAPIBackend.swift tools/music/Tests/MusicTests/LibraryAPITests.swift
git commit -m "feat(library): REST library albums model, parser, path, fetch"
```

---

## Task 2: Navigation reducer (core + Albums + sub-view switch)

**Files:**
- Create: `tools/music/Sources/TUI/LibraryNav.swift`
- Test: `tools/music/Tests/MusicTests/LibraryNavTests.swift` (create)

- [ ] **Step 1: Write the failing reducer test**

Create `tools/music/Tests/MusicTests/LibraryNavTests.swift`:
```swift
// tools/music/Tests/MusicTests/LibraryNavTests.swift
import XCTest
@testable import music

final class LibraryNavTests: XCTestCase {
    private let albumSel = LibrarySelection(id: "l.aaa", primary: "Kid A", secondary: "Radiohead")

    func testStartsOnAlbumsRoot() {
        let s = LibraryNav.initial
        XCTAssertEqual(s.subView, .albums)
        XCTAssertEqual(s.current, .albumList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testDownMovesCursorClamped() {
        var (s, _) = libraryReduce(.initial, .down, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.cursor, 1)
        (s, _) = libraryReduce(s, .down, itemCount: 2, selection: albumSel)  // clamp at last
        XCTAssertEqual(s.cursor, 1)
    }

    func testSwitchNextGoesToArtistsRootResettingCursor() {
        var (s, _) = libraryReduce(.initial, .down, itemCount: 5, selection: albumSel)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 5, selection: albumSel)
        XCTAssertEqual(s.subView, .artists)
        XCTAssertEqual(s.current, .artistList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testEnterOnAlbumListPushesTracksAndFetches() {
        let (s, action) = libraryReduce(.initial, .enter, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.current, .tracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
        XCTAssertEqual(action, .fetchAlbumTracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
    }

    func testBackPopsToAlbumRoot() {
        var (s, _) = libraryReduce(.initial, .enter, itemCount: 2, selection: albumSel)
        (s, _) = libraryReduce(s, .back, itemCount: 10, selection: nil)
        XCTAssertEqual(s.current, .albumList)
    }

    func testPlayOnAlbumListEmitsAlbumPlay() {
        let (_, action) = libraryReduce(.initial, .play, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .play(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }

    func testShuffleOnAlbumListEmitsAlbumShuffle() {
        let (_, action) = libraryReduce(.initial, .shuffle, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .shuffle(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: compile error — `LibraryNav`, `libraryReduce`, `LibrarySelection` undefined.

- [ ] **Step 3: Write the reducer**

Create `tools/music/Sources/TUI/LibraryNav.swift`:
```swift
// tools/music/Sources/TUI/LibraryNav.swift
// Pure navigation model for the Library tab. No I/O, no rendering — the scene
// executes the emitted LibraryAction. Kept pure so every transition is unit-
// testable (mirrors how PlaylistBrowserModel pulls geometry out of the scene).
import Foundation

enum LibrarySubView: CaseIterable, Equatable { case albums, artists, songs }

enum LibraryLevel: Equatable {
    case albumList, artistList, songList
    case artistAlbums(artistID: String, artistName: String)
    case tracks(albumID: String, albumTitle: String, artist: String)
}

/// Identity of whatever row is under the cursor when a key is pressed. Passed in
/// so the reducer stays pure (no dependency on the live data arrays).
struct LibrarySelection: Equatable {
    let id: String
    let primary: String    // album title / artist name / song title
    let secondary: String  // artist for album/song; "" for artist
}

enum LibraryTarget: Equatable {
    case album(id: String, title: String, artist: String)
    case song(id: String, title: String, artist: String)
    case artist(id: String, name: String)
}

enum LibraryAction: Equatable {
    case none
    case fetchArtistAlbums(artistID: String, artistName: String)
    case fetchAlbumTracks(albumID: String, albumTitle: String, artist: String)
    case play(LibraryTarget)
    case shuffle(LibraryTarget)
}

enum LibraryKey { case up, down, enter, back, switchNext, switchPrev, play, shuffle }

struct LibraryNav: Equatable {
    var subView: LibrarySubView
    var stack: [LibraryLevel]   // stack.last == current level
    var cursor: Int

    static let initial = LibraryNav(subView: .albums, stack: [.albumList], cursor: 0)
    var current: LibraryLevel { stack.last! }

    static func root(for sub: LibrarySubView) -> LibraryLevel {
        switch sub { case .albums: return .albumList; case .artists: return .artistList; case .songs: return .songList }
    }
}

func libraryReduce(_ state: LibraryNav, _ key: LibraryKey,
                   itemCount: Int, selection: LibrarySelection?) -> (LibraryNav, LibraryAction) {
    var s = state
    switch key {
    case .up:   s.cursor = max(0, s.cursor - 1); return (s, .none)
    case .down: s.cursor = min(max(0, itemCount - 1), s.cursor + 1); return (s, .none)

    case .switchNext, .switchPrev:
        let all = LibrarySubView.allCases
        let idx = all.firstIndex(of: s.subView)!
        let next = key == .switchNext ? (idx + 1) % all.count : (idx - 1 + all.count) % all.count
        s.subView = all[next]
        s.stack = [LibraryNav.root(for: s.subView)]
        s.cursor = 0
        return (s, .none)

    case .back:
        if s.stack.count > 1 { s.stack.removeLast(); s.cursor = 0 }
        return (s, .none)

    case .enter:
        guard let sel = selection else { return (s, .none) }
        switch s.current {
        case .albumList, .artistAlbums:
            s.stack.append(.tracks(albumID: sel.id, albumTitle: sel.primary, artist: sel.secondary))
            s.cursor = 0
            return (s, .fetchAlbumTracks(albumID: sel.id, albumTitle: sel.primary, artist: sel.secondary))
        case .artistList:
            s.stack.append(.artistAlbums(artistID: sel.id, artistName: sel.primary))
            s.cursor = 0
            return (s, .fetchArtistAlbums(artistID: sel.id, artistName: sel.primary))
        case .songList:
            return (s, .play(.song(id: sel.id, title: sel.primary, artist: sel.secondary)))
        case .tracks(let id, let title, let artist):
            return (s, .play(.album(id: id, title: title, artist: artist)))
        }

    case .play:
        return (s, playOrShuffle(s.current, selection, shuffle: false))
    case .shuffle:
        return (s, playOrShuffle(s.current, selection, shuffle: true))
    }
}

private func playOrShuffle(_ level: LibraryLevel, _ sel: LibrarySelection?, shuffle: Bool) -> LibraryAction {
    let target: LibraryTarget?
    switch level {
    case .albumList, .artistAlbums:
        target = sel.map { .album(id: $0.id, title: $0.primary, artist: $0.secondary) }
    case .artistList:
        target = sel.map { .artist(id: $0.id, name: $0.primary) }
    case .songList:
        target = sel.map { .song(id: $0.id, title: $0.primary, artist: $0.secondary) }
    case .tracks(let id, let title, let artist):
        target = .album(id: id, title: title, artist: artist)
    }
    guard let t = target else { return .none }
    return shuffle ? .shuffle(t) : .play(t)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: `Executed N tests, with 0 failures` (N = previous + 7).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/LibraryNav.swift tools/music/Tests/MusicTests/LibraryNavTests.swift
git commit -m "feat(library): pure navigation reducer (albums + sub-view switch)"
```

---

## Task 3: LibraryDataSources + LibraryScene (Albums) + shell seams

This task produces the first visible, playable vertical. Rendering mirrors `PlaylistsScene`; do not invent a new visual language.

**Files:**
- Create: `tools/music/Sources/TUI/LibraryDataSources.swift`
- Create: `tools/music/Sources/TUI/Shell/LibraryScene.swift`
- Modify: `tools/music/Sources/TUI/Shell/Shell.swift` (`tabs` line 16; `ensureScene` ~20-43; footer line 117)

- [ ] **Step 1: Data sources**

Create `tools/music/Sources/TUI/LibraryDataSources.swift`. Mirror `PlaylistDataSources` (struct of closures) and the `SpeakersScene` inbox threading. Albums only for now:
```swift
// tools/music/Sources/TUI/LibraryDataSources.swift
import Foundation

/// Closures the LibraryScene depends on — no direct REST/AppleScript in the
/// scene. Each runs off-thread; results post to the scene's inbox (drained in
/// tick()). Extended in Tasks 4/5 with onSongs/onArtists/onArtistAlbums.
struct LibraryDataSources {
    /// Fetch library albums (page 0). Returns [] on any failure — the scene
    /// shows an empty rail rather than crashing.
    let onAlbums: () -> [LibraryAlbum]
    /// Fetch the tracks of a library album (by name+artist via the existing
    /// AppleScript library lookup — playback and track listing both key on name).
    let onAlbumTracks: (_ albumTitle: String, _ artist: String) -> [String]
}

func makeLibraryDataSources(api: RESTAPIBackend, backend: AppleScriptBackend) -> LibraryDataSources {
    LibraryDataSources(
        onAlbums: { (try? syncRun { try await api.libraryAlbums() }) ?? [] },
        onAlbumTracks: { title, artist in
            // Track titles for the album, via the Library playlist (same source
            // the album-play AppleScript uses). Bulk read, never per-element.
            let esc = { escapeAppleScriptString($0) }
            let script = """
            set out to ""
            repeat with t in (every track of playlist "Library" whose album is "\(esc(title))" and artist is "\(esc(artist))")
                set out to out & (name of t) & linefeed
            end repeat
            return out
            """
            let raw = (try? syncRun { try await backend.runMusic(script, timeout: 30) }) ?? ""
            return raw.split(separator: "\n").map(String.init)
        }
    )
}
```
> Note: on-disk cache (`~/.config/music/library-albums.json`) can be added as a fast-follow; for the first vertical, the off-thread fetch + inbox is enough. If you add it now, mirror `PlaylistMetaCache` (`PlaylistDataSources.swift:14-43`).

- [ ] **Step 2: LibraryScene**

Create `tools/music/Sources/TUI/Shell/LibraryScene.swift`. Structure below is complete for wiring; the render bodies mirror `PlaylistsScene`'s rail/hero/track helpers — reuse `playlistZones`, `gradientBlock`, `railName`, `ANSICode`, `truncText`, `meterBar`. Keep view-state main-thread-only; post async results to `inbox` under `inboxLock`, drain in `tick()`.
```swift
// tools/music/Sources/TUI/Shell/LibraryScene.swift
import Foundation

final class LibraryScene: Scene {
    let id: SceneID = .library
    let tabTitle = "Library"
    var footerHint: String { "[ ] view · Enter open · / filter · p play · s shuffle" }

    private let sources: LibraryDataSources
    private let backend: AppleScriptBackend
    private let actions: ActionRunner

    private var nav = LibraryNav.initial
    private var albums: [LibraryAlbum] = []
    private var tracks: [String] = []          // current album's track titles
    private var filter = ""
    private var capturing = false              // filter mode
    var capturesAllInput: Bool { capturing }

    // Background inbox (albums load off-thread).
    private let inboxLock = NSLock()
    private var albumsInbox: [LibraryAlbum]? = nil
    private var lastActiveTick = Date.distantPast

    init(sources: LibraryDataSources, backend: AppleScriptBackend, actions: ActionRunner) {
        self.sources = sources
        self.backend = backend
        self.actions = actions
        loadAlbums()
    }

    private func loadAlbums() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let a = self.sources.onAlbums()
            self.inboxLock.lock(); self.albumsInbox = a; self.inboxLock.unlock()
        }
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        inboxLock.lock()
        if let a = albumsInbox { albums = a; albumsInbox = nil; changed = true }
        inboxLock.unlock()
        return changed
    }

    // Rows visible in the current level, honouring the filter.
    private func rowLabels() -> [String] {
        switch nav.current {
        case .albumList:
            return albums.map { "\($0.name) — \($0.artist)" }
                .filter { filter.isEmpty || $0.lowercased().contains(filter.lowercased()) }
        case .tracks:
            return tracks
        default: return []   // artist levels / songs added in Tasks 4-5
        }
    }

    private func selectionAtCursor() -> LibrarySelection? {
        switch nav.current {
        case .albumList:
            let shown = albums.filter { filter.isEmpty || "\($0.name) — \($0.artist)".lowercased().contains(filter.lowercased()) }
            guard nav.cursor < shown.count else { return nil }
            let a = shown[nav.cursor]
            return LibrarySelection(id: a.id, primary: a.name, secondary: a.artist)
        default: return nil
        }
    }

    func handle(_ key: KeyPress) -> SceneAction {
        if capturing { return handleFilterKey(key) }
        let libKey: LibraryKey?
        switch key {
        case .up: libKey = .up
        case .down: libKey = .down
        case .enter: libKey = .enter
        case .left, .escape: libKey = .back
        case .char("]"): libKey = .switchNext
        case .char("["): libKey = .switchPrev
        case .char("p"): libKey = .play
        case .char("s"): libKey = .shuffle
        case .char("/"): capturing = true; filter = ""; return .redraw
        default: libKey = nil
        }
        guard let k = libKey else { return .none }
        let (next, action) = libraryReduce(nav, k, itemCount: rowLabels().count, selection: selectionAtCursor())
        nav = next
        execute(action)
        return .redraw
    }

    private func execute(_ action: LibraryAction) {
        switch action {
        case .fetchAlbumTracks(_, let title, let artist):
            tracks = []
            let src = sources
            Thread.detachNewThread { [weak self] in
                let t = src.onAlbumTracks(title, artist)
                self?.inboxLock.lock(); self?.tracksInbox = t; self?.inboxLock.unlock()
            }
        case .play(.album(_, let title, let artist)):
            playAlbum(title: title, artist: artist, shuffle: false)
        case .shuffle(.album(_, let title, let artist)):
            playAlbum(title: title, artist: artist, shuffle: true)
        default: break   // song/artist actions added in Tasks 4-5
        }
    }

    // Play a library album by matching its tracks in the Library playlist — the
    // same mechanism `music play --album` uses. On the action queue → toast on fail.
    private func playAlbum(title: String, artist: String, shuffle: Bool) {
        let esc = { escapeAppleScriptString($0) }
        actions.run("Play") {
            _ = try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }
            try require((try? syncRun { try await self.backend.runMusic("""
                play (every track of playlist "Library" whose album is "\(esc(title))" and artist is "\(esc(artist))")
            """) }) != nil, "Couldn't play '\(title)'.")
        }
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        // MIRROR PlaylistsScene.render: draw the sub-view header (Albums·Artists·Songs
        // with the active one highlighted), then the 3-zone rail·hero·track pane via
        // playlistZones(width:)/gradientBlock/railName. Rail rows = rowLabels();
        // selected row inverse-video, others dim; hero shows the focused album name +
        // artist + track count; right pane lists `tracks`. See PlaylistsScene.swift:225-247.
        // (Full render omitted here — reuse the helpers; keep to the five colour roles.)
        return ""  // replace with the mirrored render
    }
}
```
> The `tracksInbox` field + its drain in `tick()` follow the same `albumsInbox` pattern — add it alongside. The `render` body is the one place you reproduce `PlaylistsScene`'s structure; everything else above is complete.

- [ ] **Step 3: Wire the shell seams**

`Shell.swift:16` — add the tab:
```swift
let tabs: [(id: SceneID, title: String)] = [
    (.nowPlaying, "Now"), (.playlists, "Playlists"), (.speakers, "Speakers"), (.library, "Library"),
]
```
`Shell.swift` `ensureScene(_:)` — add a case that refuses without a user token:
```swift
case .library:
    guard AuthManager().userToken() != nil else {
        status.post("Library needs your Apple Music account — run: music auth", error: true)
        return nil
    }
    let api = RESTAPIBackend(developerToken: (try? AuthManager().requireDeveloperToken()) ?? "",
                             userToken: AuthManager().userToken(),
                             storefront: AuthManager().storefront())
    return LibraryScene(sources: makeLibraryDataSources(api: api, backend: backend),
                        backend: backend, actions: actions)
```
`Shell.swift:117` — footer string:
```swift
// change "1/2/3 Tabs" → "1/2/3/4 Tabs"
```
> Match the exact `ensureScene` argument names to the existing `.playlists`/`.speakers` cases (`status`, `backend`, `actions` may be named differently — read lines 20-43 and mirror them).

- [ ] **Step 4: Build, then live smoke**

Run: `cd tools/music && swift build 2>&1 | tail -2`
Expected: `Build complete!`

Then drive the real tab:
```bash
.build/debug/music     # opens the shell TUI
# Press 4 (or Tab to Library). Expect the album rail to populate.
# ↑↓ move, Enter opens an album's tracks, p plays it, [ ] cycles sub-views
# (Artists/Songs will be empty until Tasks 4-5). Left/Esc backs out.
```
Expected: albums list from your library; opening + playing an album works; no crash; without a user token the tab refuses with the toast.

- [ ] **Step 5: Run the full suite**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add tools/music/Sources/TUI/LibraryDataSources.swift tools/music/Sources/TUI/Shell/LibraryScene.swift tools/music/Sources/TUI/Shell/Shell.swift
git commit -m "feat(library): Albums sub-view — scene, data source, shell tab"
```

---

## Task 4: Songs sub-view

**Files:**
- Modify: `Backends/RESTAPIBackend.swift` (song parser + `librarySongs`), `Tests/MusicTests/LibraryAPITests.swift`
- Modify: `TUI/LibraryDataSources.swift` (`onSongs`), `TUI/Shell/LibraryScene.swift` (songs rendering + play)

- [ ] **Step 1: Failing test for the song parser**

Add to `LibraryAPITests.swift`:
```swift
func testParsesLibrarySongs() {
    let json = """
    { "data": [ { "id": "i.s1", "attributes": { "name": "Idioteque", "artistName": "Radiohead", "albumName": "Kid A" } } ] }
    """
    let r = parseLibrarySongs(from: Data(json.utf8))
    XCTAssertEqual(r.first?.title, "Idioteque")
    XCTAssertEqual(r.first?.album, "Kid A")
}
func testSongsPath() {
    XCTAssertEqual(librarySongsPath(limit: 100, offset: 0), "/v1/me/library/songs?limit=100&offset=0")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"` — expect `parseLibrarySongs` undefined.

- [ ] **Step 3: Add the parser + fetch**

In `RESTAPIBackend.swift`:
```swift
func parseLibrarySongs(from data: Data) -> [LibrarySong] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibrarySong(id: obj["id"] as? String ?? "",
                           title: a["name"] as? String ?? "Unknown",
                           artist: a["artistName"] as? String ?? "Unknown",
                           album: a["albumName"] as? String ?? "")
    }
}
```
Add the method (mirror `libraryAlbums`, using `librarySongsPath`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"` — expect green, +2 tests.

- [ ] **Step 5: Wire Songs into the data source and scene**

- Add `let onSongs: () -> [LibrarySong]` to `LibraryDataSources` and the factory (`(try? syncRun { try await api.librarySongs() }) ?? []`).
- Add a `songs: [LibrarySong]` field + `songsInbox` to `LibraryScene`, loaded when `nav.subView == .songs` becomes active (fetch in `handle` on switch, or lazily in `tick` when songs empty and active).
- Extend `rowLabels()` `.songList` case → `songs.map { "\($0.title) — \($0.artist)" }` (filtered).
- Extend `selectionAtCursor()` `.songList` case.
- Extend `execute` `.play(.song(...))`/`.shuffle(.song(...))` → play the matching library track:
```swift
private func playSong(title: String, artist: String) {
    let esc = { escapeAppleScriptString($0) }
    actions.run("Play") {
        try require((try? syncRun { try await self.backend.runMusic("""
            play (some track of playlist "Library" whose name is "\(esc(title))" and artist is "\(esc(artist))")
        """) }) != nil, "Couldn't play '\(title)'.")
    }
}
```
- Songs renders as a single flat list (rail zone only — no hero/track pane).

- [ ] **Step 6: Build + live smoke + suite**

Run: `swift build` then `.build/debug/music` → `]` to Songs → filter with `/`, Enter plays a track. Then `swift test 2>&1 | grep Executed` (green).

- [ ] **Step 7: Commit**

```bash
git add -A tools/music
git commit -m "feat(library): Songs sub-view — flat list, filter, play"
```

---

## Task 5: Artists sub-view (drill + shuffle)

**Files:**
- Modify: `Backends/RESTAPIBackend.swift` (artist parser + `libraryArtists` + `artistAlbums`), `Tests/MusicTests/LibraryAPITests.swift`
- Modify: `TUI/LibraryNav.swift` tests already cover artist transitions — add the ones below
- Modify: `TUI/LibraryDataSources.swift`, `TUI/Shell/LibraryScene.swift`

- [ ] **Step 1: Failing tests — artist parser + reducer drill/shuffle**

Add to `LibraryAPITests.swift`:
```swift
func testParsesLibraryArtists() {
    let json = """{ "data": [ { "id": "r.1", "attributes": { "name": "Radiohead" } } ] }"""
    XCTAssertEqual(parseLibraryArtists(from: Data(json.utf8)).first?.name, "Radiohead")
}
func testArtistAlbumsPath() {
    XCTAssertEqual(artistAlbumsPath(artistID: "r.1"), "/v1/me/library/artists/r.1/albums?limit=100")
}
```
Add to `LibraryNavTests.swift`:
```swift
func testArtistsEnterDrillsToArtistAlbums() {
    var s = LibraryNav.initial
    (s, _) = libraryReduce(s, .switchNext, itemCount: 3, selection: nil)  // → artists
    let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
    let (s2, action) = libraryReduce(s, .enter, itemCount: 3, selection: artistSel)
    XCTAssertEqual(s2.current, .artistAlbums(artistID: "r.1", artistName: "Radiohead"))
    XCTAssertEqual(action, .fetchArtistAlbums(artistID: "r.1", artistName: "Radiohead"))
}
func testShuffleOnArtistListEmitsArtistShuffle() {
    var s = LibraryNav.initial
    (s, _) = libraryReduce(s, .switchNext, itemCount: 3, selection: nil)
    let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
    let (_, action) = libraryReduce(s, .shuffle, itemCount: 3, selection: artistSel)
    XCTAssertEqual(action, .shuffle(.artist(id: "r.1", name: "Radiohead")))
}
```
> These pass against the Task-2 reducer already (it handles `.artistList`/`.artistAlbums`). If any fail, fix the reducer — do not weaken the test.

- [ ] **Step 2: Run to verify fail/pass split**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: parser tests fail (undefined `parseLibraryArtists`); the two reducer tests pass (reducer already supports artist levels).

- [ ] **Step 3: Add artist parser + fetches**

In `RESTAPIBackend.swift`:
```swift
func parseLibraryArtists(from data: Data) -> [LibraryArtist] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibraryArtist(id: obj["id"] as? String ?? "", name: a["name"] as? String ?? "Unknown")
    }
}
```
Add `libraryArtists(limit:offset:)` (mirror `libraryAlbums`, `libraryArtistsPath`) and:
```swift
func artistAlbums(artistID: String) async throws -> [LibraryAlbum] {
    guard userToken != nil else { throw AuthError.userTokenRequired }
    let (data, status) = try await get(artistAlbumsPath(artistID: artistID))
    guard (200...299).contains(status) else {
        if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
        throw APIError.requestFailed(status)
    }
    return parseLibraryAlbums(from: data)   // relationship returns album objects
}
```
> Verify the `/artists/{id}/albums` relationship response is also `data`-top-level album objects during the live smoke; adjust if not.

- [ ] **Step 4: Run to verify all pass**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"` — green, +4 tests.

- [ ] **Step 5: Wire Artists into the data source and scene**

- Add `onArtists: () -> [LibraryArtist]` and `onArtistAlbums: (_ artistID: String) -> [LibraryAlbum]` to `LibraryDataSources` + factory.
- In `LibraryScene`: add `artists: [LibraryArtist]` + `artistAlbums: [LibraryAlbum]` fields + inboxes; load artists when the Artists sub-view activates; on `.fetchArtistAlbums`, fetch into `artistAlbums`.
- Extend `rowLabels()`/`selectionAtCursor()` for `.artistList` (artist names; selection secondary = "") and `.artistAlbums` (album names for that artist).
- Extend `execute` for `.fetchArtistAlbums`, `.play(.artist)`, `.shuffle(.artist)`:
```swift
private func playArtist(name: String, shuffle: Bool) {
    let esc = { escapeAppleScriptString($0) }
    actions.run("Play") {
        _ = try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }
        try require((try? syncRun { try await self.backend.runMusic("""
            play (every track of playlist "Library" whose artist is "\(esc(name))")
        """) }) != nil, "Couldn't play '\(name)'.")
    }
}
```
- Render: when `current` is `.artistAlbums`, show a breadcrumb `Artists ▸ <name>` above the rail (the artistName is in the level).

- [ ] **Step 6: Build + live smoke + suite**

Run: `swift build` then `.build/debug/music` → `]` `]` to Artists → Enter drills to an artist's albums → Enter opens an album → `p` plays; on an artist row `s` shuffles the whole artist; `Left`/`Esc` steps back with the breadcrumb clearing. Then `swift test 2>&1 | grep Executed` (green).

- [ ] **Step 7: Commit**

```bash
git add -A tools/music
git commit -m "feat(library): Artists sub-view — drill to albums + shuffle artist"
```

---

## Task 6: Docs + final live smoke

**Files:**
- Modify: `skills/music/SKILL.md`, `docs/guide.md`

- [ ] **Step 1: Document the Library tab**

In `skills/music/SKILL.md`, in the TUI/shell section, add the Library tab: press `4` (or Tab) for Library; `[`/`]` switches Albums/Artists/Songs; Enter opens/drills; `p` plays, `s` shuffles in context; needs the user token. Add a matching line to `docs/guide.md`'s shell overview.

- [ ] **Step 2: Full live smoke across all three sub-views**

Run: `.build/debug/music`
- Albums: browse, open, play. Songs: filter, play a track. Artists: drill → album → play; shuffle an artist.
- Confirm the sub-view header highlights the active view and the footer reads `1/2/3/4 Tabs`.
- Confirm no-token refusal (temporarily test by pointing at a config without the user token, or trust the ensureScene path — do not clobber the real token).

- [ ] **Step 3: Full suite green**

Run: `cd tools/music && swift test 2>&1 | grep -E "error:|Executed"`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add skills/music/SKILL.md docs/guide.md
git commit -m "docs(library): document the Library TUI tab"
```

> Version bump (3.4.0/3.5.0) + `scripts/install.sh` rebuild + release are deliberately NOT in this plan — they belong to the release step in TODO ## Now, after the AirPlay live pass and this feature both land. Coordinate the version with whatever ships together.

---

## Self-Review

**Spec coverage:** Albums/Artists/Songs sub-views → Tasks 3/5/4. Pins dropped → Scope (no task, correct). REST-browse + AppleScript-play → Tasks 1/3 (play blocks). Pure reducer → Task 2. Token refusal → Task 3 Step 3. Shell seams → Task 3 Step 3. Live shape verification → Task 1 Step 1 + Task 5 Step 3. Testing (parsers/paths/reducer) → Tasks 1/2/4/5. Build order Albums→Songs→Artists → Tasks 3/4/5. All spec sections covered.

**Placeholder scan:** The `render()` body in Task 3 Step 2 is intentionally delegated to "mirror PlaylistsScene" rather than reproduced — this is a reuse instruction with exact file refs and helper names, not a TODO; the surrounding scene wiring is complete code. All test/impl steps for the new logic (parsers, reducer, REST) contain full code. No "TBD"/"handle edge cases"/"similar to Task N" placeholders.

**Type consistency:** `LibraryNav`/`LibraryLevel`/`LibrarySelection`/`LibraryTarget`/`LibraryAction`/`LibraryKey` and `libraryReduce` signatures are consistent across Tasks 2–5. `LibraryAlbum/Artist/Song` fields (`id`, `name`/`title`, `artist`, `album`) match between the parsers (Tasks 1/4/5) and the scene's `rowLabels`/`selectionAtCursor`. Path builders (`libraryAlbumsPath`/`librarySongsPath`/`libraryArtistsPath`/`artistAlbumsPath`) are named consistently between tests and impl.
