import XCTest
@testable import music

/// Cached rows route by origin: catalog rows to the API, library rows to an
/// AppleScript duplicate of the track the user already owns. The partition and
/// the "all library" fact are pure so the keyless flows are testable without a
/// token or a running Music.app.
final class CachedRowRoutingTests: XCTestCase {
    private func row(_ i: Int, _ origin: SongOrigin) -> SongResult {
        SongResult(index: i, title: "T\(i)", artist: "A\(i)", album: "", catalogId: "id\(i)", origin: origin)
    }

    func testPartitionKeepsTypedOrderInsideEachHalf() {
        let p = partitionByOrigin([row(3, .library), row(1, .catalog), row(2, .library)])
        XCTAssertEqual(p.catalog.map(\.index), [1])
        XCTAssertEqual(p.library.map(\.index), [3, 2])
    }

    func testAllLibraryRowsIsFalseForEmptyInput() {
        XCTAssertFalse(allLibraryRows([]))
    }

    func testAllLibraryRowsIsFalseWhenOneCatalogRowIsMixedIn() {
        XCTAssertFalse(allLibraryRows([row(1, .library), row(2, .catalog)]))
    }

    func testAllLibraryRowsIsTrueWhenEveryRowIsLibrary() {
        XCTAssertTrue(allLibraryRows([row(1, .library), row(2, .library)]))
    }

    func testAddIndexCatalogRowAlwaysGoesToTheCatalogPath() {
        XCTAssertEqual(addIndexRoute(origin: .catalog, hasTargets: false), .catalog)
        XCTAssertEqual(addIndexRoute(origin: .catalog, hasTargets: true), .catalog)
    }

    func testAddIndexLibraryRowWithNoTargetIsAlreadyOwned() {
        XCTAssertEqual(addIndexRoute(origin: .library, hasTargets: false), .alreadyInLibrary)
    }

    func testAddIndexLibraryRowWithTargetsDuplicates() {
        XCTAssertEqual(addIndexRoute(origin: .library, hasTargets: true), .duplicateIntoPlaylists)
    }
}
