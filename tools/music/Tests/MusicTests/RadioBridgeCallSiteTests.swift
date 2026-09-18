import XCTest
@testable import music

/// Step 3's call-site binding: Enter on a station consults the coordinator.
///
/// The same shape of test that step 2 needed. `ActionRoutingTests` already
/// proves `.radioStationPlay` routes to the source in Bridge mode; these prove
/// the Radio tab actually asks.
final class RadioBridgeCallSiteTests: XCTestCase {

    private final class Wire {
        private(set) var lines: [String] = []
        var reply = #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Aja","artist":"Steely Dan"}}"#
        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return reply }
        }
        var sent: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
    }

    /// Records what Music.app was asked to open, so "did not reach the other
    /// player" is asserted rather than assumed.
    private final class RecordingOpener: Opener {
        private(set) var opened: [String] = []
        func open(_ url: String) throws { opened.append(url) }
    }

    private let station = Station(id: "ra.978194965", name: "Apple Music 1",
                                  url: "https://music.apple.com/us/station/apple-music-1/ra.978194965",
                                  isLive: true, artworkURL: nil)

    private func scene(mode: PlaybackMode, wire: Wire, opener: Opener) -> RadioScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: wire.transport) })
        return RadioScene(routing: routing,
                          store: StationStore(path: NSTemporaryDirectory() + "stations-\(UUID().uuidString).json"),
                          catalog: nil, opener: opener)
    }

    /// The binding: in Bridge mode the station reaches the wire as its own op.
    func testStationPlayInBridgeModeSendsPlayStation() {
        let wire = Wire()
        let opener = RecordingOpener()
        let s = scene(mode: .source, wire: wire, opener: opener)

        s.execute(.play(station))

        XCTAssertEqual(wire.sent.first?["op"] as? String, "slice.playStation")
        XCTAssertEqual(wire.sent.first?["id"] as? String, "ra.978194965")
        XCTAssertTrue(opener.opened.isEmpty, "Bridge mode opened a music:// URL in Music.app")
    }

    /// And Music.app mode still opens the URL, so the test above cannot pass
    /// with the mode ignored entirely.
    func testStationPlayInMusicAppModeStillOpensTheURL() {
        let wire = Wire()
        let opener = RecordingOpener()
        let s = scene(mode: .musicApp, wire: wire, opener: opener)

        s.execute(.play(station))

        XCTAssertEqual(opener.opened.count, 1, "Music.app mode did not open the station URL")
        XCTAssertTrue(wire.sent.isEmpty, "Music.app mode sent a Bridge request")
    }

    /// Ruling 17: a station Apple's catalogue does not carry refuses, in the
    /// app's own words, and is never played on Music.app instead.
    func testAnUnresolvableStationRefusesWithoutFallingBack() {
        let wire = Wire()
        wire.reply = #"{"ok":false,"op":"slice.playStation","error":{"kind":"unresolvable","detail":"'BBC Radio 1' isn't in Apple Music's catalogue, so Bridge can't play it. Switch Output to Music.app to play this station."}}"#
        let opener = RecordingOpener()
        let s = scene(mode: .source, wire: wire, opener: opener)

        s.execute(.play(Station(id: "ra.1", name: "BBC Radio 1",
                                url: "https://music.apple.com/gb/station/bbc-radio-1/ra.1",
                                isLive: true, artworkURL: nil)))

        let message = s.message ?? ""
        XCTAssertTrue(message.contains("BBC Radio 1"), "got: \(message)")
        XCTAssertTrue(message.contains("Music.app"),
                      "the refusal must say where it CAN play: \(message)")
        XCTAssertTrue(opener.opened.isEmpty,
                      "a refused station was played on Music.app anyway — that is the fallback ruling 17 forbids")
    }
}
