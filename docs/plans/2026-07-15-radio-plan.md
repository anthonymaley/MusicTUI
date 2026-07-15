# Radio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Radio tab (Favorites · Live · Personal) that plays Apple Music stations via the `music://` scheme rewrite, plus the prerequisite `music now` live-station fix.

**Architecture:** One pure function owns the trick (`https://`→`music://`), executed through an injectable `Opener` seam. Three units with one job each: `StationStore` (favorites on disk), `RadioCatalog` (REST reads), `RadioScene` (the tab). `RadioNav` is a pure reducer mirroring `LibraryNav`. The catalog API is an optimization, never a dependency — a favorite stores its own URL and plays without any network.

**Tech Stack:** Swift 5, swift-argument-parser, XCTest. Package at `tools/music`. AppleScript via `AppleScriptBackend`; REST via developer-token JWT.

**Spec:** `docs/plans/2026-07-15-radio-design.md` (commit `620b483`).

**Two phases. Phase 1 ships as its own release before Phase 2 starts** — it fixes a live user-visible bug (any live station hangs the statusline 3s, then breaks it).

---

## Spec deviation (decided during planning — spec must be updated in Task 0)

The spec proposed the live JSON shape `{"live": true, "station": "<name>", …}`. **That is wrong.** `name of current track` is the *song* for Apple's own live stations ("Okayyy (feat. Doja Cat)" on Apple Music 1) and only the *station* for third-party ones (BBC Radio 1). A `station` field would mislabel a song as a station name.

Corrected shape — same keys as normal, minus what doesn't exist:

```json
{"live": true, "track": "Okayyy (feat. Doja Cat)", "artist": "Latto",
 "album": "Big Mama", "state": "playing", "speakers": [{"name":"Kitchen","volume":56}]}
```

`duration`/`position` are **absent, not zero** — zero is a lie about a livestream.

---

## File Structure

**Phase 1 — `now` fix**

| File | Responsibility |
|---|---|
| `Sources/Commands/NowParse.swift` (create) | Pure parse of the AppleScript payload → `NowParse`. No I/O. |
| `Sources/Commands/PlaybackCommands.swift` (modify ~440-510) | AppleScript emits missing-safe fields; render delegates to `NowParse`. |
| `scripts/statusline.sh` (modify) | Render `live: true` with a LIVE marker; tolerate empty artist. |
| `Tests/MusicTests/NowParseTests.swift` (create) | Parser unit tests. |

**Phase 2 — Radio**

| File | Responsibility |
|---|---|
| `Sources/TUI/StationPlayback.swift` (create) | `Station`, `stationPlayURL`, `Opener` seam, `playStation`. |
| `Sources/TUI/StationStore.swift` (create) | Favorites: load/save/add/remove/dedupe. |
| `Sources/TUI/RadioCatalog.swift` (create) | REST: featured live, personal, search, by-id. Injected fetch. |
| `Sources/TUI/RadioNav.swift` (create) | Pure reducer. Mirrors `LibraryNav` minus the drill stack. |
| `Sources/TUI/Shell/RadioScene.swift` (create) | The tab. |
| `Sources/TUI/Shell/Router.swift` (modify) | `SceneID.radio`. |
| `Sources/TUI/Shell/Shell.swift` (modify) | Tab registration. |
| `Sources/Commands/RadioCommands.swift` (create) | `music radio` verbs. |
| `Sources/Music.swift` (modify) | Register `Radio` subcommand. |
| Tests (create) | `StationPlaybackTests`, `StationStoreTests`, `RadioCatalogTests`, `RadioNavTests`. |
| Sweep (modify) | `PlaylistBrowserModel.swift:28`, `PlaybackContext.swift:82-84`, `PlaylistsScene.swift:425,456`, `PlaylistBrowserModelTests.swift:7,20`. |

---

# PHASE 1 — the `music now` live-station fix

## Task 0: Correct the spec's JSON shape

**Files:** Modify: `docs/plans/2026-07-15-radio-design.md`

- [ ] **Step 1: Fix the shape**

In the section "The `music now` live-station fix", replace the JSON block and the sentence after it with:

````markdown
```json
{"live": true, "track": "Okayyy (feat. Doja Cat)", "artist": "Latto",
 "album": "Big Mama", "state": "playing", "speakers": [{"name":"Kitchen","volume":56}]}
```

Same keys as a normal response, minus `duration`/`position` — **absent, not zero**,
because zero is a lie about a livestream. There is deliberately no `station` field:
`name of current track` is the *song* on Apple's own live stations and the *station*
only on third-party ones, so any "station name" would be wrong half the time.
`statusline.sh` reads `live` to show a LIVE marker.
````

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-07-15-radio-design.md
git commit -m "docs: correct radio spec's live JSON shape (no station field)"
```

---

## Task 1: Extract a pure `now` parser

`now` is currently a monolith with inline AppleScript and no seam — nothing to test. Extract the parse first, behavior unchanged.

**Files:**
- Create: `Sources/Commands/NowParse.swift`
- Test: `Tests/MusicTests/NowParseTests.swift`

The AppleScript payload today is `track|artist|album|duration|position|state|speakers`, where `speakers` is `Name:Vol,Name:Vol`. Task 2 adds a `live` field before `speakers`. This task targets the **new 8-field** format so the parser is written once.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/NowParseTests.swift
import XCTest
@testable import musicPackage

final class NowParseTests: XCTestCase {
    func testStopped() {
        XCTAssertEqual(parseNowOutput("STOPPED"), .stopped)
    }

    func testLoading() {
        XCTAssertEqual(parseNowOutput("LOADING"), .loading)
    }

    func testNormalTrack() {
        let raw = "Andromeda|Gorillaz|Humanz|198|12|playing|0|Kitchen:56,Office:40"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Andromeda")
        XCTAssertEqual(i.artist, "Gorillaz")
        XCTAssertEqual(i.album, "Humanz")
        XCTAssertEqual(i.duration, 198)
        XCTAssertEqual(i.position, 12)
        XCTAssertEqual(i.state, "playing")
        XCTAssertFalse(i.isLive)
        XCTAssertEqual(i.speakers, [NowSpeaker(name: "Kitchen", volume: 56),
                                    NowSpeaker(name: "Office", volume: 40)])
    }

    /// The bug that started this: live stations have no duration. "-" means absent.
    func testLiveStationHasNoDurationOrPosition() {
        let raw = "Okayyy (feat. Doja Cat)|Latto|Big Mama|-|-|playing|1|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Okayyy (feat. Doja Cat)")
        XCTAssertTrue(i.isLive)
        XCTAssertNil(i.duration)
        XCTAssertNil(i.position)
    }

    /// BBC Radio 1 reports the station name and an EMPTY artist.
    func testLiveStationWithEmptyArtist() {
        let raw = "BBC Radio 1|||-|-|playing|1|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "BBC Radio 1")
        XCTAssertEqual(i.artist, "")
        XCTAssertEqual(i.album, "")
        XCTAssertTrue(i.isLive)
    }

    func testNoSpeakers() {
        let raw = "Andromeda|Gorillaz|Humanz|198|12|playing|0|"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.speakers, [])
    }

    /// Track titles may contain "|" — only the first 7 separators are structural.
    func testPipeInTrackTitleDoesNotBreakSpeakers() {
        let raw = "A|B|C|10|1|playing|0|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.speakers, [NowSpeaker(name: "Kitchen", volume: 56)])
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(parseNowOutput("nonsense"))
        XCTAssertNil(parseNowOutput(""))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test --filter NowParseTests`
