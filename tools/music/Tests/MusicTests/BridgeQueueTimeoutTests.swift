import XCTest
@testable import music

/// A queue request can legitimately take longer than a transport command:
/// Bridge may have to wait for the player to prepare the first song, and retry
/// that once after a cold start. Every queue request therefore goes over the
/// long-timeout transport, and transport commands keep the short one.
final class BridgeQueueTimeoutTests: XCTestCase {

    private final class Wire {
        private(set) var sentOnMain: [String] = []
        private(set) var sentOnLong: [String] = []
        func main(_ path: String, _ line: String) throws -> String {
            sentOnMain.append(line); return #"{"ok":true,"op":"x"}"#
        }
        func long(_ path: String, _ line: String) throws -> String {
            sentOnLong.append(line); return #"{"ok":true,"op":"slice.queue"}"#
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.main, libraryTransport: wire.long)
    }

    func testEveryQueueRequestUsesTheLongTimeout() throws {
        let wire = Wire()
        _ = try control(wire).queue(libraryIDs: ["i.a"])
        try control(wire).queue(catalogIDs: ["1"])
        try control(wire).queue(rows: [SourceLibraryRow(title: "t", artist: "a", album: "b")])
        XCTAssertEqual(wire.sentOnLong.count, 3)
        XCTAssertTrue(wire.sentOnLong.allSatisfy { $0.contains("\"slice.queue\"") })
        XCTAssertEqual(wire.sentOnMain.count, 0, "a queue request went over the short timeout")
    }

    func testTransportCommandsKeepTheShortTimeout() throws {
        let wire = Wire()
        try control(wire).pause()
        try control(wire).next()
        XCTAssertEqual(wire.sentOnMain.count, 2)
        XCTAssertEqual(wire.sentOnLong.count, 0)
    }

    func testTheLongTimeoutCoversAFailedPrepareAndOneRetry() {
        XCTAssertGreaterThanOrEqual(SourceAppControl.libraryReadTimeoutSeconds, 30)
    }
}
