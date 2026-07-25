# Contributing

Contributions are welcome. Read [`ARCHITECTURE.md`](ARCHITECTURE.md) first; it explains
the two-transport design and lists the parts of the codebase that are known to be
rough.

## Build and test

```bash
cd tools/music
swift build
swift test
```

473 tests, about two seconds. They need no configuration, no Apple Developer account,
and no running Music.app. CI runs the same two commands on every push.

To install your build over the released one:

```bash
scripts/install.sh
```

## The one rule that matters

**A green test suite does not mean a playback change works.**

Most of this project's real bugs have lived at the boundary to Music.app, where our
logic was correct and the platform did something undocumented. Twice a passing unit
test actively concealed a shipped bug, because the test encoded the wrong assumption.
Both cases are written up in [`docs/platform-notes.md`](docs/platform-notes.md).

So if your change touches playback, AirPlay routing, the equalizer, or artwork, please
verify it against a real Music.app and say so in the pull request. "Tests pass" is
necessary and not sufficient. If you cannot test it live, say that instead; an honest
gap is more useful than an implied verification.

## Useful to know

- **Docs travel with the code.** If you change TUI keys, AirPlay behaviour, or artwork
  handling, update the README, `skills/music/SKILL.md`, and `docs/guide.md` in the same
  commit.
- **New platform findings go in `docs/platform-notes.md`,** with the date you observed
  them and the macOS version. Undated claims decay silently.
- **Prefer batching Apple Events.** The first round-trip to Music.app costs roughly
  90 ms; each extra property in the same script costs about 7 ms. One script reading
  eight things beats eight scripts.
- **AppleScript strings live inline at each call site** today. If you find yourself
  adding several, that is a sign the shared query layer described in ARCHITECTURE.md
  is overdue rather than a reason to add a sixth variant.

## Reporting bugs

Include your macOS version, whether the track was in your library or streamed from the
catalogue, and the output of `music --version`. If it involves playback, `music now -v`
output helps. The library-versus-catalogue distinction matters more than it sounds like
it should; see the platform notes for why.
