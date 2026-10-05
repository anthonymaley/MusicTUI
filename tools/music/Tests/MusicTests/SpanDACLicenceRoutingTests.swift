// tools/music/Tests/MusicTests/SpanDACLicenceRoutingTests.swift
//
// SpanDAC's licence on the routing seam (design section 7; score M2, tests 15
// and 16). While the Mac's SpanDAC says it is not serving, it is treated as not
// installed IN MEMORY: data is open, a Mac SpanDAC output is the MusicTUI
// output, an iPhone/iPad output is refused, and neither stored file changes.
// A queue that was playing when serving ended keeps its transport keys until
// it ends or is stopped, and every new play is refused meanwhile, on every
// SpanDAC device (Anthony, 2026-10-05 15:06 and 16:07).
//
// Every store is an explicit temp path and every client a fixture transport:
// nothing here reaches a socket, a player, the network or ~/.config/music
// (`HOME=` would not isolate it; NSHomeDirectory ignores it).
import XCTest
@testable import music

/// A coordinator over temp stores with one licence cache. The Mac's clients
/// (the `.source` output and the data client) are wrapped with
/// `observingLicence`, as `live` wraps them; a network client is not.
/// Internal so `SpanDACLicenceEffectiveOutputTests` composes the same rig.
final class LicenceRig {
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
                     outputLock: Bool = false) -> RoutingCoordinator {
        RoutingCoordinator(store: modes, surface: surface,
                           outputLock: outputLock ? OutputLock(path: modes.lockPath) : nil, dataStore: data,
                           makeSourceFor: { self.client(self.tag($0), observed: $0.networkSourceID == nil,
                                                        network: $0.networkSourceID) },
                           makeDataClient: { self.client("mac-data", observed: true) },
                           starter: NeverStartsMacSpanDAC(),
                           licence: licensed ? cache : nil,
                           outputQueues: licensed ? queues : nil)
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

    /// Transport keeps reaching SpanDAC on this Mac, through its own client;
    /// a new play is REFUSED (Anthony, 2026-10-05 16:07), never a replacement:
    /// no pause is sent on its behalf, MusicTUI does not run, the serial does
    /// not move, and transport still reaches SpanDAC afterwards. Before the
    /// ruling the play paused SpanDAC and started MusicTUI (Codex review 98,
    /// finding 4), which Codex review 104 showed could still leave two
    /// players sounding.
    func testPlayOutKeepsTransportOnSpanDACAndANewPlayIsRefused() throws {
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

        // SpanDAC would confirm a pause, so a replacement could have gone ahead.
        rig.reply = LicenceRig.pausesWhenAsked(serving: false)
        let serial = c.playSerial
        XCTAssertThrowsError(try c.perform(.libraryPlay, expecting: nil, origin: .openData(resultNumber: nil),
                                           musicApp: { log.append("musicApp:\($0)") },
                                           source: { _ in log.append("source") },
                                           unaffected: { log.append("unaffected") })) {
            XCTAssertEqual(($0 as? ActionError)?.message, macPlayOutRefusal)
        }
        XCTAssertEqual(macPlayOutRefusal,
                       "SpanDAC for Mac is finishing its queue without a licence; stop it or let it end to play something new.")
        XCTAssertEqual(rig.sent.count, 5, "nothing was sent for the refused play")
        XCTAssertEqual(c.playSerial, serial)
        XCTAssertEqual(c.playOutMode, .source)
        try run(c, .next, log)
        XCTAssertEqual(log.log, Array(repeating: "source", count: 6), "MusicTUI never ran")
        XCTAssertEqual(rig.sent.map(\.tag), Array(repeating: "output:musictui_source", count: 6))
    }

    /// A play that would also be refused for another reason (here a SpanDAC
    /// row once data is open again) sends nothing to the play-out either: the
    /// play-out gate decides first, in its own sentence.
    func testAPlayRefusedBeforeItsBranchDoesNotTouchThePlayOut() throws {
        let (rig, c) = playingOut()
        let log = BranchLog()
        XCTAssertThrowsError(try run(c, .libraryPlay, log, origin: .spandacLibrary)) {
            XCTAssertEqual(($0 as? ActionError)?.message, macPlayOutRefusal)
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
    // MARK: - Design section 7, "Play-out on iPhone/iPad" (Anthony, 2026-10-05 15:06)

    /// An iPhone/iPad output whose own queue was playing when the Mac stopped
    /// serving: a recorded play-out on that device. `accepted` false is the
    /// persisted-state repair block.
    private func networkPlayingOut(accepted: Bool = true,
                                   _ surface: InvocationSurface = .tui) throws -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .networkSource(ipad), accepted: accepted)
        let c = rig.coordinator(surface)
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: .networkSource(ipad)).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        return (rig, c)
    }

    /// A new chosen play during an iPhone/iPad play-out is REFUSED with the
    /// one sentence, whatever the play and wherever its row came from:
    /// nothing is sent to the device, nothing starts on MusicTUI, the serial
    /// does not move, and the play-out keeps its transport. It never replaces
    /// the device's play-out, so two players at once cannot arise.
    func testANewPlayOverANetworkPlayOutIsRefusedAndStartsNoSecondPlayer() throws {
        let plays: [(InvocationSurface, MusicTUIAction)] = [
            (.tui, .libraryPlay), (.tui, .playlistPlay), (.tui, .discoverTrackPlay), (.tui, .discoverPlayAll),
            (.tui, .playlistTemp), (.tui, .radioStationPlay), (.cli, .cliPlaySong), (.cli, .cliPlayPlaylist),
        ]
        for (surface, action) in plays {
            for origin: PlayOrigin in [.openData(resultNumber: nil), .spandacLibrary] {
                let label = "\(surface) \(action) \(origin)"
                let (rig, c) = try networkPlayingOut(surface)
                let sentBefore = rig.sent.count, serial = c.playSerial
                let log = BranchLog()
                XCTAssertThrowsError(try run(c, action, log, origin: origin), label) {
                    XCTAssertEqual(($0 as? ActionError)?.message, iPhoneIPadNeedsLicensedMac, label)
                }
                XCTAssertEqual(iPhoneIPadNeedsLicensedMac, "iPhone/iPad SpanDAC needs SpanDAC for Mac, licensed.")
                XCTAssertEqual(log.log, [], "nothing started: \(label)")
                XCTAssertEqual(rig.sent.count, sentBefore, "nothing sent to the device: \(label)")
                XCTAssertEqual(c.playSerial, serial, label)
                XCTAssertEqual(c.playOutMode, .networkSource(ipad), "the play-out is kept: \(label)")
            }
        }
    }

    /// Transport during an iPhone/iPad play-out still reaches the device,
    /// through its own client, and never MusicTUI.
    func testTransportDuringANetworkPlayOutReachesTheDevice() throws {
        let (rig, c) = try networkPlayingOut()
        let log = BranchLog()
        let transport: [MusicTUIAction] = [.playPause, .next, .previous, .seek, .stop, .nowStatus]
        for action in transport {
            let sentBefore = rig.sent.count
            try run(c, action, log, send: { _ = try $0.control.status() })
            XCTAssertEqual(rig.sent.dropFirst(sentBefore).map(\.tag), ["output:\(ipad)"], "\(action)")
        }
        XCTAssertEqual(log.log, Array(repeating: "source", count: transport.count), "MusicTUI never ran")
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
    }

    /// The persisted-state repair block keeps its own sentence during an
    /// iPhone/iPad play-out, and touches nothing.
    func testTheRepairBlockKeepsItsSentenceDuringANetworkPlayOut() throws {
        let (rig, c) = try networkPlayingOut(accepted: false)
        let sentBefore = rig.sent.count, serial = c.playSerial
        XCTAssertThrowsError(try run(c, .libraryPlay, BranchLog(), origin: .openData(resultNumber: nil))) {
            XCTAssertEqual(($0 as? ActionError)?.message, finishSwitchingToSpanDAC)
        }
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.playSerial, serial)
        XCTAssertEqual(c.playOutMode, .networkSource(ipad))
        XCTAssertEqual(c.selection, .outputBlocked(stored: .networkSource(ipad)))
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
