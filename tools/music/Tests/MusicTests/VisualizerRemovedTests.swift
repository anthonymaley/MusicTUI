import XCTest
@testable import music

/// Anthony's ruling (2026-11-01): the visualizer goes. Music draws it only in
/// its own window, so it cannot work inside the terminal.
final class VisualizerRemovedTests: XCTestCase {

    func testTheCLIHasNoVisualizerCommand() {
        let names = Music.configuration.subcommands.map { $0.configuration.commandName ?? String(describing: $0) }
        XCTAssertFalse(names.contains("visualizer"), "music visualizer is removed")
    }

    /// The Output tab ends at the EQ block: no Visualizer row after it.
    func testTheOutputTabEndsAtTheEQBlock() {
        XCTAssertEqual(outputTabRows(speakerCount: 1, expanded: false, presetNames: []).last, .eq)
        XCTAssertEqual(outputTabRows(speakerCount: 0, expanded: true, presetNames: ["Nightclub", "Manual"]).last,
                       .preset("Manual"))
    }
}
