// tools/music/Tests/MusicTests/RoutingReservationTests.swift
//
// The routing coordinator's two-phase seam (score discover-from-here, 1.6 and
// step CR). A long play takes a `RoutingReservation` in a short phase A inside
// `perform`, leaves the ordering boundary, and comes back through
// `whileReserved` for each bounded command.
//
// Every coordinator is built over explicit temp stores with counting fakes
// (`DataRoutingRig`). Nothing here reaches a real player, Apple's Music app, a
// socket or ~/.config/music. A competing thread is proven to have reached the
// boundary with `onReachingBoundary`, never with a sleep.
import XCTest
@testable import music

final class RoutingReservationTests: XCTestCase {

    private let reentry = "Internal error: a playback action started another inside itself"
    private var rigs: [DataRoutingRig] = []

    override func tearDown() {
        for rig in rigs { try? FileManager.default.removeItem(atPath: rig.dir) }
        rigs = []
        super.tearDown()
    }

    /// SpanDAC data on the MusicTUI output unless told otherwise.
    private func coordinator(output: PlaybackMode = .musicApp, accepted: Bool = true) -> RoutingCoordinator {
        let rig = DataRoutingRig(output: output, accepted: accepted)
        rigs.append(rig)
        return rig.coordinator()
    }

    private func message(_ error: Error?) -> String? { (error as? ActionError)?.message }

    /// A chosen-music play on the path phase A uses: a Discover container on
    /// the MusicTUI output with SpanDAC data.
    private func play(_ c: RoutingCoordinator,
                      expecting: (epoch: Int, dataEpoch: Int)? = nil,
                      _ branch: () throws -> Void = {}) throws {
        try c.perform(.discoverPlayAll, expecting: expecting ?? c.stamp, origin: .spandacDiscoverContainer,
                      musicApp: { _ in try branch() },
                      source: { _ in XCTFail("a MusicTUI-output play reached a SpanDAC") },
                      unaffected: { XCTFail("a play ran as unaffected") })
    }

    /// Phase A as a scene runs it: the reservation is taken inside the branch.
    private func reserve(_ c: RoutingCoordinator) throws -> RoutingReservation {
        var taken: RoutingReservation?
        try play(c) { taken = try c.reservationForThisBranch() }
        return try XCTUnwrap(taken)
    }

    private func switchOutput(_ c: RoutingCoordinator, to target: PlaybackMode) throws {
        XCTAssertEqual(try c.switchMode(to: target, readiness: { .ready },
                                        pauseOutgoing: { _ in true }, dropQueue: { _ in }),
                       .switched(to: target))
    }

    // MARK: - 1. reservationForThisBranch

    func testAReservationCarriesTheEpochsAndSerialOfItsOwnBranch() throws {
        let c = coordinator()
        // Move every counter off zero first, so equal-to-zero proves nothing.
        try switchOutput(c, to: .source)
        try switchOutput(c, to: .musicApp)
        try play(c)
        XCTAssertEqual(c.epoch, 2)
        XCTAssertEqual(c.playSerial, 1)

        let reservation = try reserve(c)
        XCTAssertEqual(reservation, RoutingReservation(epoch: 2, dataEpoch: 0, playSerial: 2),
                       "phase A's own perform moves the serial before its branch captures it")
        XCTAssertEqual(reservation.epoch, c.epoch)
        XCTAssertEqual(reservation.dataEpoch, c.dataEpoch)
        XCTAssertEqual(reservation.playSerial, c.playSerial)
    }

    func testAReservationOutsideAnyBranchThrowsTheReentryError() {
        let c = coordinator()
        XCTAssertThrowsError(try c.reservationForThisBranch()) {
            XCTAssertEqual(self.message($0), self.reentry)
        }
        // And again after a branch has run and returned on this thread: the
        // marker is gone with it.
        XCTAssertNoThrow(try play(c))
        XCTAssertThrowsError(try c.reservationForThisBranch()) {
            XCTAssertEqual(self.message($0), self.reentry)
        }
    }

