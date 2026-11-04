// tools/music/Tests/MusicTests/DJGenrePickTests.swift
//
// "A genre I haven't heard lately", as pure pieces: the two-way genre match,
// the filter (played over 90 days ago, or never; the OLDEST 50, then
// shuffled), the bulk-column library read (one separate timed read in
// LibraryIndex's shape; played date as locale-independent epoch text;
// never-played and unreadable kept apart; misaligned columns fail whole), the
// frozen persistent-ID queue, and the SpanDAC genre source behind its protocol.
// No AppleScript runs: the read takes a script runner, and every test hands in
// a fake.
import XCTest
@testable import music

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func pid(_ n: Int) -> String { String(format: "%016X", n) }

private func song(_ n: Int, genre: String = "Jazz", played: DJPlayed) -> DJLibrarySong {
    DJLibrarySong(persistentID: pid(n), name: "Song \(n)", artist: "Artist", album: "Album", genre: genre,
                  played: played)
}

private func ago(_ days: Double) -> DJPlayed { .at(now.addingTimeInterval(-days * day)) }

final class DJGenrePickTests: XCTestCase {

    // MARK: - The two-way genre match

    func testTheGenreMatchContainsInEitherDirectionIgnoringCase() {
        XCTAssertTrue(djGenreMatches(songGenre: "Vocal Jazz", wanted: "jazz"), "jazz finds Vocal Jazz")
        XCTAssertTrue(djGenreMatches(songGenre: "Jazz", wanted: "Cool jazz"), "Cool jazz finds Jazz")
        XCTAssertTrue(djGenreMatches(songGenre: "JAZZ", wanted: "jazz"))
        XCTAssertFalse(djGenreMatches(songGenre: "Rock", wanted: "Jazz"))
        XCTAssertFalse(djGenreMatches(songGenre: "", wanted: "Jazz"), "an empty genre matches nothing")
        XCTAssertFalse(djGenreMatches(songGenre: "Jazz", wanted: "  "), "an empty wish matches nothing")
        XCTAssertTrue(djGenreMatches(songGenre: " Jazz ", wanted: "jazz"))
    }

    // MARK: - The filter

    func testOnlySongsPlayedOverNinetyDaysAgoOrNeverAreEligible() {
        let songs = [song(1, played: ago(91)), song(2, played: ago(89)), song(3, played: .never),
                     song(4, played: ago(90.5)), song(5, genre: "Rock", played: .never)]
        let pick = djPickUnheard(songs, genre: "jazz", now: now, days: 90, limit: 50, shuffler: DJReverseShuffle())
        XCTAssertEqual(Set(pick.picked.map(\.persistentID)), [pid(1), pid(3), pid(4)])
        XCTAssertEqual(pick.eligible, 3)
    }

