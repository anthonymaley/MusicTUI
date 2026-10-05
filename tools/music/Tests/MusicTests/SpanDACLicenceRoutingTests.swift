// tools/music/Tests/MusicTests/SpanDACLicenceRoutingTests.swift
//
// SpanDAC's licence on the routing seam (design section 7; score M2, tests 15
// and 16). While the Mac's SpanDAC says it is not serving, it is treated as not
// installed IN MEMORY: data is open, a Mac SpanDAC output is the MusicTUI
// output, an iPhone/iPad output is refused, and neither stored file changes.
// A queue that was playing when serving ended keeps its transport keys until
// it ends or a new play replaces it.
//
// Every store is an explicit temp path and every client a fixture transport:
// nothing here reaches a socket, a player, the network or ~/.config/music
// (`HOME=` would not isolate it; NSHomeDirectory ignores it).
import XCTest
@testable import music

/// A coordinator over temp stores with one licence cache. The Mac's clients
/// (the `.source` output and the data client) are wrapped with
/// `observingLicence`, as `live` wraps them; a network client is not.
private final class LicenceRig {
    static let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"

    let dir: String
    let modes: PlaybackModeStore
    let data: DataProviderStore
    let cache = SpanDACServingCache()
    var modePath: String { (dir as NSString).appendingPathComponent("mode.json") }
    var dataPath: String { (dir as NSString).appendingPathComponent("data.json") }

    private let lock = NSLock()
    private var _sent: [(tag: String, line: String)] = []
    var sent: [(tag: String, line: String)] { lock.lock(); defer { lock.unlock() }; return _sent }
    /// The reply a client gives to `line`; the default is a paused status
    /// with no licence object.
    var reply: (_ tag: String, _ line: String) -> String = { _, _ in LicenceRig.status(playback: "paused") }

