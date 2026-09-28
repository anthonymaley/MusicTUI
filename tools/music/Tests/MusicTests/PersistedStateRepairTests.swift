// tools/music/Tests/MusicTests/PersistedStateRepairTests.swift
//
// C-REPAIR: a stored SpanDAC output with anything but
// the accepted data state is `outputBlocked`, and fails closed. Each fixture
// writes mode.json and data.json byte for byte as a crash, a downgrade, a hand
// edit or an older build could leave them, then proves, with a counting data
// factory, a counting output factory and an armed tripwire, that nothing
// reaches either SpanDAC or Apple's Music app, nothing plays on either output,
// and neither file is rewritten. Only a person's accept ends the block.
import XCTest
@testable import music

final class PersistedStateRepairTests: XCTestCase {

    private typealias Rig = DataRoutingRig
    private let ipad = DataRoutingRig.ipad

    private struct Fixture: CustomStringConvertible {
        let name: String
        let modeJSON: String
        let stored: PlaybackMode
        let dataJSON: String?
        var description: String { name }
    }

    /// Every data.json that is not the one accepted state, beside a Mac
    /// SpanDAC and a network SpanDAC output.
    private func fixtures() -> [Fixture] {
        let modes: [(String, PlaybackMode)] = [
            (#"{"mode":"musictui_source"}"#, .source),
            (#"{"mode":"spandac_network","target":"\#(ipad)"}"#, .networkSource(ipad)),
        ]
        let data: [(String, String?)] = [
            ("missing", nil),
            ("corrupt", "{ not json"),
            ("partial", #"{"data":"spandac_mac","cere"#),
            ("unknown", #"{"data":"from_the_future","ceremony":"accepted"}"#),
            ("explicit open", #"{"data":"open","ceremony":"accepted"}"#),
            ("declined", #"{"data":"open","ceremony":"declined"}"#),
            ("SpanDAC named but declined", #"{"data":"spandac_mac","ceremony":"declined"}"#),
            ("SpanDAC named but never shown", #"{"data":"spandac_mac","ceremony":"never_shown"}"#),
        ]
        return modes.flatMap { mode in
            data.map { Fixture(name: "\($0.0) beside \(mode.1)", modeJSON: mode.0, stored: mode.1, dataJSON: $0.1) }
        }
    }

    /// The sound actions C-REPAIR refuses: everything that touches playback,
    /// and the verbs C-MATRIX runs on the MusicTUI output. Transcribed from the
    /// score, not derived from the implementation.
    private let soundActions: Set<MusicTUIAction> = Set(MusicTUIAction.allCases.filter(\.touchesPlayback)).union([
        .playPause, .next, .previous, .seek, .stop, .volume, .persistentShuffleMode,
        .persistentRepeatMode, .queueJump, .quiet, .collectionShuffle, .cliPlayResume, .nowStatus,
        .airplayRoute, .eq, .visualizer, .genius, .loveTrack, .addCurrentTrackToPlaylist,
        .removeCurrentTrackFromPlaylist,
    ])

    private let origins: [PlayOrigin?] = [nil, .spandacLibrary, .spandacCatalogue, .spandacDiscoverContainer,
                                          .openData(resultNumber: 1)]

    /// Every entry point, every action, every origin.
    private func sweep(_ c: RoutingCoordinator, _ log: BranchLog) {
        for action in MusicTUIAction.allCases {
            _ = try? c.choose(action, musicApp: { log.append("open-provider:\(action)"); return 0 },
                              source: { _ in log.append("spandac-provider:\(action)"); return 1 })
            for origin in origins {
                try? c.perform(action, expecting: c.stamp, origin: origin,
                               musicApp: { _ in log.append("musicApp:\(action)") },
                               source: { _ in log.append("source:\(action)") },
                               unaffected: { log.append("unaffected:\(action)") })
            }
            try? c.perform(action, musicApp: { log.append("musicApp:\(action)") },
                           source: { _ in log.append("source:\(action)") },
                           unaffected: { log.append("unaffected:\(action)") })
        }
    }

    func testBlockedStateNeverConstructsASpanDACClientForAnyRead() {
        for fixture in fixtures() {
            for surface in InvocationSurface.allCases {
                let rig = Rig(modeJSON: fixture.modeJSON, dataJSON: fixture.dataJSON)
                let c = rig.coordinator(surface)
                XCTAssertEqual(c.selection, .outputBlocked(stored: fixture.stored), "\(fixture)")
                XCTAssertEqual(c.data, .open, "\(fixture)")
                let log = BranchLog()
                let (_, calls) = withTripwire { sweep(c, log) }
                XCTAssertEqual(calls, [], "\(fixture) \(surface)")
                XCTAssertEqual(rig.outputBuilt, [], "\(fixture) \(surface): an output client was built")
                XCTAssertEqual(rig.dataBuilt, 0, "\(fixture) \(surface): a data client was built")
                XCTAssertEqual(rig.sent.count, 0, "\(fixture) \(surface)")
                XCTAssertFalse(log.log.contains { $0.hasPrefix("source:") || $0.hasPrefix("spandac-provider:") },
                               "\(fixture) \(surface)")
                // Reads run the open column, as shipped.
                for action in MusicTUIAction.allCases
                where action.readsMusicData && !action.readsMusicAppCurrentTrack && action.surfaces.contains(surface) {
                    XCTAssertTrue(log.log.contains("open-provider:\(action)"), "\(fixture) \(surface): \(action)")
                }
            }
        }
    }

    func testBlockedStateNeverPlaysOnEitherOutput() {
        for fixture in fixtures() {
            for surface in InvocationSurface.allCases {
                let rig = Rig(modeJSON: fixture.modeJSON, dataJSON: fixture.dataJSON)
                let c = rig.coordinator(surface)
                let log = BranchLog()
                let (_, calls) = withTripwire { sweep(c, log) }
                XCTAssertEqual(calls, [])
                for action in soundActions {
                    XCTAssertFalse(log.log.contains { $0.hasSuffix(":\(action)") && !$0.hasPrefix("open-provider") },
                                   "\(fixture) \(surface): \(action) ran a branch")
                }
                XCTAssertEqual(rig.outputBuilt, [])
                XCTAssertEqual(rig.dataBuilt, 0)
            }
        }
    }

    func testBlockedStateRefusesSoundWithTheFinishSwitchingSentence() {
        XCTAssertEqual(finishSwitchingToSpanDAC,
                       "MusicTUI hasn't finished switching to SpanDAC. Open Output to finish, or stop using SpanDAC there.")
        for fixture in fixtures() {
            for surface in InvocationSurface.allCases {
                let c = Rig(modeJSON: fixture.modeJSON, dataJSON: fixture.dataJSON).coordinator(surface)
                for action in soundActions {
                    XCTAssertEqual(routeAction(action, selection: c.selection, from: surface).sound,
                                   .refused(finishSwitchingToSpanDAC), "\(fixture) \(surface): \(action)")
                    for origin in origins {
                        XCTAssertThrowsError(try c.perform(action, expecting: c.stamp, origin: origin,
                                                           musicApp: { _ in }, source: { _ in }, unaffected: {})) {
                            XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC, "\(action)")
                        }
                    }
                }
            }
        }
    }

    func testBlockedStateNeverRewritesEitherFile() {
        for fixture in fixtures() {
            let rig = Rig(modeJSON: fixture.modeJSON, dataJSON: fixture.dataJSON)
            let modeBefore = rig.bytes(rig.modePath)
            let dataBefore = rig.bytes(rig.dataPath)
            let c = rig.coordinator(outputLock: OutputLock(path: rig.modes.lockPath))
            let (_, calls) = withTripwire { sweep(c, BranchLog()) }
            XCTAssertEqual(calls, [])
            // Nothing switches by itself, and a switch is not the way out:
            // only accepting or stopping using SpanDAC ends the block.
            for target in [PlaybackMode.musicApp, .source, .networkSource(DataRoutingRig.other)] where target != fixture.stored {
                XCTAssertThrowsError(try c.switchMode(to: target, readiness: { .ready },
                                                      pauseOutgoing: { _ in XCTFail("paused"); return true },
                                                      dropQueue: { _ in XCTFail("dropped") })) {
                    XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC, "\(fixture) to \(target)")
                }
            }
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, "\(fixture): mode.json rewritten")
            XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore, "\(fixture): data.json rewritten")
            XCTAssertEqual(c.selection, .outputBlocked(stored: fixture.stored))
            XCTAssertEqual(c.epoch, 0)
            XCTAssertEqual(c.dataEpoch, 0)
        }
    }

    func testAcceptEndsTheBlockAndMakesTheStoredOutputLive() throws {
        for fixture in fixtures() {
            let rig = Rig(modeJSON: fixture.modeJSON, dataJSON: fixture.dataJSON)
            let modeBefore = rig.bytes(rig.modePath)
            let c = rig.coordinator(outputLock: OutputLock(path: rig.modes.lockPath))
            XCTAssertEqual(try c.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac), "\(fixture)")
            XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: fixture.stored), "\(fixture)")
            XCTAssertEqual(c.mode, fixture.stored)
            XCTAssertEqual(c.dataEpoch, 1)
            XCTAssertEqual(c.epoch, 0, "the stored output was never switched, only made live")
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, "\(fixture): accept leaves mode.json alone")
            XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.spandacMac, .accepted), "\(fixture)")

