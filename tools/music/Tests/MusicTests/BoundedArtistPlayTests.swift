import XCTest
@testable import music

/// `music play --artist "X"` alone, which used to resume whatever was loaded:
/// no branch handled the option, so it fell through to the bare-`play` resume
/// and said nothing (found 2026-09-22). Ruling 12.2: an artist expands to that
/// artist's SONGS.
final class BoundedArtistPlayTests: XCTestCase {

    private func tracks(_ indices: [Int]) -> [TrackListEntry] {
        indices.map { TrackListEntry(index: $0, name: "T\($0)", artist: "Air", isCurrent: false, album: "Moon Safari") }
    }

    /// Records the scripts and answers the two reads the container build makes.
    private final class Recorder {
        var scripts: [String] = []
        func run(_ s: String) -> String {
            scripts.append(s)
            if s.contains("set ids to persistent ID") { return "A\u{1F}B" }
            if s.contains("count of tracks") { return "2" }
            return ""
        }
    }

    /// The container carries the artist's own library rows, in the order the
    /// resolver gave them, and nothing writes shuffle.
    func testPlaysTheArtistsTracksBounded() {
        let rec = Recorder()
        var launched: [String]?
        let out = playBoundedArtist(name: "Air", tracks: tracks([4, 9]), uuid: "U",
                                    run: { rec.run($0) },
                                    launch: { _, args in launched = args; return true })
        let scripts = rec.scripts
        XCTAssertEqual(out, .playing)
        XCTAssertNotNil(launched, "the cleanup watcher must be spawned")
        XCTAssertTrue(scripts.contains { $0.contains("play playlist") })
        XCTAssertFalse(scripts.contains { $0.contains("shuffle enabled") },
                       "an artist play must not write Music.app's shuffle mode")
        let build = scripts.first { $0.contains("duplicate") || $0.contains("make new playlist") } ?? ""
        XCTAssertTrue(build.contains("4"), "track 4 must be in the container: \(build)")
        XCTAssertTrue(build.contains("9"), "track 9 must be in the container: \(build)")
    }

    /// The container is an `__album__` one, so the existing stale sweep and the
    /// one-shot watcher collect it. The sweep runs BEFORE this play's own build.
    func testUsesAnAlbumContainerAndSweepsFirst() {
        let rec = Recorder()
        _ = playBoundedArtist(name: "Air", tracks: tracks([1]), uuid: "U",
                              run: { rec.run($0) }, launch: { _, _ in true })
        let scripts = rec.scripts
        XCTAssertTrue(scripts.first?.contains(albumPlaylistPrefix) ?? false,
                      "the stale sweep must run first: \(scripts.first ?? "none")")
        XCTAssertTrue(scripts.contains { $0.contains(albumContainerName(title: "Air", uuid: "U")) })
    }

    func testEveryFailureStageSaysWhatWasLeftBehind() {
        XCTAssertNil(artistOutcomeMessage(.playing, name: "Air"))
        XCTAssertEqual(artistOutcomeMessage(.buildFailed(containerRemoved: true), name: "Air"),
                       "Couldn't build the temporary playlist for 'Air'. The container was removed.")
        for outcome in [ContainerPlayOutcome.buildFailed(containerRemoved: false),
                        .playFailed(containerRemoved: false),
                        .watcherFailed(containerRemoved: false)] {
            let message = artistOutcomeMessage(outcome, name: "Air") ?? ""
            XCTAssertTrue(message.contains("music playlist cleanup"),
                          "a leftover container must point at the cleanup verb: \(message)")
        }
        XCTAssertTrue(artistOutcomeMessage(.playFailed(containerRemoved: true), name: "Air")!
            .contains("start bounded playback"))
        XCTAssertTrue(artistOutcomeMessage(.watcherFailed(containerRemoved: true), name: "Air")!
            .contains("cleanup watcher"))
    }
}

/// `--artist` beside loose words: refused rather than silently ignored
/// (Anthony, 2026-09-22, on Codex's finding).
final class ArtistWithLooseWordsTests: XCTestCase {

    private func refusal(_ args: [String], artist: String? = "Air",
                         song: String? = nil, album: String? = nil, playlist: String? = nil) -> String? {
        artistWithLooseWordsRefusal(artist: artist, args: args, song: song, album: album, playlist: playlist)
    }

    /// Both orders on the command line parse to the same thing, so both refuse.
    func testLooseWordsBesideArtistRefuse() {
        for args in [["Teardrop"], ["Teardrop", "Massive", "Attack"], ["kitchen"], ["kitchen", "40"], ["shuffle"]] {
            let message = refusal(args)
            XCTAssertNotNil(message, "\(args)")
            XCTAssertTrue(message!.contains("music play --song \"Title\" --artist \"Name\""))
            XCTAssertTrue(message!.contains("music play \"Title\" \"Name\""))
            XCTAssertTrue(message!.contains("not supported yet"), "speakers are a feature, not a mistake")
        }
    }

    /// The spellings that work, and every invocation without `--artist`.
    func testTheWorkingSpellingsProceed() {
        XCTAssertNil(refusal([]), "--artist alone plays the artist")
        XCTAssertNil(refusal([], song: "Teardrop"))
        XCTAssertNil(refusal(["Teardrop", "Massive Attack"], artist: nil), "two quoted words, no flag")
        XCTAssertNil(refusal(["Teardrop"], song: "Teardrop"), "--song decides; it narrows with --artist")
        XCTAssertNil(refusal(["Moon Safari"], album: "Moon Safari"))
        XCTAssertNil(refusal(["Top 25"], playlist: "Top 25"))
        XCTAssertNil(refusal(["3"], artist: nil))
    }
}
