import XCTest
@testable import music

final class DiscoverPlayTests: XCTestCase {
    /// Verbatim shape from the live probe (2026-08-26). An owned song carries one
    /// entry under relationships.library.data whose id is the LIBRARY id; an
    /// unowned song carries an empty array. Both directions were verified against
    /// real library rows.
    private let membershipJSON = """
    {"data":[
      {"id":"1530656381","type":"songs","attributes":{"name":"A-Men"},
       "relationships":{"library":{"data":[{"id":"i.OWGzxc4eMxPv","type":"library-songs"}]}}},
      {"id":"270425151","type":"songs","attributes":{"name":"A-Punk"},
       "relationships":{"library":{"data":[{"id":"i.6X0XQfL9qaob","type":"library-songs"}]}}},
      {"id":"9999999999","type":"songs","attributes":{"name":"Not Owned"},
       "relationships":{"library":{"data":[]}}}
    ]}
    """

    /// The partition this whole feature's safety rests on. Anything in `owned`
    /// is the user's own music and must never become eligible for deletion.
    func testPartitionsOwnedFromUnowned() throws {
        let p = parseLibraryMembership(Data(membershipJSON.utf8))
        XCTAssertEqual(p.owned, ["1530656381": "i.OWGzxc4eMxPv",
                                 "270425151": "i.6X0XQfL9qaob"])
        XCTAssertEqual(p.unowned, ["9999999999"])
    }

    /// A song the response omits entirely is NOT evidence that the user does not
    /// own it — it is evidence of nothing. Treating silence as "unowned" would
    /// make it deletable, which is the failure this feature must never have.
    func testAbsentSongIsNeitherOwnedNorUnowned() throws {
        let p = parseLibraryMembership(Data(membershipJSON.utf8))
        XCTAssertNil(p.owned["1234"])
        XCTAssertFalse(p.unowned.contains("1234"))
    }

    /// THE SAFETY TEST. Membership is three-valued: only an explicitly present
    /// empty `data` array proves a song is unowned. Every other degraded shape is
    /// the API saying nothing, and must land in NEITHER set.
    ///
    /// A draft of this parser defaulted the missing chain to `[]`, which turned
    /// all five shapes below into "unowned" — that is, into deletable. Each case
    /// here is a distinct way the API can degrade, and each one would have cost
    /// the user music they own.
    func testDegradedShapesAreNeverDeletable() {
        let shapes = [
            "relationships absent":  #"{"data":[{"id":"S1","type":"songs"}]}"#,
            "library key absent":    #"{"data":[{"id":"S2","relationships":{}}]}"#,
            "data key absent":       #"{"data":[{"id":"S3","relationships":{"library":{}}}]}"#,
            "data not an array":     #"{"data":[{"id":"S4","relationships":{"library":{"data":"nope"}}}]}"#,
            "entry without an id":   #"{"data":[{"id":"S5","relationships":{"library":{"data":[{"type":"library-songs"}]}}}]}"#,
        ]
        for (label, json) in shapes {
            let p = parseLibraryMembership(Data(json.utf8))
            XCTAssertTrue(p.unowned.isEmpty, "\(label): must not be deletable")
            XCTAssertTrue(p.owned.isEmpty, "\(label): must not be claimed as owned either")
        }
    }

    /// The one shape that DOES prove absence, so the feature is not uselessly
    /// conservative: an explicitly present empty array.
    func testExplicitEmptyArrayIsTheOnlyProofOfAbsence() {
        let json = #"{"data":[{"id":"S6","relationships":{"library":{"data":[]}}}]}"#
        XCTAssertEqual(parseLibraryMembership(Data(json.utf8)).unowned, ["S6"])
    }

    /// Malformed or empty payloads must yield an empty partition, never a
    /// partition that claims everything is unowned.
    func testMalformedPayloadYieldsNothingDeletable() {
        XCTAssertTrue(parseLibraryMembership(Data("{}".utf8)).unowned.isEmpty)
        XCTAssertTrue(parseLibraryMembership(Data("not json".utf8)).unowned.isEmpty)
        XCTAssertTrue(parseLibraryMembership(Data(#"{"data":[]}"#.utf8)).unowned.isEmpty)
    }

    /// The request batches, so the id list must round-trip in order with no
    /// escaping surprises.
    func testBuildsABatchedIDsQuery() {
        XCTAssertEqual(libraryMembershipPath(storefront: "us", catalogIDs: ["1", "2", "3"]),
                       "/v1/catalog/us/songs?ids=1,2,3&include=library")
        XCTAssertNil(libraryMembershipPath(storefront: "us", catalogIDs: []))
    }

    // MARK: - Readiness

    /// The add returns 202 and materializes asynchronously, so playback must wait
    /// for the expected track count rather than assume it. Playing a partially
    /// materialized playlist would start a short album that grows underneath.
    func testReadinessWaitsUntilTheFullCountLands() {
        XCTAssertEqual(discoverReadiness(observed: 0, expected: 5, elapsed: 0.2, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 3, expected: 5, elapsed: 1.0, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 5, expected: 5, elapsed: 2.1, timeout: 10), .ready)
    }

    /// More than expected is still ready — never block on an off-by-one from
    /// Apple's side.
    func testReadinessAcceptsMoreThanExpected() {
        XCTAssertEqual(discoverReadiness(observed: 6, expected: 5, elapsed: 1.0, timeout: 10), .ready)
    }

    /// On timeout the transaction is abandoned rather than played. The playlist
    /// survives for the sweep; a half-materialized play is worse than none.
    func testReadinessTimesOutRatherThanPlayingPartial() {
        XCTAssertEqual(discoverReadiness(observed: 2, expected: 5, elapsed: 10.0, timeout: 10), .timedOut)
    }

    // MARK: - Position mapping

    /// "Play from here" resolves on CATALOG ID against what actually
    /// materialized. Not on title: repeated titles are common — DJ mixes with
    /// several `ID` entries, albums with a reprise, movements sharing a name —
    /// and a title match plays whichever came first, which is not the row the
    /// user selected.
    func testPositionMapsByCatalogIDAgainstMaterializedOrder() {
        let materialized = ["c.10", "c.20", "c.30", "c.40"]   // catalog ids, in order
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.30", in: materialized), 3)
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.10", in: materialized), 1)
    }

    /// The case a title match gets wrong. Two tracks share a title but not an id;
    /// the second must resolve to position 2.
    func testRepeatedTitlesStillResolveToTheSelectedRow() {
        let materialized = ["c.reprise-a", "c.reprise-b"]
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.reprise-b", in: materialized), 2)
    }

    /// A selected track that did not materialize has no honest position. The
    /// caller must REPORT, never fall back to 1 — playing a different song than
    /// the one chosen is wrong, and a warning does not make it right.
    func testPositionIsNilWhenTheSelectedTrackDidNotMaterialize() {
        XCTAssertNil(discoverPlayPosition(catalogID: "c.missing", in: ["c.10", "c.20"]))
        XCTAssertNil(discoverPlayPosition(catalogID: "c.10", in: []))
    }
}
