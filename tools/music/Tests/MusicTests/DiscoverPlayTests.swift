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
}