    func testAReservationOnAnyOtherSelectionThrowsSourceChanged() throws {
        // Open data on the MusicTUI output: the shipped play.
        let open = coordinator(accepted: false)
        var openError: Error?
        var ran = 0
        try open.perform(.libraryPlay, expecting: open.stamp, origin: .openData(resultNumber: nil),
                         musicApp: { _ in
                             ran += 1
                             do { _ = try open.reservationForThisBranch() } catch { openError = error }
                         },
                         source: { _ in XCTFail("open data reached a SpanDAC") }, unaffected: {})
        XCTAssertEqual(message(openError), sourceChangedNothingPlayed)

        // SpanDAC data on a SpanDAC output.
        let spandac = coordinator(output: .source)
        var spandacError: Error?
        try spandac.perform(.libraryPlay, expecting: spandac.stamp, origin: .spandacLibrary,
                            musicApp: { _ in XCTFail("a SpanDAC-output play reached MusicTUI") },
                            source: { _ in
                                ran += 1
                                do { _ = try spandac.reservationForThisBranch() } catch { spandacError = error }
                            },
                            unaffected: {})
        XCTAssertEqual(message(spandacError), sourceChangedNothingPlayed)
        XCTAssertEqual(ran, 2, "both branches must have run for their refusals to mean anything")
    }

    // MARK: - 2. whileReserved