Expected: FAIL — `cannot find 'parseNowOutput' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Commands/NowParse.swift
// Pure parse of the `now` AppleScript payload. No I/O, no rendering — so every
// shape (normal track, live station, stopped, loading, garbage) is unit-testable.
// Live stations have no duration/position: AppleScript emits "-" and this maps
// it to nil. Zero would be a lie about a livestream.
import Foundation

struct NowSpeaker: Equatable {
    let name: String
    let volume: Int
}

struct NowInfo: Equatable {
    let track: String
    let artist: String
    let album: String
    let duration: Int?   // nil on a live station
    let position: Int?   // nil on a live station
    let state: String
    let isLive: Bool
    let speakers: [NowSpeaker]
}

enum NowParse: Equatable {
    case stopped
    case loading
    case info(NowInfo)
}

/// Payload: track|artist|album|duration|position|state|live|speakers
/// duration/position are "-" when absent; live is "1"/"0"; speakers is
/// "Name:Vol,Name:Vol" (possibly empty). Returns nil on anything unparseable.
func parseNowOutput(_ raw: String) -> NowParse? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return .stopped }
    if trimmed == "LOADING" { return .loading }

    // maxSplits: 7 → at most 8 fields; the 8th absorbs any "|" in speaker names.
    let parts = trimmed.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 8 else { return nil }

    let optInt: (String) -> Int? = { $0 == "-" ? nil : Int($0) }

    let speakers: [NowSpeaker] = parts[7]
        .split(separator: ",")
        .compactMap { pair in
            let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard let name = kv.first, !name.isEmpty else { return nil }
            return NowSpeaker(name: name, volume: Int(kv.count > 1 ? kv[1] : "0") ?? 0)
        }

    return .info(NowInfo(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: optInt(parts[3]), position: optInt(parts[4]),
        state: parts[5], isLive: parts[6] == "1",
        speakers: speakers
    ))
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test --filter NowParseTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/NowParse.swift tools/music/Tests/MusicTests/NowParseTests.swift
git commit -m "refactor(now): extract pure parseNowOutput with live-station support"
```

---

## Task 2: Make `now` emit the live-safe payload and render it

**Files:**
- Modify: `Sources/Commands/PlaybackCommands.swift` (the `now` AppleScript + render, ~440-510)

The root cause: `round d` throws when `duration` is `missing value`, the `try` swallows it, the loop burns 10 × 0.3s = **3 seconds**, `info` stays empty, `"LOADING"` is returned, and the old `guard parts.count >= 7` prints "Unexpected output".

- [ ] **Step 1: Replace the AppleScript body**

Find the `repeat 10 times` block and replace the `try` body with:

```applescript
set state to player state as text
\(stoppedCheck)
set t to name of current track
set a to artist of current track
set al to album of current track
set d to duration of current track
set p to player position
set lv to "0"
if (class of current track is URL track) and (d is missing value) then set lv to "1"
if d is missing value then
    set dTxt to "-"
else
    set dTxt to ((round d) as text)
end if
if p is missing value then
    set pTxt to "-"
else
    set pTxt to ((round p) as text)
end if
if a is missing value then set a to ""
if al is missing value then set al to ""
set info to t & "|" & a & "|" & al & "|" & dTxt & "|" & pTxt & "|" & state & "|" & lv
exit repeat
```

**Why the `class of current track is URL track` clause:** a missing duration alone shouldn't be enough to call something "live" — a cloud/unavailable ordinary track could plausibly lack one. Both signals together identify a station.

- [ ] **Step 2: Replace the parse + render**

Replace from `let trimmed = result.trimming…` through the end of the render with:

```swift
switch parseNowOutput(result) {
case .stopped:
    print(json ? "{\"state\":\"stopped\"}" : "Nothing playing.")
case .loading, .none:
    if json {
        print(#"{"error": "could not read now playing"}"#)
    } else {
        errorOut("✗ Couldn't read now playing.")
    }
case .info(let i):
    let speakers = i.speakers.map { ["name": $0.name, "volume": $0.volume] as [String: Any] }
    if json {
        var dict: [String: Any] = ["track": i.track, "artist": i.artist, "album": i.album,
                                   "state": i.state, "speakers": speakers]
        if i.isLive {
            dict["live"] = true          // duration/position deliberately ABSENT
        } else {
            dict["duration"] = i.duration ?? 0
            dict["position"] = i.position ?? 0
        }
        print(OutputFormat(mode: .json).render(dict))
    } else {
        let spkStr = i.speakers.map { "\($0.name) (vol: \($0.volume))" }.joined(separator: " | ")
        if i.isLive {
            let who = i.artist.isEmpty ? i.track : "\(i.track) — \(i.artist)"
            print("\(who) [LIVE]")
        } else {
            print("\(i.track) — \(i.artist) [\(i.album)]")
        }
        if !spkStr.isEmpty { print(spkStr) }
    }
}
```

**Note:** `.loading` now produces an honest error instead of "Unexpected output". A real LOADING (Music genuinely mid-load) is indistinguishable from a parse failure at this layer, and both mean "can't read now playing".

- [ ] **Step 3: Build and run the full suite**

Run: `cd tools/music && swift build && swift test`
Expected: build clean; all existing tests plus `NowParseTests` pass.

- [ ] **Step 4: LIVE verification — the bug that started this**

```bash
swift build -c release && cp .build/release/music ~/.local/bin/music
open "music://music.apple.com/us/station/bbc-radio-1/ra.1460912634"
sleep 8
music now                # expect: "BBC Radio 1 [LIVE]" + speakers — NOT "Unexpected output"
music now --json | jq .   # expect: valid JSON, live:true, NO duration/position keys
time music now            # expect: fast — NOT ~3s (the retry loop no longer burns)
```

**This is the gate. Green tests do not mean this works.**

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/PlaybackCommands.swift
git commit -m "fix(now): live stations no longer break now/statusline

duration is missing value on a live station; round(missing value) threw inside
the retry try-block, burning 10x0.3s before returning LOADING, which failed the
parts guard and printed 'Unexpected output' with exit 0 — feeding garbage to
jq in statusline.sh. AppleScript now emits '-' for absent duration/position and
a live flag; parsing moved to the pure parseNowOutput."
```

---

## Task 3: Teach `statusline.sh` about live stations

**Files:** Modify: `scripts/statusline.sh`

- [ ] **Step 1: Handle live + empty artist in the jq branch**

Replace lines 22-27 with:

```bash
        STATE=$(echo "$JSON" | jq -r '.state // empty')
        [ "$STATE" = "stopped" ] && exit 0
        LIVE=$(echo "$JSON" | jq -r 'if .live then "1" else "" end')
        TRACK=$(echo "$JSON" | jq -r '.track // empty')
        ARTIST=$(echo "$JSON" | jq -r '.artist // empty')
        SPEAKERS=$(echo "$JSON" | jq -r '[.speakers[]?.name] | join(", ")')
        VOLUMES=$(echo "$JSON" | jq -r '[.speakers[]?.volume] | map(tostring) | join(", ")')
```

- [ ] **Step 2: Handle live in the grep fallback**

Replace lines 29-34 with:

```bash
        STATE=$(echo "$JSON" | grep -o '"state":"[^"]*"' | cut -d'"' -f4)
        [ "$STATE" = "stopped" ] && exit 0
        echo "$JSON" | grep -q '"live":true' && LIVE=1 || LIVE=""
        TRACK=$(echo "$JSON" | grep -o '"track":"[^"]*"' | cut -d'"' -f4)
        ARTIST=$(echo "$JSON" | grep -o '"artist":"[^"]*"' | cut -d'"' -f4)
        SPEAKERS=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd', ' -)
        VOLUMES=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"volume":[0-9]*' | cut -d: -f2 | paste -sd', ' -)
```

- [ ] **Step 3: Render it**

Replace lines 37-43 with:

```bash
    [ "$STATE" = "playing" ] && ICON="▶" || ICON="⏸"
    [ -n "$LIVE" ] && ICON="$ICON ◉"

    # BBC Radio 1 reports an empty artist; Apple's live stations report the song.
    if [ -n "$ARTIST" ]; then
        LABEL="$TRACK — $ARTIST"
    else
        LABEL="$TRACK"
    fi

    if [ -n "$SPEAKERS" ]; then
        echo "$ICON $LABEL  ·  $SPEAKERS [$VOLUMES]"
    else
        echo "$ICON $LABEL"
    fi
