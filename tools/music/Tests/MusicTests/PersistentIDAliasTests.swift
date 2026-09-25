import XCTest
@testable import music

/// The alias a finished library play carries, as the Music.app persistent ID
/// the write-back looks the track up by.
///
/// The alias is a signed decimal; Music.app shows the same 64 bits as sixteen
/// uppercase hex digits. The first four fixtures were checked against real
/// library tracks.
final class PersistentIDAliasTests: XCTestCase {

    func testRealLibraryFixtures() {
        XCTAssertEqual(persistentIDHex(fromAlias: "596357614188841472"), "0846B01728D34A00")    // Are You Awake?
        XCTAssertEqual(persistentIDHex(fromAlias: "-2898457328848859944"), "D7C69C6A85560CD8")  // Organ Donor
        XCTAssertEqual(persistentIDHex(fromAlias: "854956139719541203"), "0BDD6A144E85C1D3")    // Spontaneous
        XCTAssertEqual(persistentIDHex(fromAlias: "-2643396558234642425"), "DB50C4D5E9EF1807")  // Tranz
    }

    func testZeroAndMinusOne() {
        XCTAssertEqual(persistentIDHex(fromAlias: "0"), "0000000000000000")
        XCTAssertEqual(persistentIDHex(fromAlias: "-1"), "FFFFFFFFFFFFFFFF")
    }

    func testSignedExtremes() {
        XCTAssertEqual(persistentIDHex(fromAlias: String(Int64.max)), "7FFFFFFFFFFFFFFF")
        XCTAssertEqual(persistentIDHex(fromAlias: String(Int64.min)), "8000000000000000")
    }

    func testSmallValueIsZeroPadded() {
        XCTAssertEqual(persistentIDHex(fromAlias: "15"), "000000000000000F")
    }

    /// Too large for a signed 64-bit value but still 64 bits unsigned.
    func testUnsignedFallback() {
        XCTAssertEqual(persistentIDHex(fromAlias: "18446744073709551615"), "FFFFFFFFFFFFFFFF")
    }

    func testAnythingElseIsNil() {
        for bad in ["", " 1", "1.0", "0x1F", "abc", "+5", "18446744073709551616"] {
            XCTAssertNil(persistentIDHex(fromAlias: bad), "expected nil for \(bad.debugDescription)")
        }
    }
}