    func testAHeldReservationRunsItsBodyOnce() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        var ran = 0
        XCTAssertEqual(try c.whileReserved(reservation) { ran += 1 }, .holds)
        XCTAssertEqual(ran, 1)
        // A gate is not a play: it does not move the serial, so the next gate holds too.
        XCTAssertEqual(try c.whileReserved(reservation) { ran += 1 }, .holds)
        XCTAssertEqual(ran, 2)
    }

    func testABodysErrorPropagates() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        XCTAssertThrowsError(try c.whileReserved(reservation) { throw ActionError(message: "from the body") }) {
            XCTAssertEqual(self.message($0), "from the body")
        }
        // The boundary was released on the throwing exit.
        XCTAssertEqual(try c.whileReserved(reservation) {}, .holds)
    }

    func testACommittedOutputSwitchIsSourceChanged() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        try switchOutput(c, to: .source)
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran on a SpanDAC output") }, .sourceChanged)

        // Back on the MusicTUI output the selection reads the same, but the
        // epoch has moved twice: still not the reservation's instant.
        try switchOutput(c, to: .musicApp)
        XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: .musicApp))
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran after a switch away and back") },
                       .sourceChanged)
    }

    func testStoppingSpanDACDataIsSourceChanged() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        XCTAssertEqual(try c.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in }), .stopped)
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran on open data") }, .sourceChanged)

        // Accepted again: the same selection, a later data epoch.
        XCTAssertEqual(try c.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: .musicApp))
        XCTAssertEqual(c.epoch, reservation.epoch)
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran after data was stopped and re-accepted") },
                       .sourceChanged)
    }

    func testAnotherChosenMusicPlayReachingABranchSupersedes() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        try play(c)
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran after a newer play") }, .superseded)
    }

    func testATransportActionDoesNotSupersede() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        var transport = 0
        try c.perform(.playPause, expecting: c.stamp, origin: nil,
                      musicApp: { _ in transport += 1 }, source: { _ in }, unaffected: {})
        XCTAssertEqual(transport, 1)
        var ran = 0
        XCTAssertEqual(try c.whileReserved(reservation) { ran += 1 }, .holds)
        XCTAssertEqual(ran, 1)
    }

    func testAPerformRefusedByAStaleStampDoesNotMoveTheSerial() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        let stale = (epoch: c.epoch + 1, dataEpoch: c.dataEpoch)
        XCTAssertThrowsError(try play(c, expecting: stale) { XCTFail("a stale play ran") }) {
            XCTAssertEqual(self.message($0), sourceChangedNothingPlayed)
        }
        XCTAssertEqual(c.playSerial, reservation.playSerial)
        XCTAssertEqual(try c.whileReserved(reservation) {}, .holds)
    }

    func testBothMovedIsSourceChangedBecauseItIsCheckedFirst() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        try switchOutput(c, to: .source)
        try switchOutput(c, to: .musicApp)
        try play(c)
        XCTAssertNotEqual(c.epoch, reservation.epoch)
        XCTAssertNotEqual(c.playSerial, reservation.playSerial)
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran with both moved") }, .sourceChanged)
    }

    // MARK: - 3. The boundary is free between the phases

    func testTheBoundaryIsFreeBetweenThePhases() throws {
        let c = coordinator()
        let reservation = try reserve(c)

        // Phase A has returned and no gate has run: other threads get straight in.
        let chose = DispatchSemaphore(value: 0)
        var choice: ProviderChoice<Int>?
        DispatchQueue.global().async {
            choice = try? c.choose(.discoverFeed, musicApp: { 1 }, source: { _ in 2 })
            chose.signal()
        }
        XCTAssertEqual(chose.wait(timeout: .now() + 5), .success, "a choose waited on a play between its phases")
        XCTAssertEqual(choice?.provider, 2)
        XCTAssertEqual(choice?.epoch, reservation.epoch)

        let switched = DispatchSemaphore(value: 0)
        var result: RoutingCoordinator.SwitchResult?
        DispatchQueue.global().async {
            result = try? c.switchMode(to: .source, readiness: { .ready },
                                       pauseOutgoing: { _ in true }, dropQueue: { _ in })
            switched.signal()
        }
        XCTAssertEqual(switched.wait(timeout: .now() + 5), .success, "a switch waited on a play between its phases")
        XCTAssertEqual(result, .switched(to: .source))
        XCTAssertEqual(c.mode, .source)

        // And the play's next gate sees it.
        XCTAssertEqual(try c.whileReserved(reservation) { XCTFail("ran after the switch") }, .sourceChanged)
    }

    // MARK: - 4. A gate IS the boundary

    func testACompetingChooseWaitsForARunningGate() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        let log = BranchLog()
        let inBody = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let done = DispatchGroup()

        var check: RoutingReservationCheck?
        done.enter()
        DispatchQueue.global().async {
            check = try? c.whileReserved(reservation) {
                inBody.signal()
                releaseBody.wait()
                log.append("gate body returned")
            }
            done.leave()
        }
        XCTAssertEqual(inBody.wait(timeout: .now() + 5), .success, "the gate's body never started")

        let reached = DispatchSemaphore(value: 0)
        c.onReachingBoundary { reached.signal() }
        var choice: ProviderChoice<Int>?
        done.enter()
        DispatchQueue.global().async {
            choice = try? c.choose(.discoverFeed, musicApp: { 1 }, source: { _ in
                log.append("chose")
                return 2
            })
            done.leave()
        }
        // Positive handshake: the choose is at the boundary while the gate's
        // body still holds it, and it has not got in.
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success, "choose never reached the boundary")
        XCTAssertEqual(log.log, [], "the choose ran while a gate held the boundary")
        releaseBody.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        c.onReachingBoundary(nil)

        XCTAssertEqual(check, .holds)
        XCTAssertEqual(choice?.provider, 2)
        XCTAssertEqual(log.log, ["gate body returned", "chose"])
    }

    // MARK: - 5. The re-entry guard still throws

    func testCallsFromInsideAGateBodyThrowInsteadOfDeadlocking() throws {
        let c = coordinator()
        let reservation = try reserve(c)
        var performError: Error?, chooseError: Error?, gateError: Error?
        var innerRan = 0

        XCTAssertEqual(try c.whileReserved(reservation) {
            do {
                try c.perform(.playPause, expecting: nil, origin: nil,
                              musicApp: { _ in innerRan += 1 }, source: { _ in innerRan += 1 },
                              unaffected: { innerRan += 1 })
            } catch { performError = error }
            do {
                _ = try c.choose(.discoverFeed, musicApp: { innerRan += 1; return 1 },
                                 source: { _ in innerRan += 1; return 2 })
            } catch { chooseError = error }
            do { _ = try c.whileReserved(reservation) { innerRan += 1 } } catch { gateError = error }
        }, .holds)

        XCTAssertEqual(message(performError), reentry)
        XCTAssertEqual(message(chooseError), reentry)
        XCTAssertEqual(message(gateError), reentry)
        XCTAssertEqual(innerRan, 0, "nothing nested may run")
    }

    func testAGateCalledFromInsideAPerformBranchThrowsInsteadOfDeadlocking() throws {
        let c = coordinator()
        var gateError: Error?
        var innerRan = 0
        try play(c) {
            let reservation = try c.reservationForThisBranch()
            do { _ = try c.whileReserved(reservation) { innerRan += 1 } } catch { gateError = error }
        }
        XCTAssertEqual(message(gateError), reentry)
        XCTAssertEqual(innerRan, 0)

        // The outer gate's own re-entry error is what `whileReserved` throws.
        XCTAssertThrowsError(try play(c) {
            _ = try c.whileReserved(try c.reservationForThisBranch()) { innerRan += 1 }
        }) { XCTAssertEqual(self.message($0), self.reentry) }
        XCTAssertEqual(innerRan, 0)
    }

    // MARK: - 6. playSerial

    func testThePlaySerialMovesOncePerChosenMusicPlayThatReachesABranch() throws {
        // The MusicTUI output with SpanDAC data.
        let c = coordinator()
        XCTAssertEqual(c.playSerial, 0)
        try play(c)
        XCTAssertEqual(c.playSerial, 1)
        try play(c)
        XCTAssertEqual(c.playSerial, 2)

        // Not by transport, a read, a gate, or anything refused before a branch.
        try c.perform(.playPause, expecting: c.stamp, origin: nil,
                      musicApp: { _ in }, source: { _ in }, unaffected: {})
        try c.perform(.next, musicApp: {}, source: { _ in }, unaffected: {})
        _ = try c.choose(.discoverFeed, musicApp: { 1 }, source: { _ in 2 })
        _ = try c.whileReserved(RoutingReservation(epoch: c.epoch, dataEpoch: c.dataEpoch, playSerial: 2)) {}
        XCTAssertThrowsError(try play(c, expecting: (epoch: 9, dataEpoch: 9)))
        // A row from before the switch to SpanDAC data: the stale-origin rule.
        XCTAssertThrowsError(try c.perform(.libraryPlay, expecting: c.stamp, origin: .openData(resultNumber: nil),
                                           musicApp: { _ in XCTFail("a stale row played") },
                                           source: { _ in XCTFail("a stale row played") }, unaffected: {}))
        // A play the matrix refuses outright there.
        XCTAssertThrowsError(try c.perform(.playlistTemp, expecting: c.stamp, origin: .spandacLibrary,
                                           musicApp: { _ in XCTFail("a refused play ran") },
                                           source: { _ in XCTFail("a refused play ran") }, unaffected: {}))
        XCTAssertEqual(c.playSerial, 2)

        // A `.source` branch.
        let spandac = coordinator(output: .source)
        var sourceRan = 0
        try spandac.perform(.libraryPlay, expecting: spandac.stamp, origin: .spandacLibrary,
                            musicApp: { _ in XCTFail("a SpanDAC-output play reached MusicTUI") },
                            source: { _ in sourceRan += 1 }, unaffected: {})
        XCTAssertEqual(sourceRan, 1)
        XCTAssertEqual(spandac.playSerial, 1)

        // The shipped `.musicApp` branch, through both forms of `perform`.
        let open = coordinator(accepted: false)
        var shipped = 0
        try open.perform(.libraryPlay, expecting: open.stamp, origin: .openData(resultNumber: nil),
                         musicApp: { _ in shipped += 1 }, source: { _ in }, unaffected: {})
        XCTAssertEqual(open.playSerial, 1)
        try open.perform(.playlistPlay, musicApp: { shipped += 1 }, source: { _ in }, unaffected: {})
        XCTAssertEqual(shipped, 2)
        XCTAssertEqual(open.playSerial, 2)
    }
}