```

- [ ] **Step 4: LIVE verification**

```bash
open "music://music.apple.com/us/station/bbc-radio-1/ra.1460912634"; sleep 8
bash scripts/statusline.sh </dev/null   # expect: "▶ ◉ BBC Radio 1  ·  Kitchen [56]" — no jq errors
music pause
bash scripts/statusline.sh </dev/null   # expect: "⏸ ◉ BBC Radio 1 …"
```

- [ ] **Step 5: Commit and SHIP PHASE 1**

```bash
git add scripts/statusline.sh
git commit -m "fix(statusline): render live stations with a LIVE marker"
```

Then bump the patch version in all four locations (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` ×2, `tools/music/Sources/Music.swift`), run `scripts/install.sh`, commit, push, `git tag`, `gh release create`, read the body back, **and bump the Homebrew tap formula** (tarball URL, sha256, version test string) then live-test `brew upgrade musictui`. Per CLAUDE.md, the bump is not shipped until tagged, released, and tapped.

---

# PHASE 2 — the Radio tab

## Task 4: `StationPlayback` — the mechanism

**Files:**
- Create: `Sources/TUI/StationPlayback.swift`
- Test: `Tests/MusicTests/StationPlaybackTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/StationPlaybackTests.swift
import XCTest
@testable import musicPackage

final class StationPlaybackTests: XCTestCase {
    func testRewritesHttpsToMusicScheme() {
        XCTAssertEqual(
            stationPlayURL("https://music.apple.com/us/station/apple-music-1/ra.978194965"),
            "music://music.apple.com/us/station/apple-music-1/ra.978194965")
    }

    func testAlreadyMusicSchemePassesThrough() {
        XCTAssertEqual(
            stationPlayURL("music://music.apple.com/us/station/x/ra.1"),
            "music://music.apple.com/us/station/x/ra.1")
    }

    /// A pasted ALBUM url must be rejected — music:// would silently play an
    /// album, which looks like a bug in radio.
    func testRejectsNonStationPaths() {
        XCTAssertNil(stationPlayURL("https://music.apple.com/us/album/humanz/1234"))
        XCTAssertNil(stationPlayURL("https://music.apple.com/us/playlist/chill/pl.1"))
    }

    func testRejectsForeignHosts() {
        XCTAssertNil(stationPlayURL("https://example.com/us/station/x/ra.1"))
        XCTAssertNil(stationPlayURL("https://evil.com/station/x/ra.1"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(stationPlayURL(""))
        XCTAssertNil(stationPlayURL("not a url"))
    }

    func testParsesSlugAndID() {
        let p = parseStationURL("https://music.apple.com/us/station/bbc-radio-1/ra.1460912634")
        XCTAssertEqual(p?.id, "ra.1460912634")
        XCTAssertEqual(p?.slug, "bbc-radio-1")
    }

    /// The API cannot resolve BBC Radio 1 — the slug is the only name we get.
    func testDisplayNameFromSlug() {
        XCTAssertEqual(displayNameFromSlug("bbc-radio-1"), "Bbc Radio 1")
        XCTAssertEqual(displayNameFromSlug("apple-music-chill"), "Apple Music Chill")
        XCTAssertEqual(displayNameFromSlug("apple-m%C3%BAsica-uno"), "Apple Música Uno")
    }

    func testPlayStationUsesTheOpenerSeam() throws {
        final class SpyOpener: Opener {
            var opened: [String] = []
            func open(_ url: String) throws { opened.append(url) }
        }
        let spy = SpyOpener()
        let s = Station(id: "ra.1", name: "X", url: "https://music.apple.com/us/station/x/ra.1",
                        isLive: nil, artworkURL: nil)
        try playStation(s, via: spy)
        XCTAssertEqual(spy.opened, ["music://music.apple.com/us/station/x/ra.1"])
    }

    func testPlayStationThrowsOnBadURL() {
        final class SpyOpener: Opener {
            var opened: [String] = []
            func open(_ url: String) throws { opened.append(url) }
        }
        let spy = SpyOpener()
        let s = Station(id: "x", name: "X", url: "https://example.com/nope",
                        isLive: nil, artworkURL: nil)
        XCTAssertThrowsError(try playStation(s, via: spy))
        XCTAssertTrue(spy.opened.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test --filter StationPlaybackTests`
Expected: FAIL — `cannot find 'stationPlayURL' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TUI/StationPlayback.swift
// Apple Music stations play by rewriting the station's REST share URL from
// https:// to music:// and handing it to `open` — probed and audio-verified
// 2026-07-15. The https:// form opens Safari; the scheme IS the mechanism.
// No AppleScript, no Accessibility, no MusicKit; the AirPlay route survives.
import Foundation

struct Station: Codable, Equatable {
    let id: String          // ra.978194965
    let name: String
    let url: String         // the https:// share URL — the play handle
    let isLive: Bool?       // nil = unknown; observed at play time (no duration ⇒ live)
    let artworkURL: String?
}

enum StationError: Error, Equatable {
    case notAStationURL(String)
}

protocol Opener {
    func open(_ url: String) throws
}

/// Hands the URL to macOS via /usr/bin/open. The only impure part of this file.
struct SystemOpener: Opener {
    func open(_ url: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url]
        try p.run()
        p.waitUntilExit()
    }
}

/// https://music.apple.com/{sf}/station/{slug}/{id} -> music://…
/// nil unless the host is music.apple.com AND the path is a /station/ path.
/// Both checks matter: music:// on an album URL would silently play an album.
func stationPlayURL(_ shareURL: String) -> String? {
    guard let comps = URLComponents(string: shareURL.trimmingCharacters(in: .whitespaces)),
          let host = comps.host, host == "music.apple.com",
          comps.path.contains("/station/"),
          let scheme = comps.scheme, ["http", "https", "music"].contains(scheme)
    else { return nil }
    var out = comps
    out.scheme = "music"
    return out.string
}

/// Pull the id and slug out of a station share URL. Pure; works even when the
/// catalog API cannot resolve the station (the BBC Radio 1 case).
func parseStationURL(_ shareURL: String) -> (id: String, slug: String)? {
    guard let comps = URLComponents(string: shareURL), comps.host == "music.apple.com" else { return nil }
    let segs = comps.path.split(separator: "/").map(String.init)
    guard let sIdx = segs.firstIndex(of: "station"), segs.count > sIdx + 2 else { return nil }
    return (id: segs[sIdx + 2], slug: segs[sIdx + 1])
}

/// "bbc-radio-1" -> "Bbc Radio 1". Percent-escapes are decoded first so
/// "apple-m%C3%BAsica-uno" -> "Apple Música Uno". Used only when the API can't
/// resolve the id — a best-effort label, never presented as authoritative.
func displayNameFromSlug(_ slug: String) -> String {
    let decoded = slug.removingPercentEncoding ?? slug
    return decoded.split(separator: "-")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

func playStation(_ station: Station, via opener: Opener) throws {
    guard let url = stationPlayURL(station.url) else {
        throw StationError.notAStationURL(station.url)
    }
    try opener.open(url)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test --filter StationPlaybackTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/StationPlayback.swift tools/music/Tests/MusicTests/StationPlaybackTests.swift
git commit -m "feat(radio): StationPlayback — music:// scheme rewrite behind an Opener seam"
```

---

## Task 5: `StationStore` — favorites on disk