    func testTheOldestFiftyAreTakenThenShuffled() {
        // 60 eligible songs, song n played (100 + n) days ago: song 60 is the oldest.
        let songs = (1...60).map { song($0, played: ago(Double(100 + $0))) }
        let pick = djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 50, shuffler: DJReverseShuffle())
        XCTAssertEqual(pick.picked.count, 50)
        XCTAssertEqual(pick.eligible, 60)
        // The oldest 50 are songs 11...60; reversed by the shuffler, newest of them first.
        XCTAssertEqual(pick.picked.map(\.persistentID), (11...60).map(pid))
    }

    func testNeverPlayedCountsAsOlderThanAnyDate() {
        var songs = (1...50).map { song($0, played: ago(Double(1_000 + $0))) }
        songs.append(song(99, played: .never))
        let pick = djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 50, shuffler: DJReverseShuffle())
        XCTAssertTrue(pick.picked.map(\.persistentID).contains(pid(99)), "a never-played song fell outside the oldest 50")
        XCTAssertFalse(pick.picked.map(\.persistentID).contains(pid(1)), "the newest of 51 stayed")
    }

    func testAnUnreadableDateIsNeverTreatedAsNeverPlayed() {
        let songs = [song(1, played: .unreadable), song(2, played: .never), song(3, played: ago(200))]
        let pick = djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 50, shuffler: DJReverseShuffle())
        XCTAssertEqual(Set(pick.picked.map(\.persistentID)), [pid(2), pid(3)])
        XCTAssertEqual(pick.unreadable, 1, "the skipped song is counted, and said")
    }

    func testAnUnreadableDateOutsideTheGenreIsNotCounted() {
        let pick = djPickUnheard([song(1, genre: "Rock", played: .unreadable)], genre: "Jazz", now: now, days: 90,
                                 limit: 50, shuffler: DJReverseShuffle())
        XCTAssertEqual(pick.unreadable, 0)
    }

    func testNothingEligibleIsEmpty() {
        let pick = djPickUnheard([song(1, played: ago(3))], genre: "Jazz", now: now, days: 90, limit: 50,
                                 shuffler: DJReverseShuffle())
        XCTAssertEqual(pick.picked, [])
        XCTAssertEqual(pick.eligible, 0)
    }

    func testZeroAndFiftyLimits() {
        let songs = (1...50).map { song($0, played: ago(Double(100 + $0))) }
        XCTAssertEqual(djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 0,
                                     shuffler: DJReverseShuffle()).picked.count, 0)
        XCTAssertEqual(djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 50,
                                     shuffler: DJReverseShuffle()).picked.count, 50)
    }

    func testTiesBreakByPersistentIDSoThePickIsDeterministic() {
        let same = ago(200)
        let songs = (1...5).reversed().map { song($0, played: same) }
        let pick = djPickUnheard(songs, genre: "Jazz", now: now, days: 90, limit: 3, shuffler: DJReverseShuffle())
        XCTAssertEqual(Set(pick.picked.map(\.persistentID)), [pid(1), pid(2), pid(3)])
    }

    // MARK: - The scope line

    func testTheLineNamesGenreDaysAndCount() {
        let pick = DJGenrePick(picked: (1...50).map { song($0, played: .never) }, eligible: 312, unreadable: 0)
        XCTAssertEqual(pick.line(genre: "Jazz", days: 90), "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        let one = DJGenrePick(picked: [song(1, played: .never)], eligible: 1, unreadable: 2)
        XCTAssertEqual(one.line(genre: "Jazz", days: 90),
                       "Jazz you haven't played in 90 days \u{00B7} 1 song (2 with an unreadable date skipped)")
    }

    // MARK: - The bulk read

    private let fs = "\u{1F}", rs = "\u{1E}"

    private func raw(ids: [String], names: [String]? = nil, artists: [String]? = nil, albums: [String]? = nil,
                     genres: [String]? = nil, played: [String]) -> String {
        let n = ids.count
        func col(_ v: [String]?, _ fallback: String) -> String {
            (v ?? Array(repeating: fallback, count: n)).joined(separator: rs)
        }
        return [col(ids, ""), col(names, "N"), col(artists, "A"), col(albums, "B"), col(genres, "Jazz"),
                played.joined(separator: rs)].joined(separator: fs)
    }

    func testTheScriptReadsColumnsInBulkWithoutAFilter() {
        let script = djLibraryGenreScript()
        for needle in ["playlist \"Library\"", "persistent ID of every track", "genre of every track",
                       "played date of every track", "name of every track", "artist of every track",
                       "album of every track"] {
            XCTAssertTrue(script.contains(needle), "the bulk read lacks `\(needle)`")
        }
        XCTAssertFalse(script.contains(" whose "), "a filter loses the bulk read (LibraryIndex.swift)")
        XCTAssertTrue(script.contains("date +%s"), "the played date must leave the script as epoch text")
    }

    /// Measured on the Studio's library (10,640 tracks, 4.1 s): AppleScript holds
    /// epoch seconds as a real, and `... as text` of one renders 1.79E+9, which
    /// this parser (rightly) reads as unreadable. The script builds plain digits.
    func testTheScriptBuildsPlainDigitsAndTheParserDoesNotAcceptAnExponentForm() throws {
        XCTAssertTrue(djLibraryGenreScript().contains("div 100000"))
        let read = try djParseLibraryGenreRead(raw(ids: [pid(1)], played: ["1.793821586E+9"]))
        XCTAssertEqual(read.songs.map(\.played), [.unreadable])
    }

    func testParsingReadsNeverEpochAndUnreadable() throws {
        let epoch = 1_700_000_000
        let text = raw(ids: [pid(1), pid(2), pid(3)], played: ["N", "\(epoch)", "U"])
        let read = try djParseLibraryGenreRead(text)
        XCTAssertEqual(read.songs.map(\.played),
                       [.never, .at(Date(timeIntervalSince1970: TimeInterval(epoch))), .unreadable])
        XCTAssertEqual(read.songs.map(\.persistentID), [pid(1), pid(2), pid(3)])
        XCTAssertEqual(read.songs.first?.genre, "Jazz")
    }

    func testAGarbageDateIsUnreadableNotNever() throws {
        let read = try djParseLibraryGenreRead(raw(ids: [pid(1), pid(2)], played: ["12/31/2024", ""]))
        XCTAssertEqual(read.songs.map(\.played), [.unreadable, .unreadable])
    }

    func testMisalignedColumnCountsFailTheWholeRead() {
        let skewed = [pid(1), pid(2)].joined(separator: rs)
        let text = [skewed, "N", "A", "B", "Jazz", "N\(rs)N"].joined(separator: fs)
        XCTAssertThrowsError(try djParseLibraryGenreRead(text)) {
            XCTAssertEqual($0 as? DJLibraryReadError, .misaligned)
        }
    }

    func testTheWrongNumberOfColumnBlocksFailsTheWholeRead() {
        XCTAssertThrowsError(try djParseLibraryGenreRead("a\(fs)b\(fs)c")) {
            XCTAssertEqual($0 as? DJLibraryReadError, .misaligned)
        }
        XCTAssertThrowsError(try djParseLibraryGenreRead("")) {
            XCTAssertEqual($0 as? DJLibraryReadError, .misaligned)
        }
    }

    func testAnEmptyLibraryIsEmptyNotAnError() throws {
        let text = ["", "", "", "", "", ""].joined(separator: fs)
        XCTAssertEqual(try djParseLibraryGenreRead(text).songs, [])
    }

    func testARowWhoseIDIsNotAPersistentIDIsLeftOutAndCounted() throws {
        let read = try djParseLibraryGenreRead(raw(ids: [pid(1), "NOPE"], played: ["N", "N"]))
        XCTAssertEqual(read.songs.map(\.persistentID), [pid(1)])
        XCTAssertEqual(read.skippedBadIDs, 1)
    }

    func testTrailingWhitespaceFromTheScriptIsTolerated() throws {
        let read = try djParseLibraryGenreRead(raw(ids: [pid(1)], played: ["N"]) + "\n")
        XCTAssertEqual(read.songs.count, 1)
    }

    // MARK: - Running the read

    func testTheReadRunsTheScriptOnceUnderATimeout() throws {
        var calls: [(String, TimeInterval)] = []
        let text = raw(ids: [pid(1)], played: ["N"])
        let read = try djReadLibraryForGenre(run: { calls.append(($0, $1)); return text })
        XCTAssertEqual(read.songs.count, 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, djLibraryGenreScript())
        XCTAssertEqual(calls.first?.1, DJLibraryTiming.timeoutSeconds)
        XCTAssertGreaterThan(DJLibraryTiming.timeoutSeconds, 0)
    }

    func testATimeoutRefusesAsATimeout() {
        XCTAssertThrowsError(try djReadLibraryForGenre(run: { _, _ in throw AppleScriptBackend.ScriptError.timeout("script") })) {
            XCTAssertEqual($0 as? DJLibraryReadError, .timedOut)
        }
    }

    func testAnyOtherFailureRefusesWithItsText() {
        XCTAssertThrowsError(try djReadLibraryForGenre(run: { _, _ in throw AppleScriptBackend.ScriptError.executionFailed("boom") })) {
            guard case .failed(let text)? = $0 as? DJLibraryReadError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("boom"), text)
        }
    }

    func testEveryReadFailureHasWordsForThePerson() {
        for error in [DJLibraryReadError.timedOut, .misaligned, .failed("x")] {
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertEqual(DJLibraryReadError.timedOut.message, djLibraryReadTimedOut)
        XCTAssertEqual(DJLibraryReadError.misaligned.message, djLibraryMisaligned)
    }

    // MARK: - The frozen queue

    func testTheQueueIsAddressedByPersistentIDInTheFrozenOrder() throws {
        let songs = [song(7, played: .never), song(3, played: .never)]
        let queue = try XCTUnwrap(djOpenQueue(songs, title: "Jazz you haven't played"))
        XCTAssertEqual(queue.playlistName, persistentIDQueueSource)
        XCTAssertEqual(queue.tracks.map { persistentIDOfQueueEntry($0.index) }, [pid(7), pid(3)])
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.contextLabel, "Jazz you haven't played")
        XCTAssertEqual(queue.tracks.first?.name, "Song 7")
    }

    func testOneBadIdentityFailsTheWholeQueue() {
        let bad = DJLibrarySong(persistentID: "XYZ", name: "n", artist: "a", album: "b", genre: "Jazz", played: .never)
        XCTAssertNil(djOpenQueue([song(1, played: .never), bad], title: "t"))
        XCTAssertNil(djOpenQueue([], title: "t"), "an empty queue is not a queue")
    }

    // MARK: - The SpanDAC source

    func testTheStubSaysItNeedsANewerSpanDACAndNothingElse() {
        let stub = DJSpanDACGenreStub()
        XCTAssertThrowsError(try stub.genreUnheard(genre: "Jazz", days: 90)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .needsNewerSpanDAC)
        }
        XCTAssertEqual(DJGenreSourceError.needsNewerSpanDAC.message, djNeedsNewerSpanDAC)
        XCTAssertTrue(djNeedsNewerSpanDAC.contains("newer SpanDAC"))
    }

    func testEverySourceErrorHasWords() {
        for error in [DJGenreSourceError.needsNewerSpanDAC, .libraryChanged, .failed("why")] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }
}
