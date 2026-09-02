import XCTest
import ArgumentParser
@testable import music

final class WatchContainerTests: XCTestCase {

    func testSubcommandIsHiddenFromHelp() {
        XCTAssertFalse(WatchContainer.configuration.shouldDisplay,
                       "internal plumbing must not appear in normal help")
    }

    func testCommandNameIsTheInternalForm() {
        XCTAssertEqual(WatchContainer.configuration.commandName, "__watch-container")
    }

    /// One read per poll, carrying all three signals, each independently
    /// try-guarded so one failing read does not blank the others.
    func testObservationScriptReadsAllThreeSignalsWithGuards() {
        let s = albumWatcherObservationScript()
        XCTAssertTrue(s.contains("player state"))
        XCTAssertTrue(s.contains("current playlist"))
        XCTAssertTrue(s.contains("persistent ID of current track"))
        XCTAssertTrue(s.contains("ASCII character 31"))
        // §18.5: counting "try" double-counts every guard, because "end try"
        // itself contains the substring "try" — three guards emit six "try"
        // substring occurrences, not three, so the old `>= 3` threshold
        // survived deleting an entire guard (two guards is still four).
        // "end try" occurs exactly once per guard, so this actually pins
        // the guard count.
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "end try").count - 1, 3,
                                    "each read needs its own try guard")
    }

    func testParseAllThreeFieldsPresent() {
        let raw = "playing\u{1F}__album__ U — Moon Safari\u{1F}ID2"
        let o = parseWatcherObservation(raw,
                                        containerName: "__album__ U — Moon Safari",
                                        ids: ["ID1", "ID2"])
        XCTAssertEqual(o.playerState, "playing")
        XCTAssertEqual(o.currentPlaylist, "__album__ U — Moon Safari")
        XCTAssertEqual(o.currentTrackID, "ID2")
    }

    /// Empty field means the read threw. It must become nil, not "".
    func testEmptyFieldsBecomeNilNotEmptyString() {
        let raw = "playing\u{1F}\u{1F}"
        let o = parseWatcherObservation(raw, containerName: "C", ids: [])
        XCTAssertEqual(o.playerState, "playing")
        XCTAssertNil(o.currentPlaylist)
        XCTAssertNil(o.currentTrackID)
    }

    func testMalformedPayloadIsAllNilAndThereforeSpares() {
        let o = parseWatcherObservation("garbage", containerName: "C", ids: ["A"])
        XCTAssertNil(o.playerState)
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// The watcher deletes exactly one playlist and can never reach a track.
    func testDeleteScriptNamesOnePlaylistAndNoTrack() {
        let s = playlistDeleteScript(name: "__album__ U — Moon Safari")
        XCTAssertTrue(s.contains("every user playlist whose name is"))
        XCTAssertFalse(s.contains("track"))
        XCTAssertFalse(s.contains("song"))
        XCTAssertFalse(s.contains("starts with"), "must never be prefix wide")
    }

    // MARK: - Finding 1: empty trackIDs must not invert the fail-safe

    private let containerName = "__album__ U — Moon Safari"

    /// A container that IS currently playing, with a readable track ID, but
    /// the caller has no identity ground truth at all. Before the fix this
    /// resolved to `.collect` (deletes live playback) because an empty
    /// `containerTrackIDs.contains(id)` answers false for every ID. After the
    /// fix, `resolvedWatcherObservation` nils the track ID so the decision
    /// falls to context comparison, which correctly spares.
    private func assertContextOnlySparesPlayingContainer(trackIDs: Set<String>, line: UInt = #line) {
        let raw = "playing\u{1F}\(containerName)\u{1F}SOME-TRACK-ID"
        let o = resolvedWatcherObservation(raw, containerName: containerName, trackIDs: trackIDs)
        XCTAssertNil(o.currentTrackID, "identity must be absent, not an empty-set answer", line: line)
        XCTAssertEqual(albumWatcherDecision(o), .spare,
                       "must not collect a currently playing container with no identity ground truth",
                       line: line)
    }

    func testEmptyIdsOptionIsContextOnlyAndSparesPlayingContainer() {
        let trackIDs = resolveTrackIDs(idsOption: "", manifestPath: nil)
        XCTAssertTrue(trackIDs.isEmpty)
        assertContextOnlySparesPlayingContainer(trackIDs: trackIDs)
    }

    func testCommaOnlyIdsOptionIsContextOnlyAndSparesPlayingContainer() {
        let trackIDs = resolveTrackIDs(idsOption: ",", manifestPath: nil)
        XCTAssertTrue(trackIDs.isEmpty)
        assertContextOnlySparesPlayingContainer(trackIDs: trackIDs)
    }

    func testMissingManifestPathIsContextOnlyAndSparesPlayingContainer() {
        let trackIDs = resolveTrackIDs(idsOption: nil, manifestPath: "/nonexistent/nope-\(UUID().uuidString).ids")
        XCTAssertTrue(trackIDs.isEmpty)
        assertContextOnlySparesPlayingContainer(trackIDs: trackIDs)
    }

    func testNeitherOptionSuppliedIsContextOnlyAndSparesPlayingContainer() {
        let trackIDs = resolveTrackIDs(idsOption: nil, manifestPath: nil)
        XCTAssertTrue(trackIDs.isEmpty)
        assertContextOnlySparesPlayingContainer(trackIDs: trackIDs)
    }

    /// The normal, identity-available path still collects correctly: a
    /// readable track ID absent from a NON-empty `containerTrackIDs` means
    /// playback truly left the container.
    func testNonEmptyIdsStillCollectsWhenTrackIsGenuinelyNotTheContainers() {
        let raw = "playing\u{1F}Some Other Playlist\u{1F}NOT-OURS"
        let o = resolvedWatcherObservation(raw, containerName: containerName, trackIDs: ["ID1", "ID2"])
        XCTAssertEqual(o.currentTrackID, "NOT-OURS")
        XCTAssertEqual(albumWatcherDecision(o), .collect)
    }

    // MARK: - Finding 2: lifecycle exit paths, injected clock/runner

    /// Shares mutable state between the `now` and `sleep` closures injected
    /// into the lifecycle, so tests advance a virtual clock instantly
    /// instead of waiting out real timeouts.
    private final class FakeClock {
        private(set) var current = Date(timeIntervalSince1970: 0)
        func now() -> Date { current }
        func sleep(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
    }

    /// Records every script string the lifecycle sends, and answers a
    /// canned response per call — repeating the last response once the
    /// script runs out, so an open-ended loop (e.g. sparing to max lifetime)
    /// doesn't need one entry per iteration.
    private final class ScriptCallRecorder {
        private(set) var calls: [String] = []
        private let responses: [String?]
        private var index = 0
        init(_ responses: [String?]) { self.responses = responses }
        func run(_ script: String) -> String? {
            calls.append(script)
            defer { if index < responses.count - 1 { index += 1 } }
            return responses.isEmpty ? nil : responses[index]
        }
    }

    func testArmTimeoutExitsWithoutDeletingAndRemovesManifest() throws {
        let recorder = ScriptCallRecorder([nil]) // never observed as current
        let clock = FakeClock()
        let manifestPath = NSTemporaryDirectory() + "watch-test-\(UUID().uuidString).ids"
        try "A\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let deleted = executeAlbumWatcher(name: containerName, trackIDs: ["A"],
                                          manifestPath: manifestPath, run: recorder.run,
                                          isRunning: { true },
                                          now: clock.now, sleep: clock.sleep,
                                          armTimeout: 5, pollInterval: 1, maxLifetime: 60)

        XCTAssertFalse(deleted)
        XCTAssertFalse(recorder.calls.contains(where: { $0.contains("delete") }),
                       "arm timeout must never delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath),
                       "manifest must be removed even on arm timeout")
    }

    func testArmedThenCollectDeletesExactlyOneContainerAndRemovesManifest() throws {
        let armRaw = "playing\u{1F}\(containerName)\u{1F}TRACKX"
        let leftRaw = "playing\u{1F}Somewhere Else\u{1F}TRACKY"
        let recorder = ScriptCallRecorder([armRaw, leftRaw])
        let clock = FakeClock()
        let manifestPath = NSTemporaryDirectory() + "watch-test-\(UUID().uuidString).ids"
        try "TRACKX\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let deleted = executeAlbumWatcher(name: containerName, trackIDs: ["TRACKX"],
                                          manifestPath: manifestPath, run: recorder.run,
                                          isRunning: { true },
                                          now: clock.now, sleep: clock.sleep,
                                          armTimeout: 30, pollInterval: 15, maxLifetime: 3600)

        XCTAssertTrue(deleted)
        XCTAssertEqual(recorder.calls.last, playlistDeleteScript(name: containerName),
                       "must name exactly the one container")
        XCTAssertEqual(recorder.calls.filter { $0.contains("delete") }.count, 1,
                       "must delete exactly once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath),
                       "manifest must be removed after a successful collect")
    }

    func testMaxLifetimeExpiresWhileSparingExitsWithoutDeletingAndRemovesManifest() throws {
        let armRaw = "playing\u{1F}\(containerName)\u{1F}TRACKX"
        let spareRaw = "paused\u{1F}\(containerName)\u{1F}TRACKX"
        let recorder = ScriptCallRecorder([armRaw, spareRaw]) // repeats spareRaw forever
        let clock = FakeClock()
        let manifestPath = NSTemporaryDirectory() + "watch-test-\(UUID().uuidString).ids"
        try "TRACKX\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let deleted = executeAlbumWatcher(name: containerName, trackIDs: ["TRACKX"],
                                          manifestPath: manifestPath, run: recorder.run,
                                          isRunning: { true },
                                          now: clock.now, sleep: clock.sleep,
                                          armTimeout: 5, pollInterval: 1, maxLifetime: 5)

        XCTAssertFalse(deleted)
        XCTAssertFalse(recorder.calls.contains(where: { $0.contains("delete") }),
                       "must never delete a container that may still be paused and current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath),
                       "manifest must be removed even on the max lifetime timeout")
    }

    func testUnreadablePollContinuesRatherThanDeciding() {
        let armRaw = "playing\u{1F}\(containerName)\u{1F}TRACKX"
        let leftRaw = "playing\u{1F}Somewhere Else\u{1F}TRACKY"
        // Call 1 arms. Call 2 is an unreadable poll (nil) — must NOT be
        // treated as a decision. Call 3 is the real decision.
        let recorder = ScriptCallRecorder([armRaw, nil, leftRaw])
        let clock = FakeClock()

        let deleted = albumWatcherLifecycle(name: containerName, trackIDs: ["TRACKX"],
                                            run: recorder.run, isRunning: { true },
                                            now: clock.now, sleep: clock.sleep,
                                            armTimeout: 30, pollInterval: 15, maxLifetime: 3600)

        XCTAssertTrue(deleted, "must reach the real decision past the unreadable poll")
        XCTAssertEqual(recorder.calls.count, 3,
                       "must consume the nil poll via continue, not stop or misinterpret it")
    }

    // MARK: - §16.3: the watcher must never relaunch Music

    /// `tell application "Music"` sends an Apple Event that launches a quit
    /// app. The observation script must never reference `application "Music"`
    /// at all — it has to ask System Events instead.
    func testMusicIsRunningScriptNeverReferencesApplicationMusic() {
        let s = musicIsRunningScript()
        XCTAssertFalse(s.contains("application \"Music\""),
                       "must never tell application \"Music\" — that launches a quit app")
        XCTAssertTrue(s.contains("System Events"))
        XCTAssertTrue(s.contains("exists process"))
    }

    /// If Music was never observed running, the lifecycle must exit
    /// immediately without ever reaching an observation (which would itself
    /// risk a `tell application "Music"` Apple Event).
    /// Producer addendum 2026-09-01: the negative control. With the probe
    /// returning false throughout, the watcher must invoke the script runner
    /// ZERO times — neither the observation script nor the delete script is
    /// ever issued — remove the manifest, and exit without deleting.
    /// Asserting `recorder.calls.isEmpty` (not merely `deleted == false`) is
    /// the property that actually proves "never spoke to Music at all":
    /// "it didn't delete" is satisfiable by many wrong implementations that
    /// still leak an observation Apple Event.
    func testMusicNotRunningExitsWithoutInvokingTheRunnerAndRemovesManifest() throws {
        let recorder = ScriptCallRecorder([nil])
        let clock = FakeClock()
        let manifestPath = NSTemporaryDirectory() + "watch-test-\(UUID().uuidString).ids"
        try "A\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let deleted = executeAlbumWatcher(name: containerName, trackIDs: ["A"],
                                          manifestPath: manifestPath, run: recorder.run,
                                          isRunning: { false },
                                          now: clock.now, sleep: clock.sleep,
                                          armTimeout: 30, pollInterval: 15, maxLifetime: 3600)

        XCTAssertFalse(deleted)
        XCTAssertTrue(recorder.calls.isEmpty,
                      "must never invoke the script runner at all once Music is observed not running "
                      + "— neither the observation script nor the delete script")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath),
                       "manifest must still be removed when Music was never observed running")
    }

    /// The paired positive control. Without this, a broken probe that always
    /// returns false would pass the negative test above while silently
    /// disabling the whole watcher. With the probe returning true throughout,
    /// the watcher proceeds normally and the runner IS invoked.
    func testMusicRunningProceedsNormallyAndInvokesTheRunner() {
        let armRaw = "playing\u{1F}\(containerName)\u{1F}TRACKX"
        let leftRaw = "playing\u{1F}Somewhere Else\u{1F}TRACKY"
        let recorder = ScriptCallRecorder([armRaw, leftRaw])
        let clock = FakeClock()

        let deleted = albumWatcherLifecycle(name: containerName, trackIDs: ["TRACKX"],
                                            run: recorder.run, isRunning: { true },
                                            now: clock.now, sleep: clock.sleep,
                                            armTimeout: 30, pollInterval: 15, maxLifetime: 3600)

        XCTAssertTrue(deleted)
        XCTAssertFalse(recorder.calls.isEmpty,
                       "with Music running throughout, the runner must be invoked")
    }

    /// Music quits WHILE the watcher is armed and watching (the realistic
    /// case — arming happens promptly after `play playlist` succeeds, so
    /// Music is virtually always running at armDeadline; a user quitting
    /// mid-album is the scenario this exists for). The watcher must exit
    /// without deleting and without touching the playlist, leaving the
    /// orphan for §16.1's next-invocation sweep or explicit cleanup.
    func testMusicQuitsDuringWatchExitsWithoutDeleting() {
        let armRaw = "playing\u{1F}\(containerName)\u{1F}TRACKX"
        let recorder = ScriptCallRecorder([armRaw])
        let clock = FakeClock()
        var runningCalls = 0
        func isRunning() -> Bool {
            runningCalls += 1
            return runningCalls <= 2 // running through arming, quit before the first watch poll
        }

        let manifestPath = NSTemporaryDirectory() + "watch-test-\(UUID().uuidString).ids"
        try? "TRACKX\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let deleted = executeAlbumWatcher(name: containerName, trackIDs: ["TRACKX"],
                                          manifestPath: manifestPath, run: recorder.run,
                                          isRunning: isRunning,
                                          now: clock.now, sleep: clock.sleep,
                                          armTimeout: 30, pollInterval: 15, maxLifetime: 3600)

        XCTAssertFalse(deleted)
        XCTAssertFalse(recorder.calls.contains(where: { $0.contains("delete") }),
                       "must never delete once Music is observed not running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath),
                       "manifest must still be removed when the watcher exits because Music quit")
    }

    // MARK: - §16.4: the watcher validates its own ownership

    func testOwnedAlbumContainerNameIsAccepted() {
        let name = albumContainerName(title: "Moon Safari", uuid: UUID().uuidString)
        XCTAssertTrue(isOwnedAlbumContainerName(name))
    }

    /// The exact attack named in §16.4: an arbitrary user playlist name must
    /// never validate, or `music __watch-container "Working Vibes"` would be
    /// able to delete it once it became current and playback left it.
    func testArbitraryPlaylistNameIsRejected() {
        XCTAssertFalse(isOwnedAlbumContainerName("Working Vibes"))
    }

    func testPrefixSimilarNameIsRejected() {
        XCTAssertFalse(isOwnedAlbumContainerName("__album__not the real separator"))
        XCTAssertFalse(isOwnedAlbumContainerName("__albums__ \(UUID().uuidString) — Title"))
    }

    func testNonUUIDIdentifierIsRejected() {
        XCTAssertFalse(isOwnedAlbumContainerName("__album__ not-a-uuid — Title"))
    }

    func testEmptyTitleIsRejected() {
        XCTAssertFalse(isOwnedAlbumContainerName("__album__ \(UUID().uuidString) — "))
    }

    func testOtherOwnedPrefixIsNotAnOwnedAlbumName() {
        // __discover__ containers are a different owner; the watcher must
        // never act on one even though it shares the uuid-carrying shape.
        XCTAssertFalse(isOwnedAlbumContainerName("__discover__ \(UUID().uuidString) — Title"))
    }

    // MARK: - §18.1: the manifest path must be validated, not just the name

    func testManifestPathMatchingTheDerivedPathIsValid() {
        let uuid = UUID().uuidString
        let name = albumContainerName(title: "Moon Safari", uuid: uuid)
        guard let expected = albumManifestPath(uuid: uuid) else {
            return XCTFail("a freshly generated UUID must always produce a manifest path")
        }
        XCTAssertTrue(manifestPathIsValidForOwnedName(expected, name: name))
    }

    /// The exact attack §18.1 exists to close: `executeAlbumWatcher` removes
    /// whatever `--manifest` path it is given on every exit path, so an
    /// owned NAME plus an ARBITRARY `--manifest` argument must never
    /// validate — `music __watch-container "<owned name>" --manifest
    /// <any path>` would otherwise delete that file, unattended, with all
    /// three streams at /dev/null.
    func testArbitraryManifestPathIsRejectedForAnOwnedName() {
        let uuid = UUID().uuidString
        let name = albumContainerName(title: "Moon Safari", uuid: uuid)
        XCTAssertFalse(manifestPathIsValidForOwnedName("/etc/hosts", name: name))
        XCTAssertFalse(manifestPathIsValidForOwnedName(NSTemporaryDirectory() + "not-mine.ids", name: name))
    }

    /// A real, well-formed manifest path for a DIFFERENT container's uuid
    /// must not validate against this name either — "looks like a manifest
    /// path" is not the bar, "is THIS container's manifest path" is.
    func testAnotherContainersManifestPathIsRejected() {
        let uuid = UUID().uuidString
        let name = albumContainerName(title: "Moon Safari", uuid: uuid)
        guard let otherPath = albumManifestPath(uuid: UUID().uuidString) else {
            return XCTFail("a freshly generated UUID must always produce a manifest path")
        }
        XCTAssertFalse(manifestPathIsValidForOwnedName(otherPath, name: name))
    }

    /// Fails closed for a name that was never owned in the first place —
    /// there is no uuid to derive an expected path from.
    func testManifestPathValidationFailsClosedForAnUnownedName() {
        XCTAssertFalse(manifestPathIsValidForOwnedName(NSTemporaryDirectory() + "anything.ids",
                                                        name: "Working Vibes"))
    }

    // MARK: - §18.2: the running probe distinguishes failure from absence

    func testProbeClassifiesTrueAsRunning() {
        XCTAssertEqual(classifyMusicRunningProbe("true"), .running)
        XCTAssertEqual(classifyMusicRunningProbe(" true \n"), .running)
    }

    func testProbeClassifiesFalseAsNotRunning() {
        XCTAssertEqual(classifyMusicRunningProbe("false"), .notRunning)
    }

    /// `nil` means the probe itself threw (`syncRun` rethrew and `try?`
    /// swallowed it) — distinct from a well-formed "false" response. Before
    /// §18.2 both collapsed into the same `false`, with nothing anywhere to
    /// tell a failing probe apart from Music genuinely not running.
    func testProbeClassifiesAThrowAsProbeFailedNotNotRunning() {
        XCTAssertEqual(classifyMusicRunningProbe(nil), .probeFailed)
    }

    func testProbeClassifiesGarbageAsProbeFailed() {
        XCTAssertEqual(classifyMusicRunningProbe("garbage"), .probeFailed)
        XCTAssertEqual(classifyMusicRunningProbe(""), .probeFailed)
    }
}
