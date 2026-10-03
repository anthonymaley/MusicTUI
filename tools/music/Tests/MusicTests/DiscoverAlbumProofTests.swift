import XCTest
@testable import music

// Album-cleanup step A3: the proof rule (P1-P7, CH13's order) and the P-read
// script and parser. Pure: nothing here touches a file, a socket or Music.app.
//
// Shared with DiscoverAlbumCollectorTests: every helper below carries the
// `a3` prefix (a duplicate name anywhere breaks the whole test target).

/// writeSentAt for every A3 fixture, with a fraction; S = floor of it.
let a3Sent: Double = 1_700_000_000.68
let a3S = 1_700_000_000

/// e_i for song i: the hex whose alias is "\(500 + i)".
func a3EntryHex(_ position: Int) -> String { albumTestHex(500 + position) }
func a3Alias(_ position: Int) -> String { "\(500 + position)" }

/// A pending song that holds P1 and agrees with E.
func a3PendingSong(_ position: Int, relationsBefore: [Int] = [0, 0]) -> DiscoverAlbumSong {
    var song = albumTestSong(position, state: .pending, entryHex: a3EntryHex(position))
    song.relationsBefore = relationsBefore
    return song
}

/// An album entry whose container is ours (`owned`), with E recorded and the
/// write sent at `a3Sent`. `songs` defaults to `count` songs from `a3PendingSong`.
func a3Entry(count: Int = 3, songs: [DiscoverAlbumSong]? = nil, state: DiscoverCopyState = .owned,
             containerGone: Bool? = nil, sent: Double? = a3Sent) -> DiscoverCopyEntry {
    let all = songs ?? (1...count).map { a3PendingSong($0) }
    var entry = albumTestEntry(state: state, hex: state == .intent ? nil : albumTestHex(900), songs: all,
                               containerGone: containerGone)
    entry.writeSentAt = sent
    entry.entryIDs = all.map { $0.entryHex ?? "" }
    return entry
}

/// The P-read answer that holds P3, P5 and P7 for song i of `albumTestSong`.
func a3GoodRead(_ position: Int, title: String? = nil, artist: String? = "Album Artist",
                durationMS: Int? = nil, dateAdded: Int? = a3S,
                cloudStatus: String? = "subscription", matches: Int = 1) -> DiscoverAlbumEntryRead {
    DiscoverAlbumEntryRead(matches: matches, title: title ?? "Track \(position)", artist: artist,
                           durationMS: durationMS ?? 1000 * position, dateAdded: dateAdded,
                           cloudStatus: cloudStatus)
}

final class DiscoverAlbumProofTests: XCTestCase {

    private let at40 = Date(timeIntervalSince1970: a3Sent + 40)

    /// The whole rule for one song: the no-read stage at `now`, two P4 reads
    /// 5 s apart with the same `aliases`, then the P-read.
    private func verdict(entry: DiscoverCopyEntry, position: Int = 1, before: Set<String>? = [],
                         aliases: [String?]? = nil, relationsUnreadable: Bool = false,
                         read: DiscoverAlbumEntryRead? = nil, now: Date? = nil) -> DiscoverAlbumVerdict {
        let song = entry.songs![position - 1]
        let when = now ?? at40
        let first = discoverAlbumVerdictBeforeReads(entry: entry, song: song, beforeSet: { before }, now: when)
        guard first == .pending else { return first }
        let hex = discoverAlbumEntryHex(entry: entry, song: song)!
        let relations: [String?]? = relationsUnreadable ? nil : (aliases ?? [a3Alias(position)])
        let one = discoverAlbumP4Step(entryHex: hex, firstSeenAt: nil, aliases: relations, now: when)
        guard case .notYet(let seen?) = one else {
            if case .uncertain(let reason) = one { return .uncertain(reason) }
            return .pending
        }
        let two = discoverAlbumP4Step(entryHex: hex, firstSeenAt: seen, aliases: relations,
                                      now: when.addingTimeInterval(5))
        switch two {
        case .held(let alias, _):
            return discoverAlbumVerdictAfterRead(entry: entry, song: song, alias: alias,
                                                 read: read ?? a3GoodRead(position))
        case .uncertain(let reason): return .uncertain(reason)
        case .notYet: return .pending
        }
    }

