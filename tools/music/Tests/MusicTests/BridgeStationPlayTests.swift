import XCTest
@testable import music

/// Step 3: sending a station to Bridge.
///
/// A station is its own op rather than a widening of `slice.play`, whose
/// contract is one catalogue SONG. A station is a different item kind with
/// different semantics: endless, no queue, and confirmed by a rule of its own
/// because it plays tracks rather than itself.
final class BridgeStationPlayTests: XCTestCase {

    private final class Wire {
        private(set) var lines: [String] = []
        var reply = #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Aja","artist":"Steely Dan"}}"#

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return reply }
        }

        var bodies: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.transport)
    }

    func testPlayStationSendsTheOpAndTheStationID() throws {
        let wire = Wire()
        try control(wire).playStation(id: "ra.978194965", named: "Apple Music 1")

        let body = try XCTUnwrap(wire.bodies.first, "nothing was sent")
        XCTAssertEqual(body["op"] as? String, "slice.playStation")
        XCTAssertEqual(body["id"] as? String, "ra.978194965")
    }

    /// The name travels because the app cannot learn it for a station Apple's
    /// catalogue does not carry - and that is exactly the station whose refusal
    /// has to name it.
    func testTheDisplayNameTravelsForTheRefusalMessage() throws {
        let wire = Wire()
        try control(wire).playStation(id: "ra.1", named: "BBC Radio 1")

        let body = try XCTUnwrap(wire.bodies.first, "nothing was sent")
        XCTAssertEqual(body["name"] as? String, "BBC Radio 1")
    }

    /// A station is one request. It must not be confused with a queue.
    func testPlayStationNeverSendsQueueFields() throws {
        let wire = Wire()
        try control(wire).playStation(id: "ra.978194965", named: "Apple Music 1")

        let body = try XCTUnwrap(wire.bodies.first, "nothing was sent")
        XCTAssertNil(body["ids"])
        XCTAssertNil(body["rows"])
    }

    /// Ruling 17: an unresolvable station refuses, and the app's words reach the
    /// caller intact rather than being reduced to a label.
    func testAnUnresolvableStationRefusalKeepsItsOwnWords() {
        let wire = Wire()
        wire.reply = #"{"ok":false,"op":"slice.playStation","error":{"kind":"unresolvable","detail":"'BBC Radio 1' isn't in Apple Music's catalogue, so Bridge can't play it. Switch Output to Music.app to play this station."}}"#

        XCTAssertThrowsError(try control(wire).playStation(id: "ra.1", named: "BBC Radio 1")) { error in
            guard case SourceAppError.refused(let detail) = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertTrue(detail.contains("BBC Radio 1"), "got: \(detail)")
            XCTAssertTrue(detail.contains("Music.app"),
                          "the refusal must say where it CAN be played: \(detail)")
        }
    }
}