**Files:**
- Create: `Sources/TUI/StationStore.swift`
- Test: `Tests/MusicTests/StationStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/StationStoreTests.swift
import XCTest
@testable import musicPackage

final class StationStoreTests: XCTestCase {
    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "station-store-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func station(_ id: String, _ name: String = "N") -> Station {
        Station(id: id, name: name, url: "https://music.apple.com/us/station/s/\(id)",
                isLive: nil, artworkURL: nil)
    }

    func testEmptyWhenFileMissing() {
        XCTAssertEqual(StationStore(path: tmp).favorites(), [])
    }

    func testAddThenRoundTripFromDisk() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1", "Apple Music 1"))
        XCTAssertEqual(StationStore(path: tmp).favorites().map(\.id), ["ra.1"])
        XCTAssertEqual(StationStore(path: tmp).favorites().first?.name, "Apple Music 1")
    }

    func testAddIsIdempotentOnID() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.add(station("ra.1"))
        XCTAssertEqual(s.favorites().count, 1)
    }

    /// Re-adding refreshes metadata (a later API resolve may fill in a real name).
    func testReAddReplacesMetadata() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1", "Bbc Radio 1"))
        try s.add(station("ra.1", "BBC Radio 1"))
        XCTAssertEqual(s.favorites().count, 1)
        XCTAssertEqual(s.favorites().first?.name, "BBC Radio 1")
    }

    func testRemove() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.add(station("ra.2"))
        try s.remove(id: "ra.1")
        XCTAssertEqual(s.favorites().map(\.id), ["ra.2"])
    }

    func testRemoveMissingIsNoOp() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.remove(id: "nope")
        XCTAssertEqual(s.favorites().count, 1)
    }

    func testIsFavorite() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        XCTAssertTrue(s.isFavorite(id: "ra.1"))
        XCTAssertFalse(s.isFavorite(id: "ra.2"))
    }

    func testInsertionOrderPreserved() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1")); try s.add(station("ra.2")); try s.add(station("ra.3"))
        XCTAssertEqual(s.favorites().map(\.id), ["ra.1", "ra.2", "ra.3"])
    }

    func testCorruptFileDegradesToEmpty() throws {
        try "not json".write(toFile: tmp, atomically: true, encoding: .utf8)
        XCTAssertEqual(StationStore(path: tmp).favorites(), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test --filter StationStoreTests`
Expected: FAIL — `cannot find 'StationStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TUI/StationStore.swift
// Favorite stations, persisted locally at ~/.config/music/stations.json —
// deliberately NOT Apple's library. A station added to the library becomes a
// URL track whose *name is its id* ("ra.978194965"), which would litter the
// Songs list. Local storage also keeps stations the catalog API cannot resolve
// (BBC Radio 1) as first-class favorites: each entry carries its own url+name,
// so the tab paints and plays from disk with no network at all.
import Foundation

final class StationStore {
    private let path: String
    private let lock = NSLock()
    private var cache: [Station]?

    init(path: String = NSString(string: "~/.config/music/stations.json").expandingTildeInPath) {
        self.path = path
    }

    /// Insertion order is the display order. A corrupt or missing file reads as
    /// empty — favorites are a convenience, never a reason to error at the user.
    func favorites() -> [Station] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([Station].self, from: data)
        else { cache = []; return [] }
        cache = list
        return list
    }

    func isFavorite(id: String) -> Bool {
        favorites().contains { $0.id == id }
    }

    /// Add or refresh. Re-adding replaces metadata in place, keeping position —
    /// a later API resolve can upgrade a slug-derived name to the real one.
    func add(_ station: Station) throws {
        var list = favorites()
        if let i = list.firstIndex(where: { $0.id == station.id }) {
            list[i] = station
        } else {
            list.append(station)
        }
        try write(list)
    }

    func remove(id: String) throws {
        try write(favorites().filter { $0.id != id })
    }

    func toggle(_ station: Station) throws {
        isFavorite(id: station.id) ? try remove(id: station.id) : try add(station)
    }

    private func write(_ list: [Station]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(list)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        lock.lock(); cache = list; lock.unlock()
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test --filter StationStoreTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/StationStore.swift tools/music/Tests/MusicTests/StationStoreTests.swift
git commit -m "feat(radio): StationStore — local favorites at ~/.config/music/stations.json"
```

---

## Task 6: `RadioCatalog` — REST reads

**Files:**
- Create: `Sources/TUI/RadioCatalog.swift`
- Test: `Tests/MusicTests/RadioCatalogTests.swift`

Endpoints (all live-probed 2026-07-15, developer token only — **no** Music-User-Token):

| What | Request |
|---|---|
| Live lineup (6) | `stations?filter[featured]=apple-music-live-radio` |
| Personal (1) | `stations?filter[identity]=personal` |
| By id | `stations?ids=ra.978194965` — may return `data: []` (BBC Radio 1) |
| Search | `search?term=chill&types=stations&limit=25` — 5-7 hits, no pagination |

There is **no browse-all** (`400`) and **no genre browse** (a station-genre is a bare label).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/RadioCatalogTests.swift
import XCTest
@testable import musicPackage

final class RadioCatalogTests: XCTestCase {
    /// Verbatim shape from the live probe (2026-07-15).
    private let stationsJSON = """
    {"data":[
      {"id":"ra.978194965","attributes":{
        "name":"Apple Music 1","isLive":true,
        "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965",
        "artwork":{"url":"https://example.com/{w}x{h}.jpg"}}},
      {"id":"ra.1498155548","attributes":{
        "name":"Apple Music Hits","isLive":true,
        "url":"https://music.apple.com/us/station/apple-music-hits/ra.1498155548",
        "artwork":{"url":"https://example.com/b/{w}x{h}.jpg"}}}
    ]}
    """

    private let searchJSON = """
    {"results":{"stations":{"data":[
      {"id":"ra.985484943","attributes":{
        "name":"Chill Station","isLive":false,
        "url":"https://music.apple.com/us/station/chill-station/ra.985484943",
        "artwork":{"url":"https://example.com/c/{w}x{h}.jpg"}}}
    ]}}}
    """

    private func catalog(_ body: String, capture: ((String) -> Void)? = nil) -> RadioCatalog {
        RadioCatalog(storefront: "us", token: { "tok" }, fetch: { url in
            capture?(url)
            return body.data(using: .utf8)
        })
    }

    func testDecodesLiveLineup() throws {
        let out = try catalog(stationsJSON).liveStations()
        XCTAssertEqual(out.map(\.id), ["ra.978194965", "ra.1498155548"])
        XCTAssertEqual(out.first?.name, "Apple Music 1")
        XCTAssertEqual(out.first?.isLive, true)
        XCTAssertEqual(out.first?.url, "https://music.apple.com/us/station/apple-music-1/ra.978194965")
        XCTAssertEqual(out.first?.artworkURL, "https://example.com/{w}x{h}.jpg")
    }

    func testLiveLineupHitsTheFeaturedFilter() throws {
        var seen = ""
        _ = try catalog(stationsJSON, capture: { seen = $0 }).liveStations()
        XCTAssertTrue(seen.contains("/v1/catalog/us/stations"))
        XCTAssertTrue(seen.contains("filter%5Bfeatured%5D=apple-music-live-radio")
                      || seen.contains("filter[featured]=apple-music-live-radio"))
    }

    func testPersonalHitsTheIdentityFilter() throws {
        var seen = ""
        _ = try catalog(stationsJSON, capture: { seen = $0 }).personalStation()
        XCTAssertTrue(seen.contains("filter%5Bidentity%5D=personal")
                      || seen.contains("filter[identity]=personal"))
    }

    func testDecodesSearchResults() throws {
        let out = try catalog(searchJSON).search(term: "chill")
        XCTAssertEqual(out.map(\.id), ["ra.985484943"])
        XCTAssertEqual(out.first?.isLive, false)
    }

    func testSearchEncodesTheTerm() throws {
        var seen = ""
        _ = try catalog(searchJSON, capture: { seen = $0 }).search(term: "hip hop")
        XCTAssertTrue(seen.contains("hip%20hop") || seen.contains("hip+hop"))
        XCTAssertTrue(seen.contains("types=stations"))
    }