    init(output: PlaybackMode, accepted: Bool) {
        dir = NSTemporaryDirectory() + "music-licence-route-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
        XCTAssertTrue(modes.set(output))
        data = DataProviderStore(path: (dir as NSString).appendingPathComponent("data.json"))
        if accepted { XCTAssertTrue(data.accept()) }
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    func coordinator(_ surface: InvocationSurface = .tui, licensed: Bool = true) -> RoutingCoordinator {
        RoutingCoordinator(store: modes, surface: surface, dataStore: data,
                           makeSourceFor: { self.client(self.tag($0), observed: $0.networkSourceID == nil) },
                           makeDataClient: { self.client("mac-data", observed: true) },
                           starter: NeverStartsMacSpanDAC(),
                           licence: licensed ? cache : nil)
    }

    func tag(_ mode: PlaybackMode) -> String {
        mode.networkSourceID.map { "output:\($0)" } ?? "output:\(mode.storedValue)"
    }

    private func client(_ tag: String, observed: Bool) -> SourceAppClient {
        let fixture: (String, String) throws -> String = { [self] _, line in
            lock.lock(); _sent.append((tag, line)); lock.unlock()
            return reply(tag, line)
        }
        return SourceAppClient(path: "/nonexistent/\(tag)",
                               transport: observed ? observingLicence(fixture, cache: cache) : fixture)
    }

    func bytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    // MARK: fixture lines

    static func status(playback: String, phase: String? = nil, serving: Bool? = nil) -> String {
        var body = #""playback":"\#(playback)","authorization":"authorized","contract":3,"capabilities":[]"#
        if let phase { body += #","queue":{"phase":"\#(phase)"}"# }
        if let serving {
            let state = serving ? "licensed" : "none"
            body += #","licence":{"serving":\#(serving),"state":"\#(state)","text":"Licence text."}"#
        }
        return #"{"ok":true,"status":{\#(body)}}"#
    }

    static func failure(_ kind: String, op: String = "slice.next") -> String {
        #"{"ok":false,"op":"\#(op)","error":{"kind":"\#(kind)","detail":"Refused."}}"#
    }

    /// What SpanDAC says, as if a status read went by.
    func says(serving: Bool, playback: String = "paused", phase: String? = nil) {
        cache.observe(replyLine: Self.status(playback: playback, phase: phase, serving: serving))
    }
}

final class SpanDACLicenceRoutingTests: XCTestCase {

    private let ipad = LicenceRig.ipad
    private let outputs: [PlaybackMode] = [.musicApp, .source, .networkSource(LicenceRig.ipad)]

    private func run(_ c: RoutingCoordinator, _ action: MusicTUIAction, _ log: BranchLog,
                     origin: PlayOrigin? = nil,
                     send: @escaping (SourceAppClient) throws -> Void = { try $0.control.next() }) throws {
        try c.perform(action, expecting: nil, origin: origin,
                      musicApp: { log.append("musicApp:\($0)") },
                      source: { client in try send(client); log.append("source") },
                      unaffected: { log.append("unaffected") })
    }

    // MARK: - Test 15: not serving is "not installed", in memory only

    /// Each stored pair: not serving overrides the selection, both files keep
    /// their bytes, and serving again restores exactly the stored selection.
    func testNotServingOverridesEveryStoredPairAndServingAgainRestoresIt() {
        for output in outputs {
            for accepted in [false, true] {
                let rig = LicenceRig(output: output, accepted: accepted)
                let modeBefore = rig.bytes(rig.modePath), dataBefore = rig.bytes(rig.dataPath)
                let stored = effectiveSelection(data: rig.data, modes: rig.modes)
                let c = rig.coordinator()
                let label = "\(output) accepted=\(accepted)"

                rig.says(serving: true)
                XCTAssertEqual(c.selection, stored, label)

                rig.says(serving: false)
                let expected: EffectiveSelection = output.networkSourceID != nil
                    ? .outputBlocked(stored: output) : .consistent(data: .open, output: .musicApp)
                XCTAssertEqual(c.selection, expected, label)
                XCTAssertEqual(c.data, .open, label)
                XCTAssertEqual(c.mode, output, "the stored output is unchanged in memory too: \(label)")
                XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, label)
                XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore, label)

                rig.says(serving: true)
                XCTAssertEqual(c.selection, stored, "serving again restores the stored selection: \(label)")
                XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, label)
                XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore, label)
            }
        }
    }

    /// Unknown serving (nothing observed yet) is today's behaviour exactly,
    /// and a coordinator without a cache never looks at one.
    func testUnknownServingAndNoCacheAreTodaysSelection() {
        for output in outputs {
            for accepted in [false, true] {
                let rig = LicenceRig(output: output, accepted: accepted)
                let stored = effectiveSelection(data: rig.data, modes: rig.modes)
                XCTAssertEqual(rig.coordinator().selection, stored)
                let unlicensed = rig.coordinator(licensed: false)
                rig.says(serving: false)
                XCTAssertEqual(unlicensed.selection, stored, "no cache: the licence is never read")
                XCTAssertNil(unlicensed.playOutMode)
            }
        }
    }

    /// A stored iPhone/iPad output while not serving: every sound action is
    /// refused with the one sentence, reads are open, nothing reaches any
    /// SpanDAC, and the files keep their bytes.
    func testNetworkOutputIsRefusedWithTheSentenceAndReadsAreOpen() throws {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
        let modeBefore = rig.bytes(rig.modePath), dataBefore = rig.bytes(rig.dataPath)
        let c = rig.coordinator()
        rig.says(serving: false)
        let sentBefore = rig.sent.count
        let log = BranchLog()

        for action: MusicTUIAction in [.playPause, .next, .seek, .stop] {
            XCTAssertThrowsError(try run(c, action, log)) {
                XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac, "\(action)")
            }
        }
        XCTAssertThrowsError(try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))) {
            XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac)
        }
        let read = try c.choose(.catalogSearch, musicApp: { "open" }, source: { _ in "spandac" })
        XCTAssertEqual(read.provider, "open")
        XCTAssertEqual(log.log, [])
        XCTAssertEqual(rig.sent.count, sentBefore, "nothing reached a SpanDAC")
        XCTAssertEqual(rig.bytes(rig.modePath), modeBefore)
        XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore)
    }

    /// A network output needs a POSITIVE serving read: unknown is refused
    /// with the same sentence (reads stay as today), a switch to one is
    /// refused before anything is touched, and serving true lets both through.
    func testNetworkOutputNeedsServingTrue() throws {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator()
        let log = BranchLog()

        XCTAssertThrowsError(try run(c, .playPause, log)) {
            XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac)
        }
        XCTAssertFalse(rig.sent.contains { $0.tag == "output:\(ipad)" })
        let read = try c.choose(.catalogSearch, musicApp: { "open" }, source: { $0.path })
        XCTAssertEqual(read.provider, "/nonexistent/mac-data", "unknown keeps today's SpanDAC data")

        rig.says(serving: true)
        try run(c, .playPause, log)
        XCTAssertEqual(log.log, ["source"])
        XCTAssertTrue(rig.sent.contains { $0.tag == "output:\(ipad)" })
    }

    func testSwitchingToANetworkOutputNeedsServingTrue() throws {
        let rig = LicenceRig(output: .musicApp, accepted: true)
        let c = rig.coordinator()
        let modeBefore = rig.bytes(rig.modePath)
        var touched = false
        let pause: (PlaybackMode) throws -> Bool = { _ in touched = true; return true }
        let drop: (PlaybackMode) throws -> Void = { _ in touched = true }

        for serving in [nil, false] as [Bool?] {
            if let serving { rig.says(serving: serving) }
            XCTAssertThrowsError(try c.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                                  pauseOutgoing: pause, dropQueue: drop)) {
                XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac)
            }
            XCTAssertFalse(touched)
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore)
        }
        rig.says(serving: true)
        XCTAssertEqual(try c.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                        pauseOutgoing: pause, dropQueue: drop),
                       .switched(to: .networkSource(ipad)))
    }

    /// `dataEpoch` moves once per flip of the serving VALUE: true to false,
    /// false to true, unknown to false. Unknown to true and repeats (a status
    /// or an `unlicensed` refusal saying the same) move nothing; the output
    /// epoch never moves.
    func testDataEpochMovesOncePerFlipNotOnRepeats() {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        let start = c.stamp

        rig.says(serving: true)
        XCTAssertEqual(c.dataEpoch, start.dataEpoch, "unknown to true is not a flip")
        rig.says(serving: true)
        XCTAssertEqual(c.dataEpoch, start.dataEpoch)

        rig.says(serving: false)
        XCTAssertEqual(c.dataEpoch, start.dataEpoch + 1)
        rig.says(serving: false)
        rig.cache.observe(replyLine: LicenceRig.failure("unlicensed"))
        XCTAssertEqual(c.dataEpoch, start.dataEpoch + 1, "a repeat moves nothing")

        rig.says(serving: true)
        XCTAssertEqual(c.dataEpoch, start.dataEpoch + 2)
        rig.cache.observe(replyLine: LicenceRig.failure("unlicensed", op: "slice.search"))
        XCTAssertEqual(c.dataEpoch, start.dataEpoch + 3, "an unlicensed refusal is a flip too")
        XCTAssertEqual(c.epoch, start.epoch, "the output epoch is never a licence's")

        let fresh = LicenceRig(output: .musicApp, accepted: false)
        let d = fresh.coordinator()
        let before = d.dataEpoch
        fresh.says(serving: false)
        XCTAssertEqual(d.dataEpoch, before + 1, "unknown to false is a flip")
    }

    /// A read made under one answer is dropped once the answer flips.
    func testAReadMadeBeforeAFlipPlaysNothing() throws {
        let rig = LicenceRig(output: .musicApp, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true)
        let read = try c.choose(.catalogSearch, musicApp: { "open" }, source: { _ in "spandac" })
        XCTAssertEqual(read.provider, "spandac")
        rig.says(serving: false)
        let log = BranchLog()
        XCTAssertThrowsError(try c.perform(.discoverTrackPlay, expecting: read.stamp,
                                           origin: .spandacCatalogue,
                                           musicApp: { log.append("musicApp:\($0)") },
                                           source: { _ in log.append("source") },
                                           unaffected: { log.append("unaffected") })) {
            XCTAssertEqual(($0 as? ActionError)?.message, sourceChangedNothingPlayed)
        }
        XCTAssertEqual(log.log, [])
    }

    /// Not serving with nothing playing out: Bridge is out of the picture and
    /// transport and plays go to the MusicTUI output's shipped path.
    func testNotServingWithNoQueueSendsTransportAndPlaysToMusicTUI() throws {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "paused", phase: "none")
        XCTAssertNil(c.playOutMode)
        let sentBefore = rig.sent.count
        let log = BranchLog()
        try run(c, .playPause, log)
        try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))
        XCTAssertEqual(log.log, ["musicApp:shipped", "musicApp:shipped"])
        XCTAssertEqual(rig.sent.count, sentBefore)
    }

    // MARK: - Composition: one status read, only when it matters

    func testPrimingReadsOnlyWhenSpanDACIsInvolvedAndTheSocketExists() {
        let cases: [(PlaybackMode, Bool, Bool, Bool)] = [   // output, accepted, socket, reads
            (.musicApp, false, true, false),
            (.musicApp, true, true, true),
            (.source, false, true, true),
            (.source, true, true, true),
            (.networkSource(ipad), true, true, true),
            (.source, true, false, false),
            (.musicApp, true, false, false),
        ]
        for (output, accepted, socket, reads) in cases {
            let rig = LicenceRig(output: output, accepted: accepted)
            let modeBefore = rig.bytes(rig.modePath), dataBefore = rig.bytes(rig.dataPath)
            let c = rig.coordinator()
            var count = 0
            let read = c.primeLicence(socketExists: { socket }, readStatus: {
                count += 1
                _ = try observingLicence({ _, _ in LicenceRig.status(playback: "idle", serving: false) },
                                         cache: rig.cache)("/nonexistent", #"{"op":"slice.status"}"#)
            })
            let label = "\(output) accepted=\(accepted) socket=\(socket)"
            XCTAssertEqual(read, reads, label)
            XCTAssertEqual(count, reads ? 1 : 0, label)
            XCTAssertEqual(rig.cache.snapshot().serving, reads ? false : nil, label)
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, label)
            XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore, label)
        }
        let rig = LicenceRig(output: .source, accepted: true)
        XCTAssertFalse(rig.coordinator(licensed: false).primeLicence(socketExists: { true }, readStatus: {
            XCTFail("a coordinator without a licence never reads")
        }))
        let failing = LicenceRig(output: .source, accepted: true)
        XCTAssertTrue(failing.coordinator().primeLicence(socketExists: { true },
                                                         readStatus: { throw SourceAppError.notRunning }))
        XCTAssertNil(failing.cache.snapshot().serving, "a failed read leaves serving unknown")
    }

    // MARK: - Test 16: serving ends mid-queue on Bridge

    private func playingOut() -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "playing", phase: "complete")
        XCTAssertNil(c.playOutMode)
        rig.says(serving: false, playback: "playing", phase: "complete")
        XCTAssertEqual(c.playOutMode, .source)
        return (rig, c)
    }

    /// Transport keeps reaching SpanDAC; the next new play goes to MusicTUI
    /// and ends the play-out, after which transport is MusicTUI's.
    func testPlayOutKeepsTransportOnSpanDACUntilANewPlay() throws {
        let (rig, c) = playingOut()
        let log = BranchLog()
        let sends: [(MusicTUIAction, (SourceAppClient) throws -> Void)] = [
            (.playPause, { try $0.control.pause() }),
            (.next, { try $0.control.next() }),
            (.previous, { try $0.control.previous() }),
            (.seek, { try $0.control.seek(byOffset: 30) }),
            (.stop, { try $0.control.stop() }),
        ]
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: false) }
        for (action, send) in sends { try run(c, action, log, send: send) }
        XCTAssertEqual(log.log, Array(repeating: "source", count: 5))
        XCTAssertEqual(rig.sent.map(\.tag), Array(repeating: "output:musictui_source", count: 5))
        XCTAssertEqual(c.playOutMode, .source)

        try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))
        XCTAssertEqual(log.log.last, "musicApp:shipped", "the new play goes to MusicTUI")
        XCTAssertNil(c.playOutMode)
        try run(c, .next, log)
        XCTAssertEqual(log.log.last, "musicApp:shipped")
        XCTAssertEqual(rig.sent.count, 5)
    }

    /// The CLI's `music now` follows a play-out too.
    func testNowStatusFollowsThePlayOut() throws {
        // A fresh CLI process meets the lapsed licence from unknown.
        let fresh = LicenceRig(output: .source, accepted: true)
        let c = fresh.coordinator(.cli)
        fresh.says(serving: false, playback: "playing", phase: "building")
        XCTAssertEqual(c.playOutMode, .source, "unknown to false mid-queue still plays out")
        let log = BranchLog()
        try run(c, .nowStatus, log, send: { _ = try $0.control.status() })
        XCTAssertEqual(log.log, ["source"])
        XCTAssertEqual(fresh.sent.map(\.tag), ["output:musictui_source"])
    }

    /// A status showing the queue over ends the play-out: `stopped`, `idle`,
    /// or queue phase `none`, seen by the cache or on the play-out's own reply.
    func testPlayOutEndsOnAStatusShowingTheQueueOver() throws {
        for (playback, phase) in [("stopped", "complete"), ("idle", "complete"), ("paused", "none")] {
            let (rig, c) = playingOut()
            rig.says(serving: false, playback: playback, phase: phase)
            XCTAssertNil(c.playOutMode, "\(playback)/\(phase) seen by the cache")
            let log = BranchLog()
            try run(c, .next, log)
            XCTAssertEqual(log.log, ["musicApp:shipped"])
        }
        // A network SpanDAC's replies never reach the Mac's cache, so this one
        // is ended by the play-out client's own reply alone.
        let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "playing", phase: "complete")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        rig.reply = { _, _ in LicenceRig.status(playback: "stopped", phase: "complete") }
        let log = BranchLog()
        try run(c, .stop, log, send: { try $0.control.stop() })
        XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)")
        XCTAssertTrue(rig.cache.snapshot().bridgeLoaded, "the Mac's cache did not see it")
        XCTAssertNil(c.playOutMode, "stopped on the play-out's own reply")
    }

    /// A transport reply `unlicensed` or `nothing_loaded` ends it.
    func testPlayOutEndsOnAnUnlicensedOrNothingLoadedReply() throws {
        for kind in ["unlicensed", "nothing_loaded"] {
            let (rig, c) = playingOut()
            rig.reply = { _, _ in LicenceRig.failure(kind) }
            XCTAssertThrowsError(try run(c, .next, BranchLog()), "the refusal still reaches the caller")
            XCTAssertNil(c.playOutMode, kind)
            let log = BranchLog()
            try run(c, .next, log)
            XCTAssertEqual(log.log, ["musicApp:shipped"], kind)
        }
    }

    /// Serving again ends the play-out and the stored Bridge output is live.
    func testPlayOutEndsWhenServingReturns() throws {
        let (rig, c) = playingOut()
        let epoch = c.dataEpoch
        rig.says(serving: true, playback: "playing", phase: "complete")
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.dataEpoch, epoch + 1)
        XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: .source))
        let log = BranchLog()
        try run(c, .next, log)
        XCTAssertEqual(log.log, ["source"])
    }

    /// A committed output switch pauses and drops the outgoing queue, so it
    /// ends the play-out too.
    func testACommittedSwitchEndsThePlayOut() throws {
        let (_, c) = playingOut()
        XCTAssertEqual(try c.switchMode(to: .musicApp, readiness: { .ready },
                                        pauseOutgoing: { _ in true }, dropQueue: { _ in }),
                       .switched(to: .musicApp))
        XCTAssertNil(c.playOutMode)
    }
}