    private func isUncertain(_ verdict: DiscoverAlbumVerdict, file: StaticString = #filePath, line: UInt = #line) {
        guard case .uncertain = verdict else {
            return XCTFail("expected uncertain, got \(verdict)", file: file, line: line)
        }
    }

    // MARK: Design test 9, the proof table

    func testAllSevenHoldingIsOwned() {
        XCTAssertEqual(verdict(entry: a3Entry()), .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: a3Entry(), position: 3), .owned(alias: a3Alias(3)))
    }

    func testP1FailingAloneIsPreexisting() {
        let entry = a3Entry(songs: [a3PendingSong(1, relationsBefore: [0, 1]), a3PendingSong(2), a3PendingSong(3)])
        XCTAssertEqual(verdict(entry: entry), .preexisting)
    }

    func testP2FailingAloneIsUncertain() {
        isUncertain(verdict(entry: a3Entry(state: .uncertain)))
        isUncertain(verdict(entry: a3Entry(state: .closed)))
        isUncertain(verdict(entry: a3Entry(state: .preexisting)))
        XCTAssertEqual(verdict(entry: a3Entry(state: .listening)), .owned(alias: a3Alias(1)))
    }

    func testP3FailingAloneIsUncertain() {
        isUncertain(verdict(entry: a3Entry(), read: a3GoodRead(1, title: "Track 9")))
    }

    func testP4FailingAloneIsUncertain() {
        isUncertain(verdict(entry: a3Entry(), aliases: ["777"]))
    }

    func testP5FailingAloneIsUncertain() {
        isUncertain(verdict(entry: a3Entry(), read: a3GoodRead(1, dateAdded: a3S + 3)))
    }

    func testP6FailingAloneIsPreexisting() {
        XCTAssertEqual(verdict(entry: a3Entry(), before: [a3EntryHex(1)]), .preexisting)
    }

    func testP7FailingAloneIsUncertain() {
        isUncertain(verdict(entry: a3Entry(), read: a3GoodRead(1, cloudStatus: "matched")))
    }

    func testP1UnreadableIsUncertain() {
        for shape in [[0], [], [0, 0, 0], [0, -1]] {
            let entry = a3Entry(songs: [a3PendingSong(1, relationsBefore: shape)])
            XCTAssertEqual(verdict(entry: entry), .uncertain("p1_unreadable"), "\(shape)")
        }
    }

    func testP2UnreadableIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(state: .intent)), .uncertain("p2_container_unknown"))
    }

    func testP3UnreadableIsUncertain() {
        let entry = a3Entry()
        let song = entry.songs![0]
        XCTAssertEqual(discoverAlbumVerdictAfterRead(entry: entry, song: song, alias: a3Alias(1), read: nil),
                       .uncertain("p3_unreadable"))
        isUncertain(verdict(entry: entry, read: a3GoodRead(1, artist: nil)))
        isUncertain(verdict(entry: entry, read: a3GoodRead(1).withDuration(nil)))
        var noE = entry
        noE.entryIDs = nil
        XCTAssertEqual(verdict(entry: noE), .uncertain("e_shape"))
    }

    func testP4UnreadableIsUncertain() {
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: nil, aliases: nil, now: at40),
                       .uncertain("p4_unreadable"))
    }

    func testP5UnreadableIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, dateAdded: nil)), .uncertain("p5_unreadable"))
        XCTAssertEqual(verdict(entry: a3Entry(sent: nil)), .uncertain("no_write_time"))
    }

    func testP6UnreadableIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), before: nil), .uncertain("p6_unreadable"))
    }

    func testP7UnreadableIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, cloudStatus: nil)), .uncertain("p7_unreadable"))
    }

    func testP5WindowIsTheWriteSecondToTwoSecondsLaterInclusive() {
        let entry = a3Entry()
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, dateAdded: a3S)), .owned(alias: a3Alias(1)),
                       "the arm-3 case: date added in the write's own second")
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, dateAdded: a3S + 1)), .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, dateAdded: a3S + 2)), .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, dateAdded: a3S + 3)), .uncertain("p5_date_added"))
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, dateAdded: a3S - 1)), .uncertain("p5_date_added"))
    }

    func testACaseOnlyTitleDifferenceIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, title: "track 1")), .uncertain("p3_title"))
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, artist: "album artist")), .uncertain("p3_artist"))
    }

    func testTitleAndArtistCompareAfterNFCAndWhitespaceOnly() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, title: "  Track   1 ", artist: "Album\tArtist")),
                       .owned(alias: a3Alias(1)))
        XCTAssertEqual(discoverNormalizedStrict("Cafe\u{301}  Society"), discoverNormalizedStrict("Café Society"))
        XCTAssertNotEqual(discoverNormalizedStrict("Café"), discoverNormalizedStrict("CAFÉ"))
        XCTAssertEqual(discoverNormalizedStrict("\n a \t b \n"), "a b")
    }

    func testLengthMustBeWithinOneSecondAndKnownOnBothSides() {
        let entry = a3Entry()   // song 1's row length is 1000 ms
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, durationMS: 1999)), .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, durationMS: 1)), .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: entry, read: a3GoodRead(1, durationMS: 2000)), .uncertain("p3_length"))
        var song = a3PendingSong(1)
        song = DiscoverAlbumSong(position: 1, catalogueID: song.catalogueID, title: song.title, artist: song.artist,
                                 durationMS: nil, relationsBefore: [0, 0], entryHex: song.entryHex, alias: nil,
                                 cloudStatus: nil, state: .pending, p4FirstSeenAt: nil, uncertainReason: nil,
                                 keptReason: nil, keptPlaylist: nil, deletedAt: nil)
        XCTAssertEqual(verdict(entry: a3Entry(songs: [song])), .uncertain("p3_unreadable"))
    }

    func testTheReadMustNameExactlyOneTrack() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, matches: 0)), .uncertain("p3_matches"))
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, matches: 2)), .uncertain("p3_matches"))
    }

    func testCloudStatusIsTrimmedThenExactlySubscription() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, cloudStatus: " subscription\n")),
                       .owned(alias: a3Alias(1)))
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, cloudStatus: "Subscription")),
                       .uncertain("p7_cloud_status"))
    }

    // MARK: The E-shape (P3, first half)

    func testTheEShapeMustBeRecordedFullLengthWellFormedAndDistinct() {
        var short = a3Entry()
        short.entryIDs = Array(short.entryIDs!.prefix(2))
        XCTAssertEqual(verdict(entry: short), .uncertain("e_shape"))

        var malformed = a3Entry()
        malformed.entryIDs![1] = "not-a-hex"
        XCTAssertEqual(verdict(entry: malformed), .uncertain("e_shape"), "a bad ID anywhere fails every song")

        var lower = a3Entry()
        lower.entryIDs![0] = lower.entryIDs![0].lowercased()   // "00000000000001F5" -> "...1f5"
        XCTAssertEqual(verdict(entry: lower), .uncertain("e_shape"))

        var repeated = a3Entry()
        repeated.entryIDs![2] = repeated.entryIDs![1]
        XCTAssertEqual(verdict(entry: repeated), .uncertain("e_shape"))
    }

    func testASongWhoseRecordedHexDisagreesWithEIsUncertain() {
        var song = a3PendingSong(1)
        song.entryHex = a3EntryHex(7)
        var entry = a3Entry(songs: [song])
        entry.entryIDs = [a3EntryHex(1)]
        XCTAssertEqual(verdict(entry: entry), .uncertain("e_shape"))
    }

    // MARK: CH13's order

    func testP1IsDecidedBeforeEverythingElse() {
        var entry = a3Entry(songs: [a3PendingSong(1, relationsBefore: [2, 0])], state: .uncertain, sent: nil)
        entry.entryIDs = nil
        XCTAssertEqual(verdict(entry: entry, before: nil), .preexisting)
    }

    func testTheEShapeIsDecidedBeforeP6() {
        var entry = a3Entry()
        entry.entryIDs = nil
        var asked = false
        let result = discoverAlbumVerdictBeforeReads(entry: entry, song: entry.songs![0],
                                                     beforeSet: { asked = true; return [a3EntryHex(1)] }, now: at40)
        XCTAssertEqual(result, .uncertain("e_shape"))
        XCTAssertFalse(asked, "B is not read once the E-shape has failed")
    }

    func testP6IsDecidedBeforeP2() {
        XCTAssertEqual(verdict(entry: a3Entry(state: .uncertain), before: [a3EntryHex(1)]), .preexisting,
                       "his reused row reads preexisting, not uncertain")
    }

    // MARK: The window

    func testTheWindowClosesOnlyForASongWhoseP4HasNotHeld() {
        let entry = a3Entry()
        let edge = Date(timeIntervalSince1970: a3Sent + 180)
        let past = Date(timeIntervalSince1970: a3Sent + 180.01)
        XCTAssertEqual(discoverAlbumVerdictBeforeReads(entry: entry, song: entry.songs![0], beforeSet: { [] }, now: edge),
                       .pending, "the window is inclusive at +180 s")
        XCTAssertEqual(discoverAlbumVerdictBeforeReads(entry: entry, song: entry.songs![0], beforeSet: { [] }, now: past),
                       .uncertain("window_closed"))
        var heldSong = entry.songs![0]
        heldSong.alias = a3Alias(1)
        XCTAssertEqual(discoverAlbumVerdictBeforeReads(entry: entry, song: heldSong, beforeSet: { [] }, now: past),
                       .pending, "a held song waits for its P-read")
    }

    // MARK: Design test 10, P4 specifics

    func testOneReadAloneStaysPending() {
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: nil, aliases: [a3Alias(1)], now: at40),
                       .notYet(firstSeenAt: at40.timeIntervalSince1970))
    }

    func testTwoEqualReadsTwoSecondsApartHold() {
        let first = at40.timeIntervalSince1970
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: first, aliases: [a3Alias(1)],
                                           now: at40.addingTimeInterval(2)),
                       .held(alias: a3Alias(1), firstSeenAt: first))
    }

    func testTwoEqualReadsOnePointNineSecondsApartAreNotYet() {
        let first = at40.timeIntervalSince1970
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: first, aliases: [a3Alias(1)],
                                           now: at40.addingTimeInterval(1.9)),
                       .notYet(firstSeenAt: first))
    }

    func testTwoRelationsAreUncertain() {
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: nil,
                                           aliases: [a3Alias(1), "12"], now: at40),
                       .uncertain("p4_several_relations"))
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: nil, aliases: [nil, nil], now: at40),
                       .uncertain("p4_several_relations"))
    }

    func testAnAliasWhoseHexIsNotTheEntryIsUncertain() {
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: 1, aliases: [a3Alias(2)], now: at40),
                       .uncertain("p4_other_row"))
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: nil, aliases: ["x"], now: at40),
                       .uncertain("p4_other_row"), "an alias with no hex at all")
    }

    func testANullRelationOrNoneIsStillPendingAndResetsTheStreak() {
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: 12, aliases: [nil], now: at40),
                       .notYet(firstSeenAt: nil), "CH11")
        XCTAssertEqual(discoverAlbumP4Step(entryHex: a3EntryHex(1), firstSeenAt: 12, aliases: [], now: at40),
                       .notYet(firstSeenAt: nil))
    }

    // MARK: Design test 21, decision 5 pinned

    func testHisOwnAddFoldedIntoOurRowIsOwned() {
        // Same e_i, one relation, date added inside [S, S + 2]: nothing tells it apart.
        XCTAssertEqual(verdict(entry: a3Entry(), aliases: [a3Alias(1)], read: a3GoodRead(1, dateAdded: a3S + 1)),
                       .owned(alias: a3Alias(1)))
    }

    // MARK: Design test 22, verdict half

    func testP1AtOneOrMoreIsPreexisting() {
        for shape in [[1, 0], [0, 1], [3, 3]] {
            let entry = a3Entry(songs: [a3PendingSong(1, relationsBefore: shape)])
            XCTAssertEqual(verdict(entry: entry), .preexisting, "\(shape)")
        }
    }

    func testARowInBWithADifferentTitleAndAFreshDateIsPreexisting() {
        XCTAssertEqual(verdict(entry: a3Entry(), before: [a3EntryHex(1)],
                               read: a3GoodRead(1, title: "Something Else", dateAdded: a3S)),
                       .preexisting)
    }

    func testMatchedUploadedOrPurchasedWithP1AtZeroIsUncertain() {
        for status in ["matched", "uploaded", "purchased", "ineligible", "local"] {
            XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, cloudStatus: status)),
                           .uncertain("p7_cloud_status"), status)
        }
    }

    func testATitleMismatchIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, title: "Track 1 (Remastered)")),
                       .uncertain("p3_title"))
    }

    func testDateAddedOneSecondEarlyIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), read: a3GoodRead(1, dateAdded: a3S - 1)), .uncertain("p5_date_added"))
    }

    func testTheMeasuredArm3Shape() {
        // Four songs. Entry 3 is his 2013 `matched` row, reused: 0 relations
        // before and throughout, date added 2013, and in B. The other three are
        // new rows dated in the write's own second.
        let entry = a3Entry(count: 4)
        let before: Set<String> = [a3EntryHex(3), albumTestHex(42)]
        XCTAssertEqual(verdict(entry: entry, position: 3, before: before, aliases: [],
                               read: a3GoodRead(3, dateAdded: 1_383_086_438, cloudStatus: "matched")),
                       .preexisting)
        for position in [1, 2, 4] {
            XCTAssertEqual(verdict(entry: entry, position: position, before: before,
                                   read: a3GoodRead(position, dateAdded: a3S)),
                           .owned(alias: a3Alias(position)), "song \(position)")
        }
    }

    func testTwoRelationsAfterIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), aliases: [a3Alias(1), "99"]), .uncertain("p4_several_relations"))
    }

    func testAnUnreadableReadIsUncertain() {
        XCTAssertEqual(verdict(entry: a3Entry(), relationsUnreadable: true), .uncertain("p4_unreadable"))
        let entry = a3Entry()
        XCTAssertEqual(discoverAlbumVerdictAfterRead(entry: entry, song: entry.songs![0], alias: a3Alias(1),
                                                     read: parseDiscoverAlbumEntryRead(nil)),
                       .uncertain("p3_unreadable"))
    }

    // MARK: P-read: the script, the name gate and the parser

    func testThePReadScriptAssignsOnlyAllowListedNames() {
        let names = appleScriptAssignedNames(discoverAlbumProofReadScript(hex: a3EntryHex(1)))
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.isSubset(of: discoverAlbumScriptVariables), "\(names.subtracting(discoverAlbumScriptVariables))")
        XCTAssertTrue(names.isDisjoint(with: discoverAppleScriptReservedNames))
    }

    func testThePReadScriptNamesTheHexOnlyAndAMalformedHexBuildsNoScript() {
        let script = discoverAlbumProofReadScript(hex: "26F39E39DA2D1BD7")
        XCTAssertTrue(script.contains(#"whose persistent ID is "26F39E39DA2D1BD7""#))
        XCTAssertTrue(script.contains("«class isot»"))
        XCTAssertTrue(script.contains("(ASCII character 31)"))
        XCTAssertFalse(script.contains("delete"))
        XCTAssertFalse(script.contains("tell application"), "the runner wraps the body")
        for bad in ["26f39e39da2d1bd7", "26F39E39DA2D1BD", "26F39E39DA2D1BD7\" & x", ""] {
            XCTAssertEqual(discoverAlbumProofReadScript(hex: bad), "", bad)
        }
    }

    private let us = "\u{1F}"

    func testTheParserReadsACount() {
        XCTAssertEqual(parseDiscoverAlbumEntryRead("count\(us)0"),
                       DiscoverAlbumEntryRead(matches: 0, title: nil, artist: nil, durationMS: nil,
                                              dateAdded: nil, cloudStatus: nil))
        XCTAssertEqual(parseDiscoverAlbumEntryRead("count\(us)2\n")?.matches, 2)
        XCTAssertNil(parseDiscoverAlbumEntryRead("count\(us)two"))
        XCTAssertNil(parseDiscoverAlbumEntryRead("count\(us)-1"))
        XCTAssertNil(parseDiscoverAlbumEntryRead("count"))
    }

    func testTheParserReadsOkAndFiveFields() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        let output = "ok\(us)Blue in Green\(us)Miles Davis\(us)337000\(us)2013-10-29T23:40:38\(us)subscription\n"
        XCTAssertEqual(parseDiscoverAlbumEntryRead(output, timeZone: zone),
                       DiscoverAlbumEntryRead(matches: 1, title: "Blue in Green", artist: "Miles Davis",
                                              durationMS: 337000, dateAdded: 1_383_086_438,
                                              cloudStatus: "subscription"))
    }

    func testTheISODateIsParsedInTheGivenTimeZone() throws {
        let gmt = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let plusOne = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        XCTAssertEqual(discoverAlbumParseDateAdded("2013-10-29T23:40:38", timeZone: gmt), 1_383_090_038)
        XCTAssertEqual(discoverAlbumParseDateAdded("2013-10-29T23:40:38", timeZone: plusOne), 1_383_086_438)
        for bad in ["2013-10-29 23:40:38", "2013-10-29T23:40:38Z", "2013-10-29T23:40:38+01:00",
                    "2013-13-29T23:40:38", "2013-02-30T10:00:00", "29/10/2013", ""] {
            XCTAssertNil(discoverAlbumParseDateAdded(bad, timeZone: gmt), bad)
        }
    }

    func testAnUnparseableDateIsANilFieldAndTheRestIsKept() {
        let read = parseDiscoverAlbumEntryRead("ok\(us)T\(us)A\(us)1000\(us)Tuesday\(us)subscription")
        XCTAssertEqual(read?.matches, 1)
        XCTAssertNil(read?.dateAdded)
        XCTAssertEqual(read?.title, "T")
        XCTAssertEqual(read?.cloudStatus, "subscription")
        XCTAssertNil(parseDiscoverAlbumEntryRead("ok\(us)T\(us)A\(us)1.5e3\(us)2013-10-29T23:40:38\(us)x")?.durationMS)
    }

    func testAnEmptyFieldIsANilField() {
        let read = parseDiscoverAlbumEntryRead("ok\(us)\(us)\(us)\(us)\(us)")
        XCTAssertEqual(read, DiscoverAlbumEntryRead(matches: 1, title: nil, artist: nil, durationMS: nil,
                                                    dateAdded: nil, cloudStatus: nil))
    }

    func testAMissingOrExtraFieldOrAFailedCallIsUnreadable() {
        XCTAssertNil(parseDiscoverAlbumEntryRead("ok\(us)T\(us)A\(us)1000\(us)2013-10-29T23:40:38"), "a missing field")
        XCTAssertNil(parseDiscoverAlbumEntryRead("ok\(us)T\(us)A\(us)1000\(us)2013-10-29T23:40:38\(us)s\(us)x"))
        XCTAssertNil(parseDiscoverAlbumEntryRead(nil), "the call failed")
        XCTAssertNil(parseDiscoverAlbumEntryRead(""))
        XCTAssertNil(parseDiscoverAlbumEntryRead("ok|T|A|1000|2013-10-29T23:40:38|subscription"), "wrong separator")
        XCTAssertNil(parseDiscoverAlbumEntryRead("OK\(us)T\(us)A\(us)1000\(us)2013-10-29T23:40:38\(us)s"))
    }
}

private extension DiscoverAlbumEntryRead {
    func withDuration(_ ms: Int?) -> DiscoverAlbumEntryRead {
        DiscoverAlbumEntryRead(matches: matches, title: title, artist: artist, durationMS: ms,
                               dateAdded: dateAdded, cloudStatus: cloudStatus)
    }
}