    /// BBC Radio 1: 200 with an empty data array. NOT an error.
    func testResolveReturnsNilOnEmptyData() throws {
        let c = catalog(#"{"data":[]}"#)
        XCTAssertNil(try c.resolve(id: "ra.1460912634"))
    }

    func testResolveReturnsStation() throws {
        XCTAssertEqual(try catalog(stationsJSON).resolve(id: "ra.978194965")?.name, "Apple Music 1")
    }

    func testFetchFailureThrows() {
        let c = RadioCatalog(storefront: "us", token: { "tok" }, fetch: { _ in nil })
        XCTAssertThrowsError(try c.liveStations())
    }

    func testMissingTokenThrows() {
        let c = RadioCatalog(storefront: "us", token: { nil }, fetch: { _ in Data() })
        XCTAssertThrowsError(try c.liveStations())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test --filter RadioCatalogTests`
Expected: FAIL — `cannot find 'RadioCatalog' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TUI/RadioCatalog.swift
// Catalog station reads. Developer token only — live-verified 200 with no
// Music-User-Token (2026-07-15), which the Apple docs never state.
//
// Hard limits established by probe, do NOT design around them being fixable:
//  - no browse-all: unfiltered /stations 400s ("No id(s) supplied")
//  - no genre browse: a station-genre is {"name":"Jazz"} — no link to stations
//    in either direction, and filter[genre] 400s
//  - search is shallow (5-7 hits, no pagination) and unreliable: searching
//    "bbc radio 1" returns Mozart and Beethoven stations
//  - the API does not cover everything playable: BBC Radio 1 returns data:[]
//    by id in us/gb/be with and without a user token. Reason unknown. So
//    `resolve` returning nil is NORMAL, not an error.
import Foundation

enum RadioCatalogError: Error {
    case noToken
    case fetchFailed
    case badResponse
}

final class RadioCatalog {
    private let storefront: String
    private let token: () -> String?
    private let fetch: (String) -> Data?

    init(storefront: String, token: @escaping () -> String?, fetch: @escaping (String) -> Data?) {
        self.storefront = storefront
        self.token = token
        self.fetch = fetch
    }

    private var base: String { "https://api.music.apple.com/v1/catalog/\(storefront)" }

    func liveStations() throws -> [Station] {
        try stations(at: "\(base)/stations?filter[featured]=apple-music-live-radio")
    }

    func personalStation() throws -> [Station] {
        try stations(at: "\(base)/stations?filter[identity]=personal")
    }

    /// nil when the API doesn't know the id — normal (BBC Radio 1), not an error.
    func resolve(id: String) throws -> Station? {
        try stations(at: "\(base)/stations?ids=\(id)").first
    }

    func search(term: String) throws -> [Station] {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let data = try get("\(base)/search?term=\(q)&types=stations&limit=25")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let st = results["stations"] as? [String: Any]
        else { return [] }   // no stations key = zero hits, not a failure
        return decode(st["data"] as? [[String: Any]] ?? [])
    }

    private func stations(at url: String) throws -> [Station] {
        let data = try get(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RadioCatalogError.badResponse
        }
        return decode(root["data"] as? [[String: Any]] ?? [])
    }

    private func get(_ url: String) throws -> Data {
        guard token() != nil else { throw RadioCatalogError.noToken }
        guard let data = fetch(url) else { throw RadioCatalogError.fetchFailed }
        return data
    }

    private func decode(_ rows: [[String: Any]]) -> [Station] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String,
                  let url = a["url"] as? String
            else { return nil }
            return Station(
                id: id, name: name, url: url,
                isLive: a["isLive"] as? Bool,
                artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String)
        }
    }
}

/// Wired against the real AuthManager. nil when there's no developer token —
/// callers degrade to favorites-only rather than erroring.
///
/// Implementer note: `auth.storefront()` and `auth.requireDeveloperToken()` both
/// exist — `Shell.swift:82-84` calls them exactly this way to build
/// `RESTAPIBackend(developerToken:userToken:storefront:)`. Check the return types
/// (`storefront()` may be non-optional) and adapt the guard accordingly.
func makeCatalog() -> RadioCatalog? {
    let auth = AuthManager()
    guard (try? auth.requireDeveloperToken()) != nil else { return nil }
    return RadioCatalog(
        storefront: auth.storefront(),
        token: { try? AuthManager().requireDeveloperToken() },
        fetch: { urlString in
            guard let url = URL(string: urlString),
                  let tok = try? AuthManager().requireDeveloperToken() else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 20)
            return out
        })
}
```

**`makeCatalog()` lives here, not in the CLI file** — Task 8 (the scene) needs it before Task 9 (the verbs) exists.

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test --filter RadioCatalogTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/RadioCatalog.swift tools/music/Tests/MusicTests/RadioCatalogTests.swift
git commit -m "feat(radio): RadioCatalog — featured/personal/search/resolve over REST"
```

---

## Task 7: `RadioNav` — the pure reducer

**Files:**
- Create: `Sources/TUI/RadioNav.swift`
- Test: `Tests/MusicTests/RadioNavTests.swift`

Mirrors `LibraryNav` (`Sources/TUI/LibraryNav.swift`) minus the drill stack — stations are flat, so there is no `stack` and no `.back` level pop.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/RadioNavTests.swift
import XCTest
@testable import musicPackage

final class RadioNavTests: XCTestCase {
    private func sel(_ id: String) -> Station {
        Station(id: id, name: id, url: "https://music.apple.com/us/station/s/\(id)",
                isLive: nil, artworkURL: nil)
    }

    func testInitialIsFavorites() {
        XCTAssertEqual(RadioNav.initial.subView, .favorites)
        XCTAssertEqual(RadioNav.initial.cursor, 0)
    }

    func testDownClampsToItemCount() {
        let (s, _) = radioReduce(RadioNav.initial, .down, itemCount: 2, selection: nil)
        XCTAssertEqual(s.cursor, 1)
        let (s2, _) = radioReduce(s, .down, itemCount: 2, selection: nil)
        XCTAssertEqual(s2.cursor, 1)   // clamped
    }

    func testDownOnEmptyListStaysAtZero() {
        let (s, _) = radioReduce(RadioNav.initial, .down, itemCount: 0, selection: nil)
        XCTAssertEqual(s.cursor, 0)
    }

    func testUpClampsAtZero() {
        let (s, _) = radioReduce(RadioNav.initial, .up, itemCount: 3, selection: nil)
        XCTAssertEqual(s.cursor, 0)
    }

