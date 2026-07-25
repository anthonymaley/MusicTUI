# Architecture

How MusicTUI is put together, and why several obvious alternatives were rejected.
Written for anyone reading the source for the first time, or considering a
contribution.

Measurements in this document were taken on 2026-07-25 against the tree at that
commit. They will drift.

## The shape of it

```
tools/music/Sources/            73 files, 13,396 lines
├── Music.swift                 CLI entry point, subcommand registry, --version
├── StatusReporter.swift        shell status-line output
├── Commands/     19 files      3,290 lines   one type per CLI subcommand
├── TUI/          36 files      7,823 lines   the terminal UI
│   └── Shell/                                tabbed shell + scenes
├── Backends/     11 files      1,602 lines   the two transports
├── Models/        2 files        235 lines   shared value types
└── Auth/          3 files        347 lines   MusicKit JWT + user token

tools/music/Tests/              4,789 lines, 473 tests
```

Everything is one Swift package with a single external dependency,
[swift-argument-parser](https://github.com/apple/swift-argument-parser). There is no
framework, no code generation, and no runtime requirement for the user beyond macOS 14.

## Two transports, and how the choice gets made

All communication with Apple Music goes through one of two backends in `Backends/`:

**`AppleScriptBackend`** spawns `/usr/bin/osascript` and pipes AppleScript source to
it. This is the only route to *local* control: playback transport, AirPlay device
routing and per-device volume, the equalizer, and reading what is currently playing.
There is no API for any of that.

**`RESTAPIBackend`** talks to the Apple Music API over HTTPS. This is the only route
to *catalog* data: search across the full catalogue, library metadata at scale,
playlist management, artwork URLs, and radio station metadata. It needs a developer
token, which is why those features are gated behind an Apple Developer account.

The split is not a preference. Each side can do things the other cannot, so most
interesting operations use both: search the catalogue over REST, then play the result
over AppleScript.

`AppleScriptBackend` runs every script under a watchdog that terminates a hung
`osascript` rather than letting a dying AirPlay device wedge the UI.

## The TUI

`TUI/Shell/` is a tabbed shell. Each tab is a *scene* conforming to the `Scene`
protocol in `TUI/Shell/Scene.swift`:

```swift
protocol Scene: AnyObject {
    var id: SceneID { get }
    var tabTitle: String { get }
    var capturesAllInput: Bool { get }
    func tick(snapshot: NowPlayingSnapshot) -> Bool
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String
    func handle(_ key: KeyPress) -> SceneAction
    func artPlacementsInvalidated()
}
```

A scene draws only into the body region it is handed. It never touches the tab bar,
the chrome, or the now-playing footer. It returns a `SceneAction` (`redraw`, `push`,
`pop`, `quit`) rather than mutating shell state directly.

`PlaybackPoller` runs on its own thread and publishes immutable snapshots. Scenes
never block the input loop on an `osascript` round-trip; actions go onto a queue.
Keys are read from a single UI thread, which is what makes the one-byte pushback in
the escape-sequence parser safe without a lock.

Cover art degrades through a ladder: kitty graphics protocol for true pixels, then
`chafa` half-blocks, then monochrome blocks, then a generated gradient. Art is
decoration, so nothing in that chain surfaces an error to the user.

## What actually binds this to Apple

Beyond `Foundation`, `Darwin`, and the argument parser, only **four files** import an
Apple framework:

| File | Framework | Purpose |
|---|---|---|
| `Auth/JWTGenerator.swift` | CryptoKit | ES256 signing for the developer token |
| `TUI/KittyGraphics.swift` | CoreGraphics, ImageIO | JPEG to PNG for the kitty protocol |
| `TUI/NowPlayingTUI.swift` | CoreGraphics, ImageIO | same, plus termios |
| `Backends/SpeakerIPResolver.swift` | Network | speaker address resolution |

There is no AppKit, no ScriptingBridge, no `NSAppleScript`, and no Accessibility API
use anywhere in the tree. Every integration point is either a subprocess or an HTTPS
call. External binaries invoked: `osascript`, `open`, `netstat`, `chafa`, and `python`
for the local auth callback server.

## Testing

473 tests, run in CI on every push. They cover pure logic: parsers, the AirPlay heal
ladder, queue state transitions, layout maths, key disambiguation, artwork cache
decisions. Backends are injected behind seams so no test needs Music.app running.

The tests verify with an isolated `HOME`, so they do not depend on local
configuration.

**What the tests cannot cover** is the part that breaks most often. A green suite has
repeatedly coexisted with a completely broken feature, because the failure lived at
the boundary to Music.app rather than in our logic. See
[`docs/platform-notes.md`](docs/platform-notes.md) for two cases where a passing test
actively concealed a shipped bug. Anything touching playback gets verified against a
real Music.app before release.

## Rejected alternatives

**MusicKit.** The obvious choice, and it does not work for a distributable CLI. Using
it does not remove the Apple Developer account requirement, and the entitlement and
signing model does not survive the way a Homebrew-installed binary is built and
rebuilt. Investigated and abandoned.

**MediaRemote and other private frameworks.** Would provide the now-playing data that
AppleScript loses on non-library tracks. Private, unstable across releases, and
unshippable. Rejected.

**Driving the web player in a browser.** Rejected: no AirPlay control, no equalizer,
enormous dependency, and fragile against any markup change.

**Rewriting in Rust or Go.** Considered seriously and rejected on measurement.
Roughly 100% of observable latency sits beyond a subprocess boundary: the binary's own
startup is unmeasurable at ~0 ms, while a single Apple Event round-trip to Music.app
costs ~90 ms and cannot be reached by any language. A rewrite's theoretical ceiling is
the ~70 ms of `osascript` startup and compilation, which is also recoverable from
Swift. Separately, the codebase's list and cursor plumbing is 1 to 5% of each scene file,
so a TUI framework would replace about 1% of the source while the 100-plus AppleScript
call sites would port across verbatim as string literals. The numbers are in
[`docs/platform-notes.md`](docs/platform-notes.md).

**Keychain for credentials.** Rejected in favour of `0600` files under
`~/.config/music/`, matching `aws` and `gh`. Homebrew builds are ad-hoc signed, so
Keychain ACLs do not survive a rebuild, and the tool needs to work over SSH with a
locked login keychain.

## Known rough edges

Stated plainly, because they are the first things a contributor will notice.

- **`TUI/Shell/LibraryScene.swift` is 1,068 lines** with 34 functions. It grew past
  the point where it should have been split.
- **The AppleScript boundary is stringly typed.** Around 106 `runMusic(` call sites
  build AppleScript as string literals, and roughly 53 sites hand-parse the delimited
  text that comes back. There is no shared query layer, so batching Apple Events is a
  manual optimisation at each site rather than the default. Given that the first Apple
  Event costs ~90 ms and each additional one ~7 ms, this is a performance issue as
  much as a tidiness one.
- **State crossing that boundary is often `[String: Any]`** rather than typed values,
  at around 99 sites. Extracting a neutral domain model is the intended fix and has
  not been done.
- **CLI playback is not resident.** `music play --album` exits immediately, so
  album-scoped queueing only works inside the TUI, which stays alive to drive it.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
