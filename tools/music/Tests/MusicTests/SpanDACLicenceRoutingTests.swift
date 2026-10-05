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
    /// Fed by the network output's replies only, as `live` feeds it.
    let queues = SpanDACOutputQueues()
    var modePath: String { (dir as NSString).appendingPathComponent("mode.json") }
    var dataPath: String { (dir as NSString).appendingPathComponent("data.json") }

    private let lock = NSLock()
    private var _sent: [(tag: String, line: String)] = []
    var sent: [(tag: String, line: String)] { lock.lock(); defer { lock.unlock() }; return _sent }
    /// The reply a client gives to `line`; the default is a paused status
    /// with no licence object.
    var reply: (_ tag: String, _ line: String) -> String = { _, _ in LicenceRig.status(playback: "paused") }
    /// When set, used instead of `reply`, and may throw as a transport does.
    var throwingReply: ((_ tag: String, _ line: String) throws -> String)?

    init(output: PlaybackMode, accepted: Bool) {
        dir = NSTemporaryDirectory() + "music-licence-route-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
        XCTAssertTrue(modes.set(output))
        data = DataProviderStore(path: (dir as NSString).appendingPathComponent("data.json"))
        if accepted { XCTAssertTrue(data.accept()) }
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    func coordinator(_ surface: InvocationSurface = .tui, licensed: Bool = true,
                     macAbsent: Bool = false) -> RoutingCoordinator {
        RoutingCoordinator(store: modes, surface: surface, dataStore: data,
                           makeSourceFor: { self.client(self.tag($0), observed: $0.networkSourceID == nil,
                                                        network: $0.networkSourceID) },
                           makeDataClient: { self.client("mac-data", observed: true) },
                           starter: NeverStartsMacSpanDAC(),
                           licence: licensed ? cache : nil,
                           outputQueues: licensed ? queues : nil,
                           macSpanDACAbsent: { macAbsent })
    }

    func tag(_ mode: PlaybackMode) -> String {
        mode.networkSourceID.map { "output:\($0)" } ?? "output:\(mode.storedValue)"
    }

    private func client(_ tag: String, observed: Bool, network: String? = nil) -> SourceAppClient {
        let fixture: (String, String) throws -> String = { [self] _, line in
            lock.lock(); _sent.append((tag, line)); lock.unlock()
            if let throwingReply { return try throwingReply(tag, line) }
            return reply(tag, line)
        }
        let transport: (String, String) throws -> String
        if observed { transport = observingLicence(fixture, cache: cache) }
        else if let network { transport = observingOutputQueue(fixture, sourceID: network, queues: queues) }
        else { transport = fixture }
        return SourceAppClient(path: "/nonexistent/\(tag)", transport: transport)
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

    /// The op a request line names.
    static func op(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["op"] as? String
    }

    /// A SpanDAC playing its queue until a `slice.pause` reaches it; every
    /// status after that says paused.
    static func pausesWhenAsked(serving: Bool?) -> (String, String) -> String {
        let lock = NSLock()
        var paused = false
        return { _, line in
            lock.lock(); defer { lock.unlock() }
            if op(line) == "slice.pause" { paused = true }
            return status(playback: paused ? "paused" : "playing", phase: "complete", serving: serving)
        }
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

    /// Precedence: the persisted-state repair block (a stored SpanDAC output
    /// with no accepted data) is decided FIRST, whatever the licence says; the
    /// iPhone/iPad licence refusal applies only where that block does not.
    /// Pinned for serving unknown and serving false, for an action and for a
    /// switch, with nothing touched.
    func testTheRepairBlockIsDecidedBeforeTheNetworkLicenceRefusal() throws {
        for serving in [nil, false] as [Bool?] {
            let label = "serving \(serving.map(String.init) ?? "unknown")"
            // A stored iPhone/iPad output, data never accepted: the repair block.
            let blocked = LicenceRig(output: .networkSource(ipad), accepted: false)
            let c = blocked.coordinator()
            if let serving { blocked.says(serving: serving) }
            for action: MusicTUIAction in [.playPause, .next] {
                XCTAssertThrowsError(try run(c, action, BranchLog()), label) {
                    XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC, "\(action) \(label)")
                }
            }
            XCTAssertThrowsError(try run(c, .libraryPlay, BranchLog(), origin: .openData(resultNumber: nil)), label) {
                XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC, label)
            }
            XCTAssertEqual(blocked.sent.count, 0, label)

            // A switch to an iPhone/iPad with data never accepted: the repair
            // refusal, before the licence one.
            let open = LicenceRig(output: .musicApp, accepted: false)
            let d = open.coordinator()
            if let serving { open.says(serving: serving) }
            var touched = false
            XCTAssertThrowsError(try d.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                                  pauseOutgoing: { _ in touched = true; return true },
                                                  dropQueue: { _ in touched = true })) {
                XCTAssertEqual(($0 as? ActionError)?.message, switchMusicTUIToSpanDACFirst, label)
            }
            XCTAssertFalse(touched, label)

            // Data accepted: no repair block, so the licence refusal applies.
            let accepted = LicenceRig(output: .networkSource(ipad), accepted: true)
            let e = accepted.coordinator()
            if let serving { accepted.says(serving: serving) }
            XCTAssertThrowsError(try run(e, .playPause, BranchLog()), label) {
                XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac, label)
            }
            let acceptedOpen = LicenceRig(output: .musicApp, accepted: true)
            let f = acceptedOpen.coordinator()
            if let serving { acceptedOpen.says(serving: serving) }
            XCTAssertThrowsError(try f.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                                  pauseOutgoing: { _ in true }, dropQueue: { _ in })) {
                XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac, label)
            }
        }
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

    /// Transport keeps reaching SpanDAC; the next new play first silences the
    /// play-out (a pause, then a status read confirming it is not playing),
    /// THEN goes to MusicTUI and ends the play-out, after which transport is
    /// MusicTUI's. Before finding 4 (Codex review 98) no source command was
    /// sent before the new play, so SpanDAC kept playing beside MusicTUI.
    func testPlayOutKeepsTransportOnSpanDACUntilANewPlayThatSilencesItFirst() throws {
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

        rig.reply = LicenceRig.pausesWhenAsked(serving: false)
        let serial = c.playSerial
        var sentWhenTheBodyRan: Int?
        try c.perform(.libraryPlay, expecting: nil, origin: .openData(resultNumber: nil),
                      musicApp: { sentWhenTheBodyRan = rig.sent.count; log.append("musicApp:\($0)") },
                      source: { _ in log.append("source") }, unaffected: { log.append("unaffected") })
        XCTAssertEqual(log.log.last, "musicApp:shipped", "the new play goes to MusicTUI")
        XCTAssertEqual(sentWhenTheBodyRan, 7, "the pause and its confirming status went BEFORE the new play")
        XCTAssertEqual(rig.sent.dropFirst(5).map(\.tag), ["output:musictui_source", "output:musictui_source"])
        XCTAssertEqual(rig.sent.dropFirst(5).map { LicenceRig.op($0.line) }, ["slice.pause", "slice.status"])
        XCTAssertEqual(c.playSerial, serial + 1)
        XCTAssertNil(c.playOutMode)
        try run(c, .next, log)
        XCTAssertEqual(log.log.last, "musicApp:shipped")
        XCTAssertEqual(rig.sent.count, 7)
    }

    /// The silence step fails (the pause is not confirmed by a status, or the
    /// status cannot be read): the new play is refused with a plain sentence,
    /// nothing plays on MusicTUI, the serial does not move, and the play-out
    /// keeps its transport.
    func testANewPlayThatCannotSilenceThePlayOutIsRefusedAndThePlayOutKept() throws {
        let replies: [(String, (String, String) throws -> String)] = [
            ("still playing", { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: false) }),
            ("status unreadable", { _, line in
                if LicenceRig.op(line) == "slice.status" { throw SourceAppError.notRunning }
                return #"{"ok":true}"#
            }),
        ]
        for (label, reply) in replies {
            let (rig, c) = playingOut()
            rig.throwingReply = reply
            let serial = c.playSerial
            let log = BranchLog()
            XCTAssertThrowsError(try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil)), label) {
                XCTAssertEqual(($0 as? ActionError)?.message,
                               "Couldn't confirm SpanDAC on this Mac paused; nothing was played on MusicTUI.", label)
                XCTAssertFalse((($0 as? ActionError)?.message ?? "").contains("Music.app"), label)
            }
            XCTAssertEqual(log.log, [], "nothing played on MusicTUI: \(label)")
            XCTAssertEqual(c.playSerial, serial, label)
            XCTAssertEqual(c.playOutMode, .source, "the play-out is kept: \(label)")
            XCTAssertEqual(rig.sent.map { LicenceRig.op($0.line) }.first, "slice.pause", label)
            rig.throwingReply = nil
            rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: false) }
            try run(c, .next, log)
            XCTAssertEqual(log.log, ["source"], "transport still reaches SpanDAC: \(label)")
        }
    }

    /// A play refused before its branch (here a SpanDAC row once data is open
    /// again) sends nothing to the play-out: only an admitted play silences it.
    func testAPlayRefusedBeforeItsBranchDoesNotTouchThePlayOut() throws {
        let (rig, c) = playingOut()
        let log = BranchLog()
        XCTAssertThrowsError(try run(c, .libraryPlay, log, origin: .spandacLibrary)) {
            XCTAssertEqual(($0 as? ActionError)?.message, sourceChangedNothingPlayed)
        }
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertEqual(c.playOutMode, .source)
    }

    // MARK: - Finding 5: network play-out needs the network output's own evidence

    /// A loaded Mac queue never grants an iPhone/iPad output play-out: the
    /// network output's own status said it was idle (or said nothing).
    func testAMacQueueNeverGrantsNetworkPlayOut() throws {
        for networkSays in [nil, "idle"] as [String?] {
            let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
            let c = rig.coordinator()
            rig.says(serving: true, playback: "playing", phase: "complete")
            if let networkSays {
                rig.reply = { _, _ in LicenceRig.status(playback: networkSays, phase: "none") }
                _ = try c.client(for: .networkSource(ipad)).control.status()
            }
            rig.says(serving: false, playback: "playing", phase: "complete")
            let label = "network said \(networkSays ?? "nothing")"
            XCTAssertNil(c.playOutMode, label)
            let sentBefore = rig.sent.count
            XCTAssertThrowsError(try run(c, .next, BranchLog()), label) {
                XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac, label)
            }
            XCTAssertEqual(rig.sent.count, sentBefore, "nothing reached the iPhone/iPad: \(label)")
        }
    }

    /// An idle Mac never denies it: the network output's own status showed
    /// its queue playing, so the reduction records play-out there, and a later
    /// Mac status showing the Mac idle does not end it.
    func testAnIdleMacDoesNotDenyNetworkPlayOut() throws {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        rig.says(serving: false, playback: "stopped", phase: "none")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad), "the Mac's queue says nothing about the iPhone/iPad")
        let log = BranchLog()
        try run(c, .next, log)
        XCTAssertEqual(log.log, ["source"])
        XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)")
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
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
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
    // MARK: - Codex review 100, finding 1: a new play replaces an iPhone/iPad play-out

    /// An iPhone/iPad output whose own queue was playing when the Mac stopped
    /// serving: a recorded play-out on that device. `accepted` false is the
    /// persisted-state repair block.
    private func networkPlayingOut(accepted: Bool = true) throws -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: accepted)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        return (rig, c)
    }

    /// Design section 7 (mid-song) and score M2: the next new play REPLACES
    /// an iPhone/iPad play-out and goes to MusicTUI, as it does for SpanDAC
    /// on this Mac. Inside the boundary, the device is paused and a status
    /// read through its own client confirms it is not playing, BEFORE the
    /// MusicTUI body runs; then the play-out is cleared and the serial moves.
    /// Before this, the play was refused with the licence sentence.
    func testANewPlayOverANetworkPlayOutSilencesTheDeviceThenGoesToMusicTUI() throws {
        let (rig, c) = try networkPlayingOut()
        rig.reply = LicenceRig.pausesWhenAsked(serving: nil)
        let sentBefore = rig.sent.count, serial = c.playSerial
        let log = BranchLog()
        var sentWhenTheBodyRan: Int?
        try c.perform(.libraryPlay, expecting: nil, origin: .openData(resultNumber: nil),
                      musicApp: { sentWhenTheBodyRan = rig.sent.count; log.append("musicApp:\($0)") },
                      source: { _ in log.append("source") }, unaffected: { log.append("unaffected") })
        XCTAssertEqual(log.log, ["musicApp:shipped"], "the new play goes to MusicTUI")
        XCTAssertEqual(sentWhenTheBodyRan, sentBefore + 2, "the pause and its confirming status went BEFORE the new play")
        XCTAssertEqual(rig.sent.dropFirst(sentBefore).map(\.tag), ["output:\(ipad)", "output:\(ipad)"],
                       "through the device's own client")
        XCTAssertEqual(rig.sent.dropFirst(sentBefore).map { LicenceRig.op($0.line) }, ["slice.pause", "slice.status"])
        XCTAssertEqual(c.playSerial, serial + 1)
        XCTAssertNil(c.playOutMode, "the play-out is replaced")
    }

    /// The device cannot be confirmed paused (still playing, or its status
    /// cannot be read): nothing plays on MusicTUI, the serial does not move,
    /// and the play-out keeps its transport. The sentence names the device
    /// generically and never says Music.app.
    func testANewPlayThatCannotSilenceANetworkPlayOutIsRefusedAndThePlayOutKept() throws {
        let replies: [(String, (String, String) throws -> String)] = [
            ("still playing", { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }),
            ("status unreadable", { _, line in
                if LicenceRig.op(line) == "slice.status" { throw SourceAppError.notRunning }
                return #"{"ok":true}"#
            }),
        ]
        for (label, reply) in replies {
            let (rig, c) = try networkPlayingOut()
            rig.throwingReply = reply
            let sentBefore = rig.sent.count, serial = c.playSerial
            let log = BranchLog()
            XCTAssertThrowsError(try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil)), label) {
                XCTAssertEqual(($0 as? ActionError)?.message,
                               "Couldn't confirm the iPhone/iPad SpanDAC paused; nothing was played on MusicTUI.", label)
                XCTAssertFalse((($0 as? ActionError)?.message ?? "").contains("Music.app"), label)
            }
            XCTAssertEqual(log.log, [], "nothing played on MusicTUI: \(label)")
            XCTAssertEqual(c.playSerial, serial, label)
            XCTAssertEqual(c.playOutMode, .networkSource(ipad), "the play-out is kept: \(label)")
            XCTAssertEqual(rig.sent.dropFirst(sentBefore).first.map { LicenceRig.op($0.line) }, "slice.pause", label)
            XCTAssertEqual(rig.sent.dropFirst(sentBefore).first?.tag, "output:\(ipad)", label)
            rig.throwingReply = nil
            rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
            try run(c, .next, log)
            XCTAssertEqual(log.log, ["source"], "transport still reaches the device: \(label)")
            XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)", label)
        }
    }

    /// A stale SpanDAC-origin row, and the persisted-state repair block, both
    /// refuse BEFORE anything reaches the playing device: only an admitted
    /// play silences it.
    func testAStaleRowOrTheRepairBlockRefusesBeforeTouchingANetworkPlayOut() throws {
        let (rig, c) = try networkPlayingOut()
        let sentBefore = rig.sent.count
        XCTAssertThrowsError(try run(c, .libraryPlay, BranchLog(), origin: .spandacLibrary)) {
            XCTAssertEqual(($0 as? ActionError)?.message, sourceChangedNothingPlayed)
        }
        XCTAssertEqual(rig.sent.count, sentBefore, "a stale row touches nothing")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))

        let (blocked, d) = try networkPlayingOut(accepted: false)
        let blockedBefore = blocked.sent.count, serial = d.playSerial
        XCTAssertThrowsError(try run(d, .libraryPlay, BranchLog(), origin: .openData(resultNumber: nil))) {
            XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC)
        }
        XCTAssertEqual(blocked.sent.count, blockedBefore, "the repair block touches nothing")
        XCTAssertEqual(d.playSerial, serial)
        XCTAssertEqual(d.playOutMode, .networkSource(ipad))
    }

    // MARK: - Ruling A8: after a replacement, the sounding music is MusicTUI's to control

    /// A new play has replaced an iPhone/iPad play-out: returns the rig and
    /// coordinator with that play made on MusicTUI.
    private func replacedNetworkPlayOut() throws -> (LicenceRig, RoutingCoordinator) {
        let (rig, c) = try networkPlayingOut()
        rig.reply = LicenceRig.pausesWhenAsked(serving: nil)
        let log = BranchLog()
        try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))
        XCTAssertEqual(log.log, ["musicApp:shipped"])
        XCTAssertNil(c.playOutMode)
        return (rig, c)
    }

    /// Conductor ruling A8: once a new play has replaced an iPhone/iPad
    /// play-out, the music sounding is MusicTUI's, so every transport action
    /// (and Now) goes to the MusicTUI output, as it does for a stored Mac
    /// SpanDAC while not serving. New plays keep going there. Nothing reaches
    /// the device, and neither stored file is written. Before A8 these were
    /// refused with the iPhone/iPad licence sentence.
    func testAfterAReplacementTransportGoesToMusicTUI() throws {
        let (rig, c) = try replacedNetworkPlayOut()
        let modeBefore = rig.bytes(rig.modePath), dataBefore = rig.bytes(rig.dataPath)
        let sentBefore = rig.sent.count
        let log = BranchLog()
        for action: MusicTUIAction in [.playPause, .next, .previous, .seek, .stop, .nowStatus] {
            XCTAssertNoThrow(try run(c, action, log), "\(action)")
        }
        XCTAssertEqual(log.log, Array(repeating: "musicApp:shipped", count: 6))
        try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))
        XCTAssertEqual(log.log.last, "musicApp:shipped", "new plays keep going to MusicTUI")
        XCTAssertEqual(rig.sent.count, sentBefore, "nothing reached the device")
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
        XCTAssertEqual(c.mode, .networkSource(ipad), "the stored output is unchanged in memory")
        XCTAssertEqual(pollTarget(selection: c.selection, playOut: c.playOutMode), .musicApp,
                       "Now follows the MusicTUI output")
        XCTAssertEqual(rig.bytes(rig.modePath), modeBefore)
        XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore)
    }

    /// Serving again restores the stored iPhone/iPad selection, and the
    /// MusicTUI routing does not come back by itself when serving ends again.
    func testServingReturningRestoresTheStoredNetworkSelection() throws {
        let (rig, c) = try replacedNetworkPlayOut()
        rig.says(serving: true)
        XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: .networkSource(ipad)))
        rig.reply = { _, _ in LicenceRig.status(playback: "paused", phase: "complete") }
        let log = BranchLog()
        try run(c, .next, log)
        XCTAssertEqual(log.log, ["source"])
        XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)")

        rig.reply = { _, _ in LicenceRig.status(playback: "idle") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
        rig.says(serving: false)
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.selection, .outputBlocked(stored: .networkSource(ipad)),
                       "a later lapse with nothing playing is blocked as before")
        XCTAssertThrowsError(try run(c, .next, BranchLog())) {
            XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac)
        }
    }

    /// A committed output switch ends the MusicTUI routing a replacement set
    /// up; it does not survive on the stored output's side.
    func testACommittedSwitchClearsTheReplacement() throws {
        let (_, c) = try replacedNetworkPlayOut()
        XCTAssertEqual(c.replacedPlayOutMode, .networkSource(ipad))
        XCTAssertEqual(try c.switchMode(to: .musicApp, readiness: { .ready },
                                        pauseOutgoing: { _ in true }, dropQueue: { _ in }),
                       .switched(to: .musicApp))
        XCTAssertNil(c.replacedPlayOutMode)
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
    }

    /// Serving again clears it, and a NEW play-out that arises later on the
    /// device takes over: transport reaches the device again until the next
    /// new play replaces that one.
    func testANewPlayOutTakesOverFromAReplacement() throws {
        let (rig, c) = try replacedNetworkPlayOut()
        rig.says(serving: true)
        XCTAssertNil(c.replacedPlayOutMode, "serving again clears it")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
        rig.says(serving: false)
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        XCTAssertNil(c.replacedPlayOutMode)
        let log = BranchLog()
        try run(c, .next, log)
        XCTAssertEqual(log.log, ["source"])
        XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)")
    }

    /// The repair block is never overridden: with data not accepted, a
    /// replacement cannot happen, and nothing routes to MusicTUI around it.
    func testTheReplacementNeverOverridesTheRepairBlock() throws {
        let (rig, c) = try networkPlayingOut(accepted: false)
        let sentBefore = rig.sent.count
        XCTAssertThrowsError(try run(c, .libraryPlay, BranchLog(), origin: .openData(resultNumber: nil)))
        XCTAssertNil(c.replacedPlayOutMode)
        XCTAssertEqual(c.selection, .outputBlocked(stored: .networkSource(ipad)))
        XCTAssertEqual(rig.sent.count, sentBefore)
    }

    /// SpanDAC on this Mac proven absent (not running AND no socket) is
    /// evidence it is not playing, as it is for a switch: the new play goes
    /// ahead although no status could be read. Absence never speaks for an
    /// iPhone/iPad.
    func testEstablishedAbsenceSilencesAMacPlayOut() throws {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator(macAbsent: true)
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "playing", phase: "complete")
        XCTAssertEqual(c.playOutMode, .source)
        rig.throwingReply = { _, _ in throw SourceAppError.notRunning }
        let log = BranchLog()
        try run(c, .libraryPlay, log, origin: .openData(resultNumber: nil))
        XCTAssertEqual(log.log, ["musicApp:shipped"])
        XCTAssertNil(c.playOutMode)
    }

    // MARK: - Finding 8: the composition-time read is off the TUI's launch path

    /// The TUI composes promptly however slow SpanDAC's status is. Until the
    /// read lands, serving is unknown: an iPhone/iPad output is refused (it
    /// needs a positive read) and nothing reaches it; once the read lands,
    /// routing follows it.
    func testTheTUIPrimesOffTheLaunchPathAndStaysFailClosedUntilSettled() throws {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator(.tui)
        let release = DispatchSemaphore(value: 0)
        let primed = expectation(description: "the prime finished")
        let slow: (String, String) throws -> String = { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return LicenceRig.status(playback: "idle", serving: true)
        }
        let start = Date()
        c.primeLicenceAtComposition(socketExists: { true }, readStatus: {
            _ = try observingLicence(slow, cache: rig.cache)("/nonexistent", #"{"op":"slice.status"}"#)
        }, done: { primed.fulfill() })
        let waited = Date().timeIntervalSince(start)
        XCTAssertLessThan(waited, 1.0, "composition did not wait for the read: \(waited)s")
        XCTAssertNil(rig.cache.snapshot().serving)
        XCTAssertThrowsError(try run(c, .playPause, BranchLog())) {
            XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac)
        }
        XCTAssertFalse(rig.sent.contains { $0.tag == "output:\(ipad)" })

        release.signal()
        wait(for: [primed], timeout: 5)
        XCTAssertEqual(rig.cache.snapshot().serving, true)
        let log = BranchLog()
        try run(c, .playPause, log)
        XCTAssertEqual(log.log, ["source"])
        XCTAssertTrue(rig.sent.contains { $0.tag == "output:\(ipad)" })
    }

    /// An answer that lands inside the TUI's short launch wait routes the
    /// first action, as it did when the read was synchronous. A slower one
    /// leaves the one-action residual documented (and not yet measured) on
    /// `licencePrimeLaunchWaitMilliseconds`.
    func testAPromptAnswerLandsBeforeTheTUIComposes() {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator(.tui)
        c.primeLicenceAtComposition(socketExists: { true }, readStatus: {
            _ = try observingLicence({ _, _ in LicenceRig.status(playback: "idle", serving: false) },
                                     cache: rig.cache)("/nonexistent", #"{"op":"slice.status"}"#)
        })
        XCTAssertEqual(rig.cache.snapshot().serving, false)
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
    }

    /// A CLI command reads before its one action (bounded in `live`), and a
    /// TUI with nothing to read sends nothing.
    func testTheCLIPrimesBeforeReturningAndAnUninvolvedTUIReadsNothing() {
        let rig = LicenceRig(output: .source, accepted: true)
        var finished = false
        rig.coordinator(.cli).primeLicenceAtComposition(socketExists: { true }, readStatus: {
            _ = try observingLicence({ _, _ in LicenceRig.status(playback: "idle", serving: false) },
                                     cache: rig.cache)("/nonexistent", #"{"op":"slice.status"}"#)
        }, done: { finished = true })
        XCTAssertTrue(finished)
        XCTAssertEqual(rig.cache.snapshot().serving, false)

        let open = LicenceRig(output: .musicApp, accepted: false)
        let skipped = expectation(description: "the prime was skipped")
        open.coordinator(.tui).primeLicenceAtComposition(socketExists: { true }, readStatus: {
            XCTFail("nothing involves SpanDAC, so nothing is read")
        }, done: { skipped.fulfill() })
        wait(for: [skipped], timeout: 5)
        XCTAssertNil(open.cache.snapshot().serving)
    }
}
