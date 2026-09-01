// tools/music/Tests/MusicTests/ContinuationSourceTests.swift
//
// The end-of-queue continuation menu must keep two things apart that are both
// plain Strings and look interchangeable:
//
//   - the ADDRESSABLE source, what `play track N of playlist X` consumes
//   - the HUMAN-FACING label, what the user is shown and promised
//
// An album/artist queue plays FROM "Library" but is "Moon Safari" to the user.
// Conflating them shipped a menu that offered "Shuffle Library" and, on press,
// shuffled all 14k library tracks instead of the album that had just ended.
//
// Routing is decided by the SOURCE's addressability, never by the presence of
// a label: a label is presentation metadata and must not steer playback.
import XCTest
@testable import music

final class ContinuationSourceTests: XCTestCase {

    private func albumQueue() -> AppQueue {
        AppQueue(
            playlistName: "Library",
            tracks: [
                TrackListEntry(index: 41, name: "La Femme d'Argent", artist: "Air", isCurrent: false),
                TrackListEntry(index: 42, name: "Sexy Boy", artist: "Air", isCurrent: false),
                TrackListEntry(index: 43, name: "All I Need", artist: "Air", isCurrent: true),
            ],
            currentIndex: 3,
            displayName: "Moon Safari")
    }

    private func playlistQueue() -> AppQueue {
        AppQueue(
            playlistName: "Friday Mix",
            tracks: [
                TrackListEntry(index: 1, name: "A", artist: "X", isCurrent: true),
                TrackListEntry(index: 2, name: "B", artist: "Y", isCurrent: false),
            ],
            currentIndex: 1)
    }

    // MARK: - Classification is by source addressability, not by label

    func testLibrarySourcedQueueIsBounded() {
        guard case .bounded = continuationSource(for: albumQueue()) else {
            return XCTFail("a Library-sourced queue is not addressable and must be bounded")
        }
    }

    func testMusicSourcedQueueIsBounded() {
        // `isLibraryContextName` accepts both "Library" and "Music".
        let q = AppQueue(
            playlistName: "Music",
            tracks: [TrackListEntry(index: 7, name: "A", artist: "X", isCurrent: true)],
            currentIndex: 1,
            displayName: "Some Album")
        guard case .bounded = continuationSource(for: q) else {
            return XCTFail("a Music-sourced queue must be bounded too")
        }
    }

    func testRealPlaylistQueueStaysPlaylistBacked() {
        guard case .playlist(let name) = continuationSource(for: playlistQueue()) else {
            return XCTFail("a real playlist queue must stay playlist-backed")
        }
        XCTAssertEqual(name, "Friday Mix")
    }

    // MARK: - The label must never be the addressable source

    func testAlbumQueueLabelsWithTheAlbumNotTheSourcePlaylist() {
        let source = continuationSource(for: albumQueue())
        XCTAssertEqual(source.label, "Moon Safari")
        XCTAssertNotEqual(source.label, "Library")
    }

    func testRealPlaylistQueueLabelsWithItsOwnName() {
        XCTAssertEqual(continuationSource(for: playlistQueue()).label, "Friday Mix")
    }

    func testBoundedQueueCarriesLabelAndSourceAsSeparateFields() {
        // Separation, not deletion: playback still needs "Library" to issue
        // `play track N of playlist "Library"`, but it can never be shown.
        guard case .bounded(let label, let source, let tracks) = continuationSource(for: albumQueue()) else {
            return XCTFail("expected a bounded source")
        }
        XCTAssertEqual(label, "Moon Safari")
        XCTAssertEqual(source, "Library")
        XCTAssertEqual(tracks.map(\.name), ["La Femme d'Argent", "Sexy Boy", "All I Need"])
    }

    // MARK: - Shuffle reshuffles ONLY those same tracks, never a fetch

    func testShuffleOfBoundedQueueIsAPermutationOfTheSameTracks() {
        let shuffled = continuationShuffleTracks(continuationSource(for: albumQueue()))
        XCTAssertEqual(shuffled?.count, 3)
        XCTAssertEqual(
            Set(shuffled?.map(\.name) ?? []),
            ["La Femme d'Argent", "Sexy Boy", "All I Need"],
            "shuffle must reuse the queue's own tracks, never fetch a playlist")
    }

    func testShuffleOfBoundedQueuePreservesSourcePositions() {
        // `.index` is what `play track N of playlist X` consumes. Shuffling the
        // play order must not renumber it — the v2-lite two-kinds-of-index rule.
        let shuffled = continuationShuffleTracks(continuationSource(for: albumQueue()))
        XCTAssertEqual(Set(shuffled?.map(\.index) ?? []), [41, 42, 43])
    }

    func testShuffleOfPlaylistQueueIsNotInMemory() {
        // A real playlist shuffles by name through the existing path.
        XCTAssertNil(continuationShuffleTracks(continuationSource(for: playlistQueue())))
    }

    // MARK: - The rebuilt queue must not lose the label again

    func testShuffledBoundedQueueKeepsTheLabel() {
        // shufflePlayPlaylist (AppQueue.swift:440) drops displayName when it
        // rebuilds. Repeating that here would re-break the label on the NEXT
        // queue-end, one continuation later.
        let q = shuffledBoundedQueue(label: "Moon Safari", source: "Library", tracks: albumQueue().tracks)
        XCTAssertEqual(q.displayName, "Moon Safari")
        XCTAssertEqual(q.contextLabel, "Moon Safari")
    }

    func testShuffledBoundedQueueKeepsTheAddressableSource() {
        let q = shuffledBoundedQueue(label: "Moon Safari", source: "Library", tracks: albumQueue().tracks)
        XCTAssertEqual(q.playlistName, "Library")
        XCTAssertEqual(Set(q.tracks.map(\.index)), [41, 42, 43])
    }

    func testShuffledBoundedQueueStartsAtTheFirstTrackOfThePlayOrder() {
        let q = shuffledBoundedQueue(label: "Moon Safari", source: "Library", tracks: albumQueue().tracks)
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.currentSourcePosition, q.tracks[0].index)
    }
}
