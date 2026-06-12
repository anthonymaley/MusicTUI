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

    private let presets = VenuePack.names + ["Acoustic", "Bass Booster", "Hip-Hop", "Manual"]

    func testResolverExactCaseInsensitive() {
        XCTAssertEqual(EQNameResolver.resolve("dungeon", in: presets), .match("Dungeon"))
        XCTAssertEqual(EQNameResolver.resolve("bass booster", in: presets), .match("Bass Booster"))
    }

    func testResolverPrefix() {
        XCTAssertEqual(EQNameResolver.resolve("night", in: presets), .match("Nightclub"))
    }

    func testResolverContainsAmbiguous() {
        XCTAssertEqual(EQNameResolver.resolve("club", in: presets),
                       .ambiguous(["Nightclub", "Jazz Club"]))
    }

    func testResolverNone() {
        XCTAssertEqual(EQNameResolver.resolve("xyzzy", in: presets), .none)
    }

    func testParseEQSnapshot() {
        let rs = "\u{1E}", us = "\u{1F}"
        let raw = "true\(rs)Nightclub\(rs)Manual\(us)Acoustic\(us)Nightclub"
        XCTAssertEqual(parseEQSnapshot(raw),
                       EQSnapshot(enabled: true, current: "Nightclub",
                                  presets: ["Manual", "Acoustic", "Nightclub"]))
    }

    func testParseEQSnapshotNoCurrent() {
        let rs = "\u{1E}", us = "\u{1F}"
        let raw = "false\(rs)\(rs)Manual\(us)Acoustic"
        let snap = parseEQSnapshot(raw)
        XCTAssertEqual(snap, EQSnapshot(enabled: false, current: nil,
                                        presets: ["Manual", "Acoustic"]))
    }

    func testParseEQSnapshotGarbage() {
        XCTAssertNil(parseEQSnapshot("not a snapshot"))
    }
}
