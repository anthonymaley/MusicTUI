import XCTest
@testable import music

final class EQModelTests: XCTestCase {
    func testVenuePackShape() {
        XCTAssertEqual(VenuePack.all.count, 8)
        for p in VenuePack.all {
            XCTAssertEqual(p.bands.count, 10, p.name)
            XCTAssertTrue(p.bands.allSatisfy { (-12.0...12.0).contains($0) }, p.name)
            XCTAssertTrue((-12.0...12.0).contains(p.preamp), p.name)
        }
    }

    func testVenuePackNamesUnique() {
        let names = VenuePack.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains("Nightclub"))
        XCTAssertTrue(names.contains("Dungeon"))
    }

    func testSparklineBounds() {
        XCTAssertEqual(eqSparkline([Double](repeating: -12, count: 10)), "▁▁▁▁▁▁▁▁▁▁")
        XCTAssertEqual(eqSparkline([Double](repeating: 12, count: 10)), "██████████")
        // 0 dB maps to the middle of the 8-glyph ramp (index 4 of 0...7).
        XCTAssertEqual(eqSparkline([0]), "▅")
    }
}