            let log = BranchLog()
            try c.perform(.next, expecting: c.stamp,
                          musicApp: { _ in log.append("musicApp") },
                          source: { _ = try? $0.control.next(); log.append("source") },
                          unaffected: { log.append("unaffected") })
            XCTAssertEqual(log.log, ["source"], "\(fixture)")
            XCTAssertEqual(rig.outputBuilt, [fixture.stored], "\(fixture): the stored output plays")
            XCTAssertEqual(rig.sent.map(\.tag), [rig.tag(fixture.stored)])
        }
    }

    /// An older build that knows nothing of data.json rewrote mode.json onto a
    /// SpanDAC output. The production composition reads data.json beside it,
    /// finds nothing accepted, and fails closed: no silent migration.
    func testADowngradedModeFileWithoutDataIsBlocked() throws {
        for (json, stored) in [(#"{"mode":"musictui_source"}"#, PlaybackMode.source),
                               (#"{"mode":"spandac_network","target":"\#(ipad)"}"#, .networkSource(ipad))] {
            let rig = Rig(modeJSON: json, dataJSON: nil)
            let live = RoutingCoordinator.live(store: rig.modes, surface: .tui, starter: NeverStartsMacSpanDAC())
            XCTAssertEqual(live.mode, stored)
            XCTAssertEqual(live.selection, .outputBlocked(stored: stored))
            XCTAssertEqual(live.data, .open)
            XCTAssertEqual(live.ceremony, .neverShown)
            let (_, calls) = try withTripwire {
                XCTAssertThrowsError(try live.perform(.playPause, expecting: live.stamp,
                                                      musicApp: { _ in XCTFail("played") },
                                                      source: { _ in XCTFail("played") },
                                                      unaffected: { XCTFail("ran") })) {
                    XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC)
                }
            }
            XCTAssertEqual(calls, [])
            XCTAssertNil(rig.bytes(rig.dataPath), "reading never writes data.json")
            XCTAssertEqual(rig.bytes(rig.modePath), Data(json.utf8), "mode.json keeps the stored output")
        }
    }

    /// The only accepted data state is BOTH `spandac_mac` and `accepted`. A
    /// file naming SpanDAC without an accepted ceremony, beside the MusicTUI
    /// output, is open data (column 1), never column 4.
    func testANonAcceptedSpanDACDataFileBesideTheMusicTUIOutputReadsOpen() throws {
        for dataJSON in [#"{"data":"spandac_mac","ceremony":"declined"}"#,
                         #"{"data":"spandac_mac","ceremony":"never_shown"}"#,
                         #"{"data":"spandac_mac","ceremony":"from_the_future"}"#] {
            let rig = Rig(modeJSON: #"{"mode":"music_app"}"#, dataJSON: dataJSON)
            let c = rig.coordinator()
            XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp), dataJSON)
            XCTAssertEqual(c.data, .open, dataJSON)
            let choice = try c.choose(.discoverFeed, musicApp: { "open" }, source: { _ in "spandac" })
            XCTAssertEqual(choice.provider, "open", dataJSON)
            XCTAssertEqual(rig.dataBuilt, 0, dataJSON)
        }
    }
}