    func testSwitchNextCyclesForwardAndWraps() {
        var s = RadioNav.initial
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .live)
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .personal)
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .favorites)   // wraps
    }

    func testSwitchPrevWrapsBackwards() {
        let (s, _) = radioReduce(RadioNav.initial, .switchPrev, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .personal)
    }

    func testSwitchResetsCursor() {
        var s = radioReduce(RadioNav.initial, .down, itemCount: 5, selection: nil).0
        XCTAssertEqual(s.cursor, 1)
        s = radioReduce(s, .switchNext, itemCount: 5, selection: nil).0
        XCTAssertEqual(s.cursor, 0)
    }

    func testEnterEmitsPlay() {
        let (_, a) = radioReduce(RadioNav.initial, .enter, itemCount: 1, selection: sel("ra.1"))
        XCTAssertEqual(a, .play(sel("ra.1")))
    }

    func testEnterWithNoSelectionIsNoOp() {
        let (_, a) = radioReduce(RadioNav.initial, .enter, itemCount: 0, selection: nil)
        XCTAssertEqual(a, .none)
    }

    func testToggleFavEmitsToggle() {
        let (_, a) = radioReduce(RadioNav.initial, .toggleFav, itemCount: 1, selection: sel("ra.1"))
        XCTAssertEqual(a, .toggleFavorite(sel("ra.1")))
    }

    func testToggleFavWithNoSelectionIsNoOp() {
        let (_, a) = radioReduce(RadioNav.initial, .toggleFav, itemCount: 0, selection: nil)
        XCTAssertEqual(a, .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/music && swift test --filter RadioNavTests`
Expected: FAIL — `cannot find 'RadioNav' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TUI/RadioNav.swift
// Pure navigation model for the Radio tab — mirrors LibraryNav (same [ / ]
// sub-view cycle, same reducer signature) minus the drill stack: stations are
// flat, there is nothing to drill into.
import Foundation

// Declaration order IS the on-screen order and the [ / ] cycle order.
// Favorites first: it's the home, it paints from disk with no network, and it's
// the only sub-view that works with no token.
enum RadioSubView: CaseIterable, Equatable { case favorites, live, personal }

enum RadioKey { case up, down, enter, switchNext, switchPrev, toggleFav }

enum RadioAction: Equatable {
    case none
    case play(Station)
    case toggleFavorite(Station)
}

struct RadioNav: Equatable {
    var subView: RadioSubView
    var cursor: Int

    static let initial = RadioNav(subView: .favorites, cursor: 0)
}

func radioReduce(_ state: RadioNav, _ key: RadioKey,
                 itemCount: Int, selection: Station?) -> (RadioNav, RadioAction) {
    var s = state
    switch key {
    case .up:
        s.cursor = max(0, s.cursor - 1)
        return (s, .none)

    case .down:
        s.cursor = min(max(0, itemCount - 1), s.cursor + 1)
        return (s, .none)

    case .switchNext, .switchPrev:
        let all = RadioSubView.allCases
        let idx = all.firstIndex(of: s.subView)!
        let next = key == .switchNext ? (idx + 1) % all.count : (idx - 1 + all.count) % all.count
        s.subView = all[next]
        s.cursor = 0
        return (s, .none)

    case .enter:
        guard let sel = selection else { return (s, .none) }
        return (s, .play(sel))

    case .toggleFav:
        guard let sel = selection else { return (s, .none) }
        return (s, .toggleFavorite(sel))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/music && swift test --filter RadioNavTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/RadioNav.swift tools/music/Tests/MusicTests/RadioNavTests.swift
git commit -m "feat(radio): RadioNav pure reducer mirroring LibraryNav"
```

---

## Task 8: `RadioScene` + tab wiring

**Files:**
- Create: `Sources/TUI/Shell/RadioScene.swift`
- Modify: `Sources/TUI/Shell/Router.swift` (the `SceneID` enum, line 5)
- Modify: `Sources/TUI/Shell/Shell.swift` (tab registration)

Read `Sources/TUI/Shell/LibraryScene.swift` before starting — `RadioScene` follows its structure exactly (capture branch → `vimAlias` → key mapping → reducer → action execution).

- [ ] **Step 1: Add the SceneID case**

`Sources/TUI/Shell/Router.swift` line 5:

```swift
case nowPlaying, playlists, speakers, search, library, queue, radio
```

- [ ] **Step 2: Write the scene**

```swift
// Sources/TUI/Shell/RadioScene.swift
// The Radio tab: Favorites · Live · Personal, cycled with [ / ].
// Playback is the music:// scheme rewrite (StationPlayback). Favorites carry
// their own url+name so this tab paints and plays with NO network and NO token —
// Live/Personal/search degrade to an honest message instead.
import Foundation

final class RadioScene: Scene {
    let id: SceneID = .radio
    let tabTitle = "Radio"

    private var nav = RadioNav.initial
    private let store: StationStore
    private let catalog: RadioCatalog?
    private let opener: Opener

    private var live: [Station] = []
    private var personal: [Station] = []
    private var searchHits: [Station] = []

    // Raw text entry. `capturing` mirrors LibraryScene's filter capture; `adding`
    // is the `a` flow (URL or search term).
    private var capturing = false
    private var filter = ""
    private var adding = false
    private var addText = ""
    private var message: String?

    init(store: StationStore, catalog: RadioCatalog?, opener: Opener = SystemOpener()) {
        self.store = store
        self.catalog = catalog
        self.opener = opener
    }

    var capturesAllInput: Bool { capturing || adding }

    private var rows: [Station] {
        let base: [Station]
        switch nav.subView {
        case .favorites: base = store.favorites()
        case .live:      base = live
        case .personal:  base = personal
        }
        guard !filter.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var selection: Station? {
        let r = rows
        guard nav.cursor >= 0, nav.cursor < r.count else { return nil }
        return r[nav.cursor]
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Raw text entry FIRST — before vimAlias, or typed letters get eaten by
        // navigation (the 3.6.0 gotcha; see docs/playbook.md).
        if adding {
            switch key {
            case .enter:  commitAdd(); adding = false; addText = ""
            case .escape: adding = false; addText = ""; message = nil
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !addText.isEmpty { addText.removeLast() }
            case .char(let c): addText.append(c)
            default: break
            }
            return .redraw
        }

        if capturing {
            switch key {
            case .enter:  capturing = false
            case .escape: capturing = false; filter = ""; nav.cursor = 0
            case .up:     nav.cursor = max(0, nav.cursor - 1)
            case .down:   nav.cursor = min(max(0, rows.count - 1), nav.cursor + 1)
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filter.isEmpty { filter.removeLast() }; nav.cursor = 0
            case .char(let c): filter.append(c); nav.cursor = 0
            default: break
            }
            return .redraw
        }

        let key = vimAlias(key, listScene: true)

        let rKey: RadioKey
        switch key {
        case .up:    rKey = .up
        case .down:  rKey = .down
        case .enter, .right: rKey = .enter
        case .char("["): rKey = .switchPrev
        case .char("]"): rKey = .switchNext
        case .char("f"): rKey = .toggleFav
        case .char("/"): capturing = true; return .redraw
        case .char("a"): adding = true; addText = ""; message = nil; return .redraw
        default: return .none
        }

        let (next, action) = radioReduce(nav, rKey, itemCount: rows.count, selection: selection)
        nav = next
        execute(action)
        return .redraw
    }

    private func execute(_ action: RadioAction) {
        switch action {
        case .none:
            break
        case .play(let s):
            do { try playStation(s, via: opener); message = "▶ \(s.name)" }
            catch { message = "✗ Couldn't start \(s.name)" }
        case .toggleFavorite(let s):
            do { try store.toggle(s) } catch { message = "✗ Couldn't save favorite" }
        }
    }

    /// One affordance, two inputs. URL detection is by SCHEME PREFIX only — not
    /// a heuristic. A bare "music.apple.com/..." is treated as a search term and
    /// simply finds nothing; that's predictable. Do not try to be clever here.
    private func commitAdd() {
        let input = addText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        let isURL = ["http://", "https://", "music://"].contains { input.hasPrefix($0) }
        if isURL {
            guard stationPlayURL(input) != nil, let p = parseStationURL(input) else {
                message = "✗ Not an Apple Music station URL"
                return
            }
            // Enrich if the API knows it; fall back to the slug if not. The API
            // is an optimization — BBC Radio 1 is unresolvable and must still work.
            let resolved = try? catalog?.resolve(id: p.id)
            let station = (resolved ?? nil) ?? Station(
                id: p.id, name: displayNameFromSlug(p.slug), url: input,
                isLive: nil, artworkURL: nil)
            do { try store.add(station); message = "★ \(station.name)" }
            catch { message = "✗ Couldn't save favorite" }
        } else {
            guard let catalog else { message = "✗ Search needs auth (music auth setup)"; return }
            do {
                searchHits = try catalog.search(term: input)
                message = searchHits.isEmpty
                    ? "No stations for “\(input)” — try pasting the station URL"
                    : "\(searchHits.count) result(s) — f to favorite"
            } catch {
                message = "✗ Search failed"
            }
        }
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        // Live/Personal are fetched once, lazily, off the first tick after the
        // tab is entered. Favorites need no fetch — they're already on disk.
        guard let catalog, !loadAttempted else { return false }
        loadAttempted = true
        live = (try? catalog.liveStations()) ?? []
        personal = (try? catalog.personalStation()) ?? []
        return !(live.isEmpty && personal.isEmpty)
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        renderRadioBody(frame: frame, subView: nav.subView, rows: rows,
                        cursor: nav.cursor, filter: filter,
                        adding: adding, addText: addText, message: message)
    }
}
```

Add the `loadAttempted` field alongside the other private state:

```swift
    private var loadAttempted = false
```

**`render` is deliberately deferred to Task 8b.** This task's `render` calls `renderRadioBody`, which Task 8b writes. To keep this task independently compilable and testable, add a temporary minimal implementation at the bottom of the file:

```swift
// TEMPORARY — replaced in Task 8b by the rail+hero renderer.
// A plain list is enough to prove keys, reducer, and tab wiring work.
func renderRadioBody(frame: ShellFrame, subView: RadioSubView, rows: [Station],
                     cursor: Int, filter: String, adding: Bool, addText: String,
                     message: String?) -> String {
    var out = ""
    var y = frame.bodyY
    let put: (String) -> Void = { line in
        out += "\u{1B}[\(y);1H\u{1B}[K" + String(line.prefix(frame.width))
        y += 1
    }
    put("  \(RadioSubView.allCases.map { $0 == subView ? "[\($0)]" : "\($0)" }.joined(separator: "  "))")
    if adding { put("  add> \(addText)") }
    else if !filter.isEmpty { put("  /\(filter)") }
    if let m = message { put("  \(m)") }
    for (i, s) in rows.enumerated() where y < frame.bodyY + frame.bodyHeight {
        put("\(i == cursor ? " ▸ " : "   ")\(s.name)\(s.isLive == true ? "  [LIVE]" : "")")
    }
    if rows.isEmpty { put("   (empty)") }
    return out
}
```

- [ ] **Step 3: Register the tab**

`Sources/TUI/Shell/Shell.swift` — scenes are built lazily in a factory keyed by `SceneID` (see the `LibraryScene` construction around line 82, which reads `auth.storefront()` and builds a `RESTAPIBackend`). Add a `case .radio:` branch following that same shape:

```swift
        case .radio:
            // makeCatalog() already returns nil with no developer token.
            let scene = RadioScene(store: StationStore(), catalog: makeCatalog())
            scenes[id] = scene
            return scene
```

`catalog` is `nil` with no developer token — Favorites still list and play, Live/Personal render empty. Also add `.radio` to whatever drives the tab strip order (mirror how `.library` is listed) — place Radio after Library.

- [ ] **Step 4: Build and test**

Run: `cd tools/music && swift build && swift test`
Expected: build clean, all tests pass.

- [ ] **Step 5: LIVE smoke — the tab works before it looks good**

```bash
swift build -c release && cp .build/release/music ~/.local/bin/music && music
```

- [ ] Radio tab appears; `[` / `]` cycle the three sub-views
- [ ] `Enter` on a Live station is **audible**
- [ ] `/` and `a` capture text; typing "f"/"a"/"[" into them does NOT trigger nav

- [ ] **Step 6: Commit**

```bash
git add tools/music/Sources/TUI/Shell/RadioScene.swift tools/music/Sources/TUI/Shell/Router.swift tools/music/Sources/TUI/Shell/Shell.swift
git commit -m "feat(radio): Radio tab — keys, reducer wiring, plain-list render"
```

---

## Task 8b: Rail + hero render

**Files:** Modify: `Sources/TUI/Shell/RadioScene.swift`

This replaces the temporary `renderRadioBody` with the real rail+hero surface.

**This task cannot be pre-written as code and must not be guessed.** `LibraryScene.swift` is 1045 lines; its render lives at `:389` with private helpers `renderRail` `:785`, `renderSongList` `:842`, `renderArtistList` `:875`, `renderHero` `:918`, `renderRightPane` `:1004`, and it uses `PlaylistZones` for geometry. Any render written without reading those would be confidently wrong.

- [ ] **Step 1: Read the reference**

Read `Sources/TUI/Shell/LibraryScene.swift:389-460` (render) and `:785-1045` (the five helpers), plus `PlaylistZones` in `Sources/TUI/PlaylistBrowserModel.swift`. Note how `ArtworkStore` is called and how `kittyEnabled` threads through.

- [ ] **Step 2: Mirror it**

Rewrite `renderRadioBody` as a rail (station names, cursor, LIVE markers, `★` on favorites) plus a hero (station artwork via `ArtworkStore`, name, `editorialNotes` if present). Reuse `PlaylistZones` — do not invent new geometry. If a needed helper is private to `LibraryScene`, **extract it to a shared file rather than duplicating it**; `LibraryScene` is already 1045 lines and a split is warranted.

Two rules from the design:
- **Live stations show a `LIVE` badge, never a progress bar** — they have no duration or position.
- Artwork misses fall back to the existing gradient identicon; art is decoration and must never error at the user.

`RadioScene` will need `kittyEnabled` passed in (as `LibraryScene` takes it) — add it to `init` and to the `Shell.swift` construction from Task 8.

- [ ] **Step 3: Build and test**

Run: `cd tools/music && swift build && swift test`
Expected: clean.

- [ ] **Step 4: LIVE verification**

- [ ] Rail shows station names; `★` marks favorites; LIVE markers on live stations
- [ ] Hero shows real station artwork (kitty pixels on iTerm2/Kitty/WezTerm/Ghostty; chafa elsewhere)
- [ ] A station with no artwork shows the gradient identicon, no error
- [ ] Resizing the terminal rescales cleanly (the 3.6.0 resize fix applies)

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/RadioScene.swift
git commit -m "feat(radio): rail + hero with station artwork"
```

---

## Task 9: `music radio` CLI verbs

**Files:**
- Create: `Sources/Commands/RadioCommands.swift`
- Modify: `Sources/Music.swift` (subcommand list)

These are where the `/music` skill lands casual requests ("put on BBC Radio 1").

- [ ] **Step 1: Write the commands**

```swift
// Sources/Commands/RadioCommands.swift
// CLI surface for radio. `play` resolves by favorite name first (works with no
// token), then falls back to catalog search.
import ArgumentParser
import Foundation

struct Radio: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Play and manage radio stations.",
        subcommands: [RadioList.self, RadioPlay.self, RadioAdd.self, RadioSearch.self],
        defaultSubcommand: RadioList.self)
}

struct RadioList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List favorite stations.")
    func run() throws {
        let favs = StationStore().favorites()
        guard !favs.isEmpty else {
            print("No favorite stations. Add one: music radio add <url>")
            return
        }
        for (i, s) in favs.enumerated() {
            print("\(i + 1). \(s.name)\(s.isLive == true ? "  [LIVE]" : "")")
        }
    }
}

struct RadioPlay: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "play", abstract: "Play a station by name or URL.")
    @Argument(help: "Favorite name, search term, or station URL") var query: [String]

    func run() throws {
        let input = query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { throw ValidationError("Name or URL required.") }

        if ["http://", "https://", "music://"].contains(where: { input.hasPrefix($0) }) {
            guard let p = parseStationURL(input), stationPlayURL(input) != nil else {
                throw ValidationError("Not an Apple Music station URL.")
            }
            let s = Station(id: p.id, name: displayNameFromSlug(p.slug), url: input,
                            isLive: nil, artworkURL: nil)
            try playStation(s, via: SystemOpener())
            print("▶ \(s.name)")
            return
        }

        // Favorites first — no network, no token.
        if let hit = StationStore().favorites().first(where: {
            $0.name.localizedCaseInsensitiveContains(input)
        }) {
            try playStation(hit, via: SystemOpener())
            print("▶ \(hit.name)")
            return
        }

        guard let catalog = makeCatalog() else {
            errorOut("✗ No match in favorites, and search needs auth (music auth setup).")
            return
        }
        guard let hit = try catalog.search(term: input).first else {
            errorOut("✗ No station found for “\(input)”. Try pasting the station URL.")
            return
        }
        try playStation(hit, via: SystemOpener())
        print("▶ \(hit.name)")
    }
}

struct RadioAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Favorite a station by URL.")
    @Argument(help: "Station URL") var url: String

    func run() throws {
        guard stationPlayURL(url) != nil, let p = parseStationURL(url) else {
            throw ValidationError("Not an Apple Music station URL.")
        }
        // The API can't resolve everything playable (BBC Radio 1) — degrade, don't fail.
        let resolved = try? makeCatalog()?.resolve(id: p.id)
        let s = (resolved ?? nil) ?? Station(id: p.id, name: displayNameFromSlug(p.slug),
                                             url: url, isLive: nil, artworkURL: nil)
        try StationStore().add(s)
        print("★ \(s.name)")
    }
}

struct RadioSearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search catalog stations.")
    @Argument(help: "Search term") var term: [String]

    func run() throws {
        guard let catalog = makeCatalog() else {
            errorOut("✗ Search needs auth (music auth setup).")
            return
        }
        let hits = try catalog.search(term: term.joined(separator: " "))
        guard !hits.isEmpty else {
            print("No stations found. Station search is shallow — pasting the URL always works.")
            return
        }
        for s in hits {
            print("\(s.name)\(s.isLive == true ? "  [LIVE]" : "")\n  \(s.url)")
        }
    }
}

```

**`makeCatalog()` is defined in Task 6** (`Sources/TUI/RadioCatalog.swift`) — do not redeclare it here.

- [ ] **Step 2: Register the subcommand**

In `Sources/Music.swift`, add `Radio.self` to the `subcommands:` array.

- [ ] **Step 3: Build and test**

Run: `cd tools/music && swift build && swift test`
Expected: clean.

- [ ] **Step 4: LIVE verification**

```bash
swift build -c release && cp .build/release/music ~/.local/bin/music
music radio add "https://music.apple.com/us/station/bbc-radio-1/ra.1460912634"
music radio list                 # expect: "1. Bbc Radio 1"  (API can't resolve it — slug name)
music radio play "bbc"           # expect: ▶ and AUDIBLE BBC Radio 1
music speaker list | grep '▶'    # expect: route unchanged
music radio search chill         # expect: a few stations
```

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/RadioCommands.swift tools/music/Sources/Music.swift
git commit -m "feat(radio): music radio list/play/add/search"
```

---

## Task 10: Sweep the orphaned `__radio__` readers

`__radio__`'s producer was `startRadioStation`, deleted in `6bd5bc1` (1.11.0). The readers survived — orphaned dead code, not scaffolding. Real stations are not playlists and get no `__radio__` prefix.

**Files:**
- Modify: `Sources/TUI/PlaylistBrowserModel.swift:28`
- Modify: `Sources/TUI/Shell/PlaybackContext.swift:82-84`
- Modify: `Sources/TUI/Shell/PlaylistsScene.swift:425,456`
- Modify: `Tests/MusicTests/PlaylistBrowserModelTests.swift:7,20`

- [ ] **Step 1: Delete the badge case and its classifier**

In `PlaylistBrowserModel.swift`, remove `case radio` from `PlaylistBadge` and delete line 28 (`if name.hasPrefix("__radio__") { return .radio }`). Update the doc comment above `playlistBadge` — it currently reads "radio > recent > apple > smart > none"; make it "recent > apple > smart > none".

- [ ] **Step 2: Delete the prefix strippers**

`PlaybackContext.swift:84` — drop `"__radio__ "` from the prefix array, leaving `["__queue__ "]`. Update the doc comment on line 82 to drop the `__radio__` example.

`PlaylistsScene.swift:425` and `:456` — replace the `hasPrefix("__radio__")` ternaries with plain `m.name`.

- [ ] **Step 3: Delete the orphaned tests**

Remove the two `__radio__` assertions in `PlaylistBrowserModelTests.swift` (lines 7 and 20). If a test exists solely to assert `.radio`, delete the whole test; if `.radio` is one assertion among others, delete just that line.

- [ ] **Step 4: Verify nothing references it**

Run: `cd tools/music && grep -rn "__radio__\|PlaylistBadge.radio\|\.radio" Sources/ Tests/ | grep -v "SceneID" | grep -v "RadioScene\|RadioNav\|RadioCatalog\|RadioSubView"`
Expected: **no output**.

Run: `swift build && swift test`
Expected: clean, all pass.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/PlaylistBrowserModel.swift tools/music/Sources/TUI/Shell/PlaybackContext.swift tools/music/Sources/TUI/Shell/PlaylistsScene.swift tools/music/Tests/MusicTests/PlaylistBrowserModelTests.swift
git commit -m "chore: sweep orphaned __radio__ readers (producer died in 6bd5bc1)"
```

---

## Task 11: Docs travel with code

Per CLAUDE.md, README / `skills/music/SKILL.md` / `docs/guide.md` move in the **same commit** as TUI-key and behavior changes.

**Files:**
- Modify: `README.md`, `skills/music/SKILL.md`, `docs/guide.md`

- [ ] **Step 1: README**

Add Radio to the tab list and the feature list. Document the keys: `[` / `]` cycle Favorites · Live · Personal, `Enter` plays, `f` favorites, `a` adds by URL or search term, `/` filters. Add the `music radio list/play/add/search` verbs.

- [ ] **Step 2: SKILL.md**

Add radio triggers to the skill description so casual requests route correctly: "put on BBC Radio 1", "play Apple Music 1", "what radio stations do I have", "favorite this station", "add this radio station". Document `music radio play <name|url>` as the entry point. **Note the honest limitation:** station search is shallow and misses many real stations (BBC Radio 1 among them) — when search fails, ask the user for the station's URL from music.apple.com rather than claiming it doesn't exist.

- [ ] **Step 3: docs/guide.md**

Document the Radio tab and verbs. State plainly that favorites are stored locally at `~/.config/music/stations.json` and do not sync to other devices.

- [ ] **Step 4: Commit**

```bash
git add README.md skills/music/SKILL.md docs/guide.md
git commit -m "docs: Radio tab, music radio verbs, honest search limitations"
```

---

## Task 12: Ship Phase 2

- [ ] **Step 1: Full live verification (the definition of done)**

Green tests are **not** done. Every item needs a human:

```bash
music                       # open the TUI
```

- [ ] Radio tab appears alongside Now / Playlists / Library / Speakers
- [ ] `[` / `]` cycle Favorites · Live · Personal
- [ ] Live shows 6 stations (Apple Music 1 / Hits / Country / Música Uno / Club / Chill)
- [ ] Personal shows "Anthony Maley's Station"
- [ ] `Enter` on a live station → **audible**, LIVE badge, no progress bar
- [ ] `Enter` on a track-based station → **audible**, real duration and progress
- [ ] **AirPlay route survives** every play (`music speaker list | grep '▶'`)
- [ ] `f` favorites a station; it appears in Favorites and survives a TUI restart
- [ ] `a` + BBC Radio 1's URL → becomes a working favorite **despite the API not knowing it exists**
- [ ] `a` + "chill" → search results
- [ ] `/` filters the current list; **typing "f", "a", "[" into the filter does NOT trigger nav** (the 3.6.0 gotcha)
- [ ] `music now` and `statusline.sh` both survive a live station
- [ ] With no token: Favorites still list and play; Live/Personal show an honest message

- [ ] **Step 2: Ship**

Bump the minor version in all four locations (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` ×2, `tools/music/Sources/Music.swift`), run `scripts/install.sh`, `swift test`, commit, push, `git tag vX.Y.0`, `git push origin vX.Y.0`, `gh release create` (quoted heredoc; **read the body back**), then **bump the Homebrew tap** (`anthonymaley/homebrew-musictui` Formula/musictui.rb — tarball URL, sha256, version test string), push, and live-test `brew upgrade musictui`.

- [ ] **Step 3: Update CONTEXT.md and the comparison page**

CONTEXT.md → Key Decisions → Radio: promote from "mechanism probed" to "shipped in X.Y.0", and record which station classes were live-verified.

`site/compare.html`: radio moves out of "Where MusicTUI is behind". MusicTUI becomes the only **native** Music.app TUI with radio — the Cider-dependent `apple-music-tui` needs a second app to do it.

---

## Open questions carried from the spec

- **Why BBC Radio 1 plays but isn't in the catalog API.** Unknown. Every design decision routes around it rather than explaining it — that's why `resolve` returning nil is normal and why favorites store their own url+name.
- **Transport on *live* stations** — untested. Track-based transport works (`skip`/`pause`/`play` verified). There may be nothing to skip to on a livestream; find out during Task 12 and record the answer.
- **Mid-station speaker switching** — untested. Route *survival* is verified; changing route mid-station is not.
- **Seeding Favorites with the 6 live stations on first run** — worth considering if the empty-first-run state reads badly. Deferred, not decided.
