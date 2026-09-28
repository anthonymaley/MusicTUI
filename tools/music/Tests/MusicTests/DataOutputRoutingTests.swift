// tools/music/Tests/MusicTests/DataOutputRoutingTests.swift
//
// Routing by two axes (score: data route and output, C-MATRIX, C-EPOCH,
// C-REPAIR). Where MusicTUI's music DATA comes from and where its SOUND goes
// are separate selections: `routeAction(_:selection:from:)` decides both, and
// `RoutingCoordinator` hands `choose` the DATA client and `perform` the OUTPUT
// client.
//
// Every store here is an explicit temp path, every client a counting fake, and
// no test reaches a real player, Apple's Music app, the network or
// ~/.config/music. `HOME=` would not isolate anything (NSHomeDirectory ignores
// it), so nothing here relies on it.
import XCTest
@testable import music

/// A coordinator over temp stores with counting factories. Each client's
/// transport records which client it is, so a test can tell the Mac's data
/// client from an output client by what reached it.
final class DataRoutingRig {
    static let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
    static let other = "6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91"
    static let statusReply = #"{"ok":true,"status":{"playback":"paused","authorization":"authorized","contract":3,"capabilities":[]}}"#

    let dir: String
    let modes: PlaybackModeStore
    let data: DataProviderStore
    var dataPath: String { (dir as NSString).appendingPathComponent("data.json") }
    var modePath: String { (dir as NSString).appendingPathComponent("mode.json") }

    private let lock = NSLock()
    private var _outputBuilt: [PlaybackMode] = []
    private var _dataBuilt = 0
    private var _sent: [(tag: String, line: String)] = []
    var outputBuilt: [PlaybackMode] { lock.lock(); defer { lock.unlock() }; return _outputBuilt }
    var dataBuilt: Int { lock.lock(); defer { lock.unlock() }; return _dataBuilt }
    var sent: [(tag: String, line: String)] { lock.lock(); defer { lock.unlock() }; return _sent }
    var dataFailure: Error?
    var outputFailure: Error?

    /// `accepted` writes the one accepted data state through the store;
    /// otherwise no data.json exists.
    init(output: PlaybackMode, accepted: Bool, dataStorePath: String? = nil) {
        dir = NSTemporaryDirectory() + "music-data-route-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
        modes.set(output)
        data = DataProviderStore(path: dataStorePath ?? (dir as NSString).appendingPathComponent("data.json"))
        if accepted { XCTAssertTrue(data.accept()) }
    }

    /// Raw files, byte for byte as another build (or a crash) left them:
    /// `dataJSON` nil means no data.json at all.
    init(modeJSON: String, dataJSON: String?) {
        dir = NSTemporaryDirectory() + "music-data-route-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let modePath = (dir as NSString).appendingPathComponent("mode.json")
        let dataPath = (dir as NSString).appendingPathComponent("data.json")
        try! modeJSON.write(toFile: modePath, atomically: true, encoding: .utf8)
        if let dataJSON { try! dataJSON.write(toFile: dataPath, atomically: true, encoding: .utf8) }
        modes = PlaybackModeStore(path: modePath)
        data = DataProviderStore(path: dataPath)
    }

    func coordinator(_ surface: InvocationSurface = .tui, outputLock: OutputLock? = nil) -> RoutingCoordinator {
        RoutingCoordinator(store: modes, surface: surface, outputLock: outputLock, dataStore: data,
                           makeSourceFor: { self.makeOutput($0) },
                           makeDataClient: { self.makeData() },
                           starter: NeverStartsMacSpanDAC())
    }

    func tag(_ mode: PlaybackMode) -> String {
        mode.networkSourceID.map { "output:\($0)" } ?? "output:\(mode.storedValue)"
    }

    private func makeOutput(_ mode: PlaybackMode) -> SourceAppClient {
        lock.lock(); _outputBuilt.append(mode); lock.unlock()
        return client(tag(mode), failure: { self.outputFailure })
    }

    private func makeData() -> SourceAppClient {
        lock.lock(); _dataBuilt += 1; lock.unlock()
        return client("mac-data", failure: { self.dataFailure })
    }

    private func client(_ tag: String, failure: @escaping () -> Error?) -> SourceAppClient {
        SourceAppClient(path: "/nonexistent/\(tag)", transport: { [self] _, line in
            lock.lock(); _sent.append((tag, line)); lock.unlock()
            if let error = failure() { throw error }
            return Self.statusReply
        })
    }

    func bytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

/// Which branch ran, in order.
final class BranchLog {
    private let lock = NSLock()
    private var _log: [String] = []
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    func append(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }
}

final class DataOutputRoutingTests: XCTestCase {

    private typealias Rig = DataRoutingRig
    private let ipad = DataRoutingRig.ipad

    // MARK: - The score's column 4, transcribed independently of routeAction

    /// C-MATRIX column 4 (`consistent(spandacMac, .musicApp)`), list by list as
    /// the score states it. Each action is in exactly one list.
    private let col4Reads: Set<MusicTUIAction> = [
        .discoverFeed, .discoverRefresh, .catalogSearch, .radioSearch, .radioCatalogueBrowse,
        .radioStationLookup, .recent, .rotation, .newReleases, .similar, .playlistListing,
        .searchLibrary, .libraryRetry,
    ]
    private let col4RefusedReads: Set<MusicTUIAction> = [
        .similarToCurrentTrack, .suggest, .suggestFromCurrentTrack, .newReleasesLikeCurrentTrack,
    ]
    private let col4ShippedSound: Set<MusicTUIAction> = [
        .playPause, .next, .previous, .seek, .stop, .volume, .persistentShuffleMode,
        .persistentRepeatMode, .queueJump, .quiet, .collectionShuffle, .cliPlayResume, .nowStatus,
        .airplayRoute, .eq, .visualizer, .genius, .loveTrack, .addCurrentTrackToPlaylist,
        .removeCurrentTrackFromPlaylist,
    ]
    private let col4LibraryManagement: Set<MusicTUIAction> = [.addToLibrary, .playlistWrite, .playlistShare, .cliMix]
    private let col4ChooseAndPlay: Set<MusicTUIAction> = [
        .libraryPlay, .playlistPlay, .discoverTrackPlay, .discoverPlayAll, .cliPlayIndex,
        .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong, .cliPlayArtist, .cliPlayCatalogSong,
    ]
    private let col4RefusedPlays: Set<MusicTUIAction> = [.cliPlayQuery, .playlistTemp]
    private let col4Local: Set<MusicTUIAction> = [
        .radioFavourite, .radioAddURL, .auth, .libraryArtistTierFilter, .playlistsOpenNowPlaying,
    ]

    /// The score's "`newReleases`, `similar` (CLI, as dispatched today)": on
    /// the CLI they follow today's SpanDAC dispatch, so `similar` is served and
    /// `new-releases` (refused on SpanDAC since Part 2 P8: no op serves its
    /// artist lookup) is refused on the data axis rather than falling back.
    private func col4ServesRead(_ action: MusicTUIAction, from surface: InvocationSurface) -> Bool {
        !(action == .newReleases && surface == .cli)
    }

    private let col1 = EffectiveSelection.consistent(data: .open, output: .musicApp)
    private let col4 = EffectiveSelection.consistent(data: .spandacMac, output: .musicApp)

    private func allSelections() -> [EffectiveSelection] {
        [
            col1,
            .outputBlocked(stored: .source), .outputBlocked(stored: .networkSource(ipad)),
            .consistent(data: .spandacMac, output: .source),
            .consistent(data: .spandacMac, output: .networkSource(ipad)),
            col4,
            // Unrepresentable through the stores (C-REPAIR); decided anyway.
            .consistent(data: .open, output: .source),
            .consistent(data: .open, output: .networkSource(ipad)),
        ]
    }

    private func run(_ c: RoutingCoordinator, _ action: MusicTUIAction, _ log: BranchLog,
                     origin: PlayOrigin? = nil,
                     expecting: (epoch: Int, dataEpoch: Int)? = nil) throws {
        try c.perform(action, expecting: expecting ?? c.stamp, origin: origin,
                      musicApp: { log.append("musicApp:\($0)") },
                      source: { client in _ = try? client.control.status(); log.append("source") },
                      unaffected: { log.append("unaffected") })
    }

    private func runOld(_ c: RoutingCoordinator, _ action: MusicTUIAction, _ log: BranchLog) throws {
        try c.perform(action,
                      musicApp: { log.append("musicApp") },
                      source: { client in _ = try? client.control.status(); log.append("source") },
                      unaffected: { log.append("unaffected") })
    }

    private func message(_ error: Error) -> String? { (error as? ActionError)?.message }

    // MARK: - Column 1

    /// Column 1 is exactly the shipped column: the sound axis is
    /// `routeAction(_:in: .musicApp, from:)` for every action on both
    /// surfaces, and data is open or not read at all.
    func testOpenDataColumnIsTheShippedColumn() throws {
        for surface in InvocationSurface.allCases {
            for action in MusicTUIAction.allCases {
                let routed = routeAction(action, selection: col1, from: surface)
                XCTAssertEqual(routed.sound, routeAction(action, in: .musicApp, from: surface), "\(action) \(surface)")
                XCTAssertTrue(routed.data == .open || routed.data == .none, "\(action) \(surface): \(routed.data)")
                if col4Reads.contains(action) || col4RefusedReads.contains(action) {
                    XCTAssertEqual(routed.data, .open, "\(action) is a read and reads open data")
                }
            }
        }
        // Through the coordinator: the same branch as the single-selection
        // coordinator ran, and every Music.app-side branch is the shipped body.
        for surface in InvocationSurface.allCases {
            let rig = Rig(output: .musicApp, accepted: false)
            let c = rig.coordinator(surface)
            XCTAssertEqual(c.selection, col1)
            for action in MusicTUIAction.allCases {
                let log = BranchLog()
                try run(c, action, log)
                let expected: String
                switch routeAction(action, in: .musicApp, from: surface) {
                case .musicApp: expected = "musicApp:shipped"
                case .unaffected: expected = "unaffected"
                case .source, .refused: expected = "unexpected"
                }
                XCTAssertEqual(log.log, [expected], "\(action) \(surface)")
            }
        }
    }

    // MARK: - Column 3

    /// Column 3: today's SpanDAC column on the sound axis, and every read from
    /// the Mac's own SpanDAC, never the network device, even when the output
    /// is an iPhone or iPad (Anthony, 09:44).
    func testSpanDACOutputColumnReadsAlwaysComeFromTheMac() throws {
        var readsChecked = 0
        for output in [PlaybackMode.source, .networkSource(ipad)] {
            let selection = EffectiveSelection.consistent(data: .spandacMac, output: output)
            for surface in InvocationSurface.allCases {
                let rig = Rig(output: output, accepted: true)
                let c = rig.coordinator(surface)
                XCTAssertEqual(c.selection, selection)
                for action in MusicTUIAction.allCases {
                    let routed = routeAction(action, selection: selection, from: surface)
                    XCTAssertEqual(routed.sound, routeAction(action, in: output, from: surface),
                                   "\(action) \(surface): the sound axis is today's SpanDAC column")
                    guard action.readsMusicData, routed.data == .spandacMac else { continue }
                    readsChecked += 1
                    let before = rig.sent.count
                    let choice = try c.choose(action, musicApp: { "open" },
                                              source: { client -> String in
                                                  _ = try? client.control.status(); return "spandac" })
                    XCTAssertEqual(choice.provider, "spandac", "\(action) \(surface)")
                    XCTAssertEqual(rig.sent.suffix(from: before).map(\.tag), ["mac-data"], "\(action) \(surface) on \(output)")
                    if routed.sound == .source {
                        let mark = rig.sent.count
                        try run(c, action, BranchLog())
                        XCTAssertEqual(rig.sent.suffix(from: mark).map(\.tag), ["mac-data"],
                                       "\(action) \(surface): a read performed on \(output) still reads the Mac")
                    }
                }
                XCTAssertEqual(rig.outputBuilt, [], "a read built an output client on \(output)")
            }
        }
        XCTAssertGreaterThan(readsChecked, 20)

        // Playback on column 3 still goes to the output's own client.
        let rig = Rig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator()
        try run(c, .next, BranchLog())
        XCTAssertEqual(rig.sent.map(\.tag), ["output:\(ipad)"])
        XCTAssertEqual(rig.dataBuilt, 0)
    }

    // MARK: - Column 4

    /// Column 4 reads come from the Mac's SpanDAC through `choose` and
    /// through `perform`, and never build an output client: the MusicTUI
    /// output has none.
    func testMusicTUIOutputWithSpanDACDataServesReadsFromSpanDAC() throws {
        for surface in InvocationSurface.allCases {
            let rig = Rig(output: .musicApp, accepted: true)
            let c = rig.coordinator(surface)
            XCTAssertEqual(c.selection, col4)
            XCTAssertEqual(c.data, .spandacMac)
            for action in col4Reads {
                let routed = routeAction(action, selection: col4, from: surface)
                guard action.surfaces.contains(surface) else {
                    // Unreachable from this surface: decided, not defaulted.
                    if case .refused(let why) = routed.data { XCTAssertFalse(why.isEmpty) }
                    else { XCTAssertEqual(routed.data, .spandacMac, "\(action) \(surface)") }
                    continue
                }
                guard col4ServesRead(action, from: surface) else {
                    XCTAssertEqual(routed.data, .refused(notAvailableWithSpanDACData), "\(action) \(surface)")
                    continue
                }
                XCTAssertEqual(routed.data, .spandacMac, "\(action) \(surface)")
                let mark = rig.sent.count
                let choice = try c.choose(action, musicApp: { "open" },
                                          source: { client -> String in
                                              _ = try? client.control.status(); return "spandac" })
                XCTAssertEqual(choice.provider, "spandac", "\(action) \(surface)")
                let log = BranchLog()
                try run(c, action, log)
                XCTAssertEqual(log.log, ["source"], "\(action) \(surface)")
                XCTAssertEqual(rig.sent.suffix(from: mark).map(\.tag), ["mac-data", "mac-data"], "\(action) \(surface)")
            }
            for action in col4RefusedReads {
                XCTAssertEqual(routeAction(action, selection: col4, from: surface).data,
                               .refused(notAvailableWithSpanDACData), "\(action) \(surface)")
            }
            XCTAssertEqual(rig.outputBuilt, [], "the MusicTUI output has no SpanDAC client")
        }
    }

    /// Transport and the current-track verbs act on the MusicTUI output as
    /// shipped: the shipped route, no data read, and the shipped body.
    func testMusicTUIOutputKeepsTransportAndCurrentTrackVerbs() throws {
        for surface in InvocationSurface.allCases {
            let rig = Rig(output: .musicApp, accepted: true)
            let c = rig.coordinator(surface)
            for action in col4ShippedSound {
                let routed = routeAction(action, selection: col4, from: surface)
                XCTAssertEqual(routed.sound, routeAction(action, in: .musicApp, from: surface), "\(action) \(surface)")
                XCTAssertEqual(routed.data, .none, "\(action) \(surface)")
                let log = BranchLog()
                try run(c, action, log)
                XCTAssertEqual(log.log, ["musicApp:shipped"], "\(action) \(surface)")
                let old = BranchLog()
                try runOld(c, action, old)
                XCTAssertEqual(old.log, ["musicApp"], "\(action) \(surface): the unchanged call sites keep working")
            }
            for action in col4LibraryManagement {
                XCTAssertEqual(routeAction(action, selection: col4, from: surface),
                               RoutedAction(data: .none, sound: routeAction(action, in: .musicApp, from: surface)),
                               "\(action): library management keeps its shipped body")
            }
            for action in col4Local {
                XCTAssertEqual(routeAction(action, selection: col4, from: surface),
                               RoutedAction(data: .none, sound: .unaffected), "\(action)")
            }
            XCTAssertEqual(rig.outputBuilt, [])
            XCTAssertEqual(rig.dataBuilt, 0, "no transport verb reads music data")
        }
    }

    /// Choose-and-play on the MusicTUI output with SpanDAC data takes the
    /// path of the ROW's origin: library to the hand-off, catalogue to the
    /// add, a Discover container to the container add. Anything else, free
    /// words included, refuses; so does every call site that names no origin
    /// (groups B and C ship refuse-all until the paths land).
    func testChooseAndPlayOnMusicTUIOutputTakesTheRowOriginsPath() throws {
        let origins: [(PlayOrigin?, MusicTUIPlayPath?)] = [
            (.spandacLibrary, .handoff),
            (.spandacCatalogue, .add),
            (.spandacDiscoverContainer, .addContainer),
            (nil, nil),
        ]
        for surface in InvocationSurface.allCases {
            let rig = Rig(output: .musicApp, accepted: true)
            let c = rig.coordinator(surface)
            for action in col4ChooseAndPlay {
                XCTAssertEqual(routeAction(action, selection: col4, from: surface),
                               RoutedAction(data: .spandacMac, sound: .musicApp), "\(action) \(surface)")
                for (origin, path) in origins {
                    let log = BranchLog()
                    if let path {
                        try run(c, action, log, origin: origin)
                        XCTAssertEqual(log.log, ["musicApp:\(path)"], "\(action) from \(String(describing: origin))")
                    } else {
                        XCTAssertThrowsError(try run(c, action, log, origin: origin)) {
                            XCTAssertEqual(self.message($0), pickASpanDACOutput, "\(action)")
                        }
                        XCTAssertEqual(log.log, [])
                    }
                }
                // A row read under open data and played after the switch.
                let stale = BranchLog()
                XCTAssertThrowsError(try run(c, action, stale, origin: .openData(resultNumber: 3))) {
                    XCTAssertEqual(self.message($0), surface == .cli
                                   ? resultFromBeforeSpanDACSwitch(3) : listFromBeforeSpanDACSwitch)
                }
                XCTAssertEqual(stale.log, [])
                // The unchanged call sites name no origin: refused.
                let old = BranchLog()
                XCTAssertThrowsError(try runOld(c, action, old)) {
                    XCTAssertEqual(self.message($0), pickASpanDACOutput)
                }
                XCTAssertEqual(old.log, [])
            }
            for action in col4RefusedPlays {
                for origin in [PlayOrigin.spandacLibrary, .spandacCatalogue, .spandacDiscoverContainer] {
                    let log = BranchLog()
                    XCTAssertThrowsError(try run(c, action, log, origin: origin)) {
                        XCTAssertEqual(self.message($0), pickASpanDACOutput, "\(action): free words never play")
                    }
                    XCTAssertEqual(log.log, [])
                }
            }
            XCTAssertEqual(rig.outputBuilt, [])
            XCTAssertEqual(rig.dataBuilt, 0, "the coordinator hands the path; the scene supplies the body")
        }
    }

    /// A station on the MusicTUI output plays by its share URL (looked up by
    /// id through the data provider when the row has none): the station path,
    /// never the SpanDAC output, never by name.
    func testStationPlayOnMusicTUIOutputRoutesByURL() throws {
        for surface in InvocationSurface.allCases {
            XCTAssertEqual(routeAction(.radioStationPlay, selection: col4, from: surface),
                           RoutedAction(data: .spandacMac, sound: .musicApp))
            let rig = Rig(output: .musicApp, accepted: true)
            let c = rig.coordinator(surface)
            for origin in [nil, PlayOrigin.spandacCatalogue, .spandacLibrary] {
                let log = BranchLog()
                try run(c, .radioStationPlay, log, origin: origin)
                XCTAssertEqual(log.log, ["musicApp:stationURL"], "\(String(describing: origin))")
            }
            // The shipped body is not the station path: refused until the
            // Radio and Discover call sites take it.
            let old = BranchLog()
            XCTAssertThrowsError(try runOld(c, .radioStationPlay, old)) {
                XCTAssertEqual(self.message($0), pickASpanDACOutput)
            }
            XCTAssertEqual(old.log, [])
            XCTAssertEqual(rig.outputBuilt, [])
        }
    }

    // MARK: - The whole matrix

    func testEveryActionIsDecidedInEveryColumn() {
        // The score's column-4 lists partition the closed set.
        let lists = [col4Reads, col4RefusedReads, col4ShippedSound, col4LibraryManagement,
                     col4ChooseAndPlay, col4RefusedPlays, [.radioStationPlay], col4Local]
        var seen: Set<MusicTUIAction> = []
        for list in lists {
            XCTAssertTrue(seen.isDisjoint(with: list), "an action is in two column-4 lists: \(seen.intersection(list))")
            seen.formUnion(list)
        }
        XCTAssertEqual(seen, Set(MusicTUIAction.allCases), "column 4 does not decide: \(Set(MusicTUIAction.allCases).subtracting(seen))")

        for selection in allSelections() {
            for surface in InvocationSurface.allCases {
                for action in MusicTUIAction.allCases {
                    let routed = routeAction(action, selection: selection, from: surface)
                    if case .refused(let why) = routed.sound {
                        XCTAssertFalse(why.isEmpty, "\(action) \(selection) \(surface)")
                        XCTAssertNotEqual(routed.data, .open, "\(action) \(selection): refused sound serves no data")
                        XCTAssertNotEqual(routed.data, .spandacMac, "\(action) \(selection): refused sound serves no data")
                    }
                    if case .refused(let why) = routed.data {
                        XCTAssertFalse(why.isEmpty, "\(action) \(selection) \(surface)")
                    }
                    switch selection {
                    case .consistent(.open, _), .outputBlocked:
                        XCTAssertNotEqual(routed.data, .spandacMac, "\(action): open data never reads SpanDAC")
                        XCTAssertNotEqual(routed.sound, .source, "\(action): nothing reaches a SpanDAC before accept")
                    case .consistent(.spandacMac, _):
                        XCTAssertNotEqual(routed.data, .open, "\(action): SpanDAC data never falls back to open")
                    }
                }
            }
        }
        // A SpanDAC output with open data cannot be committed; it routes as
        // blocked (fail closed), never as a working column.
        for output in [PlaybackMode.source, .networkSource(ipad)] {
            for surface in InvocationSurface.allCases {
                for action in MusicTUIAction.allCases {
                    XCTAssertEqual(routeAction(action, selection: .consistent(data: .open, output: output), from: surface),
                                   routeAction(action, selection: .outputBlocked(stored: output), from: surface),
                                   "\(action) \(surface)")
                }
            }
        }
    }

    /// DoD 7 with two selections: OPEN DATA never constructs a SpanDAC
    /// client, through any entry point, for any action, with any origin.
    func testOpenDataModeNeverConstructsASourceClient() throws {
        for surface in InvocationSurface.allCases {
            let rig = Rig(output: .musicApp, accepted: false)
            let c = rig.coordinator(surface)
            for action in MusicTUIAction.allCases {
                for origin in [nil, PlayOrigin.spandacLibrary, .spandacCatalogue, .spandacDiscoverContainer,
                               .openData(resultNumber: 1)] {
                    try? run(c, action, BranchLog(), origin: origin)
                }
                try? runOld(c, action, BranchLog())
                _ = try? c.choose(action, musicApp: { 0 }, source: { _ in 1 })
            }
            XCTAssertEqual(rig.outputBuilt, [], "\(surface)")
            XCTAssertEqual(rig.dataBuilt, 0, "\(surface)")
            XCTAssertEqual(rig.sent.count, 0, "\(surface)")
        }
    }

    /// No fallback on either axis: a failing SpanDAC read never becomes an
    /// open read, a refused read never runs the shipped body, a failing
    /// SpanDAC output never becomes the MusicTUI output, and an open read
    /// never becomes a SpanDAC read.
    func testNoFallbackOnEitherAxis() throws {
        // Data axis, column 4: the Mac fails; nothing open runs.
        let rig = Rig(output: .musicApp, accepted: true)
        rig.dataFailure = SourceAppError.notRunning
        let c = rig.coordinator(.cli)
        for action in col4Reads where col4ServesRead(action, from: .cli) {
            var openBuilt = false
            XCTAssertThrowsError(try c.choose(action, musicApp: { openBuilt = true; return 0 },
                                              source: { client -> Int in _ = try client.control.status(); return 1 }))
            XCTAssertFalse(openBuilt, "\(action)")
            let log = BranchLog()
            XCTAssertThrowsError(try c.perform(action, expecting: c.stamp,
                                               musicApp: { _ in log.append("musicApp") },
                                               source: { _ = try $0.control.status(); log.append("source") },
                                               unaffected: { log.append("unaffected") }))
            XCTAssertEqual(log.log, [], "\(action)")
        }
        for action in col4RefusedReads {
            var openBuilt = false
            XCTAssertThrowsError(try c.choose(action, musicApp: { openBuilt = true; return 0 }, source: { _ in 1 }))
            XCTAssertFalse(openBuilt, "\(action): no fallback to the web API")
        }

        // Sound axis, column 3: the selected SpanDAC fails; MusicTUI never plays.
        let out = Rig(output: .networkSource(ipad), accepted: true)
        out.outputFailure = SourceAppError.link(.asleep)
        let d = out.coordinator()
        for action in MusicTUIAction.allCases where action.touchesPlayback {
            let log = BranchLog()
            try? d.perform(action, expecting: d.stamp, origin: .spandacLibrary,
                           musicApp: { _ in log.append("musicApp") },
                           source: { try $0.control.pause(); log.append("source") },
                           unaffected: { log.append("unaffected") })
            XCTAssertEqual(log.log, [], "\(action)")
        }
        XCTAssertEqual(out.outputBuilt, [.networkSource(ipad)], "only the selected SpanDAC is ever built")

        // Column 1: an open read is never a SpanDAC read.
        let open = Rig(output: .musicApp, accepted: false)
        let e = open.coordinator()
        for action in MusicTUIAction.allCases where action.readsMusicData {
            var spandacBuilt = false
            _ = try? e.choose(action, musicApp: { 0 }, source: { _ in spandacBuilt = true; return 1 })
            XCTAssertFalse(spandacBuilt, "\(action)")
        }
    }

    // MARK: - C-EPOCH

    /// A play stamped before an OUTPUT switch refuses inside the boundary,
    /// before any branch runs.
    func testAStaleOutputEpochRefusesBeforeAnyBranchRuns() throws {
        let rig = Rig(output: .musicApp, accepted: true)
        let c = rig.coordinator()
        let stamp = c.stamp
        _ = try c.switchMode(to: .source, readiness: { .ready }, pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(c.epoch, stamp.epoch + 1)
        for action in [MusicTUIAction.next, .libraryPlay, .discoverTrackPlay, .radioStationPlay] {
            let log = BranchLog()
            XCTAssertThrowsError(try run(c, action, log, origin: .spandacLibrary, expecting: stamp)) {
                XCTAssertEqual(self.message($0), sourceChangedNothingPlayed, "\(action)")
            }
            XCTAssertEqual(log.log, [], "\(action)")
        }
        let log = BranchLog()
        try run(c, .next, log, expecting: c.stamp)
        XCTAssertEqual(log.log, ["source"], "a fresh stamp runs")
        XCTAssertEqual(rig.dataBuilt, 0)
    }

    /// A read-then-play whose read happened before the DATA source changed
    /// refuses inside the boundary, before any branch runs, and the choice
    /// carries the data epoch it was stamped with.
    func testAStaleDataEpochRefusesBeforeAnyBranchRuns() throws {
        let rig = Rig(output: .musicApp, accepted: false)
        let c = rig.coordinator()
        let choice = try c.choose(.discoverFeed, musicApp: { "open" }, source: { _ in "spandac" })
        XCTAssertEqual(choice.provider, "open")
        XCTAssertEqual(choice.dataEpoch, 0)
        XCTAssertTrue(choice.stamp == (epoch: 0, dataEpoch: 0))
        _ = try c.acceptSpanDACData(readiness: { .ready })
        XCTAssertEqual(c.dataEpoch, 1)
        XCTAssertEqual(c.epoch, 0, "accepting data is not an output switch")
        for action in [MusicTUIAction.next, .discoverTrackPlay, .libraryPlay] {
            let log = BranchLog()
            XCTAssertThrowsError(try run(c, action, log, origin: .spandacCatalogue, expecting: choice.stamp)) {
                XCTAssertEqual(self.message($0), sourceChangedNothingPlayed)
            }
            XCTAssertEqual(log.log, [], "\(action)")
        }
        let after = try c.choose(.discoverFeed, musicApp: { "open" }, source: { _ in "spandac" })
        XCTAssertEqual(after.provider, "spandac")
        XCTAssertEqual(after.dataEpoch, 1)
    }

    // MARK: - Accepting SpanDAC data

    func testAcceptRequiresTheMacSpanDACReady() {
        for readiness in [SourceReadiness.checking, .notRunning, .unavailable("SpanDAC needs Apple Music access")] {
            let rig = Rig(output: .musicApp, accepted: false)
            let c = rig.coordinator()
            var asked = 0
            XCTAssertThrowsError(try c.acceptSpanDACData(readiness: { asked += 1; return readiness })) {
                XCTAssertEqual(self.message($0),
                               "SpanDAC on this Mac is \(readiness.label); MusicTUI is still using its own music data.")
            }
            XCTAssertEqual(asked, 1, "readiness is read inside the boundary, once")
            XCTAssertNil(rig.bytes(rig.dataPath), "nothing was written")
            XCTAssertEqual(c.dataEpoch, 0)
            XCTAssertEqual(c.selection, col1)
        }
    }

    func testAcceptBumpsDataEpochOnceAndLeavesOutput() throws {
        let rig = Rig(output: .musicApp, accepted: false)
        let c = rig.coordinator()
        let modeBytes = rig.bytes(rig.modePath)
        XCTAssertEqual(try c.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        XCTAssertEqual(c.dataEpoch, 1)
        XCTAssertEqual(c.epoch, 0)
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(c.selection, col4)
        XCTAssertEqual(c.ceremony, .accepted)
        XCTAssertEqual(rig.bytes(rig.modePath), modeBytes, "the output is untouched")
        XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.spandacMac, .accepted))

        XCTAssertEqual(try c.acceptSpanDACData(readiness: { XCTFail("already accepted"); return .ready }),
                       .alreadySelected)
        XCTAssertEqual(c.dataEpoch, 1, "no second bump")
    }

    func testAFailedAcceptSaveChangesNothing() {
        let rig = Rig(output: .musicApp, accepted: false, dataStorePath: "/dev/null/cannot/data.json")
        let c = rig.coordinator()
        XCTAssertThrowsError(try c.acceptSpanDACData(readiness: { .ready })) {
            XCTAssertEqual(self.message($0), "Couldn't save the switch to SpanDAC; MusicTUI is still using its own music data.")
        }
        XCTAssertEqual(c.dataEpoch, 0)
        XCTAssertEqual(c.data, .open)
        XCTAssertEqual(c.selection, col1)
        XCTAssertEqual(c.ceremony, .neverShown)
    }

    /// A SpanDAC output with open data is unrepresentable in a committed
    /// state: the switch refuses before readiness, pause or drop.
    func testSwitchingToASpanDACOutputRefusesWithoutAcceptedData() throws {
        for target in [PlaybackMode.source, .networkSource(ipad)] {
            let rig = Rig(output: .musicApp, accepted: false)
            let c = rig.coordinator(outputLock: OutputLock(path: rig.modes.lockPath))
            let modeBytes = rig.bytes(rig.modePath)
            let log = BranchLog()
            XCTAssertThrowsError(try c.switchMode(to: target,
                                                  readiness: { log.append("readiness"); return .ready },
                                                  pauseOutgoing: { _ in log.append("pause"); return true },
                                                  dropQueue: { _ in log.append("drop") })) {
                XCTAssertEqual(self.message($0), "Switch MusicTUI to SpanDAC first. Still using MusicTUI.")
            }
            XCTAssertEqual(log.log, [])
            XCTAssertEqual(c.mode, .musicApp)
            XCTAssertEqual(c.epoch, 0)
            XCTAssertEqual(rig.bytes(rig.modePath), modeBytes)

            _ = try c.acceptSpanDACData(readiness: { .ready })
            XCTAssertEqual(try c.switchMode(to: target, readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in }),
                           .switched(to: target), "after accepting, the same switch goes ahead")
        }
    }

    // MARK: - The way back

    func testStopUsingSpanDACSwitchesOutputThenDataAndBumpsOnce() throws {
        // A SpanDAC output: the output moves first, through the normal
        // transaction, while data is still accepted; then data returns to open.
        let rig = Rig(output: .source, accepted: true)
        let c = rig.coordinator(outputLock: OutputLock(path: rig.modes.lockPath))
        let log = BranchLog()
        let result = try c.stopUsingSpanDACData(
            pauseOutgoing: { mode in
                log.append("pause \(mode)")
                XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.spandacMac, .accepted))
                return true
            },
            dropQueue: { mode in
                log.append("drop \(mode)")
                XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.spandacMac, .accepted),
                              "data is still SpanDAC while the output switches")
            })
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(log.log, ["pause source", "drop source"])
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(PlaybackModeStore(path: rig.modePath).mode(), .musicApp)
        XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.open, .declined))
        XCTAssertEqual(c.selection, col1)
        XCTAssertEqual(c.epoch, 1)
        XCTAssertEqual(c.dataEpoch, 1, "one bump for the whole stop")
        XCTAssertEqual(c.ceremony, .declined)

        // The MusicTUI output: nothing to pause; data alone returns.
        let tui = Rig(output: .musicApp, accepted: true)
        let d = tui.coordinator()
        XCTAssertEqual(try d.stopUsingSpanDACData(pauseOutgoing: { _ in XCTFail("nothing to pause"); return false },
                                                  dropQueue: { _ in XCTFail("nothing to drop") }), .stopped)
        XCTAssertEqual(d.epoch, 0)
        XCTAssertEqual(d.dataEpoch, 1)
        XCTAssertEqual(d.selection, col1)

        // Nothing to stop: no write, no bump.
        let fresh = Rig(output: .musicApp, accepted: false)
        let e = fresh.coordinator()
        XCTAssertEqual(try e.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in }), .alreadyOpen)
        XCTAssertEqual(e.dataEpoch, 0)
        XCTAssertNil(fresh.bytes(fresh.dataPath))
    }

    /// A network SpanDAC that does not answer: data still returns to open,
    /// the output stays blocked, the result says why, and a retry can finish.
    func testStopUsingSpanDACWithAnUnconfirmedPauseKeepsTheOutputBlocked() throws {
        let rig = Rig(output: .networkSource(ipad), accepted: true)
        let c = rig.coordinator()
        let result = try c.stopUsingSpanDACData(pauseOutgoing: { _ in false }, dropQueue: { _ in XCTFail("dropped") })
        XCTAssertEqual(result, .outputStillBlocked(why: "Couldn't confirm SpanDAC paused; still using it"))
        XCTAssertTrue(DataProviderStore(path: rig.dataPath).read() == (.open, .declined))
        XCTAssertEqual(PlaybackModeStore(path: rig.modePath).mode(), .networkSource(ipad))
        XCTAssertEqual(c.selection, .outputBlocked(stored: .networkSource(ipad)))
        XCTAssertEqual(c.dataEpoch, 1)
        XCTAssertEqual(c.epoch, 0)
        let log = BranchLog()
        XCTAssertThrowsError(try run(c, .next, log)) {
            XCTAssertEqual(self.message($0), finishSwitchingToSpanDAC)
        }
        XCTAssertEqual(log.log, [])

        // The person retries once the SpanDAC answers.
        XCTAssertEqual(try c.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in }), .stopped)
        XCTAssertEqual(c.selection, col1)
        XCTAssertEqual(c.dataEpoch, 2)
        XCTAssertEqual(c.epoch, 1)
    }

    // MARK: - Naming

    /// Every sentence the coordinator and the new columns produce names the
    /// non-SpanDAC output MusicTUI and never "Music.app".
    func testThePersonFacingOutputNameIsMusicTUI() throws {
        var sentences: [String] = []
        func collect(_ body: () throws -> Void) {
            do { try body(); XCTFail("expected a refusal") } catch { sentences.append(message(error) ?? "\(error)") }
        }
        // Switch refusals out of and into the MusicTUI output.
        let accepted = Rig(output: .musicApp, accepted: true).coordinator()
        collect { _ = try accepted.switchMode(to: .source, readiness: { .notRunning }, pauseOutgoing: { _ in true }, dropQueue: { _ in }) }
        collect { _ = try accepted.switchMode(to: .source, readiness: { .ready }, pauseOutgoing: { _ in false }, dropQueue: { _ in }) }
        collect { _ = try accepted.switchMode(to: .networkSource(ipad), readiness: { .unavailable("SpanDAC is asleep.") }, pauseOutgoing: { _ in true }, dropQueue: { _ in }) }
        collect { _ = try accepted.switchMode(to: .source, readiness: { .ready }, pauseOutgoing: { _ in true }, dropQueue: { _ in throw SourceAppError.notRunning }) }
        let unwritable = RoutingCoordinator(store: PlaybackModeStore(path: "/dev/null/cannot/mode.json"), surface: .tui,
                                            dataStore: DataProviderStore(path: Rig(output: .musicApp, accepted: true).dataPath),
                                            makeSourceFor: { _ in .failing(.notPaired) }, makeDataClient: { .failing(.notPaired) },
                                            starter: NeverStartsMacSpanDAC())
        _ = try? unwritable.acceptSpanDACData(readiness: { .ready })
        collect { _ = try unwritable.switchMode(to: .source, readiness: { .ready }, pauseOutgoing: { _ in true }, dropQueue: { _ in }) }
        let open = Rig(output: .musicApp, accepted: false).coordinator()
        collect { _ = try open.switchMode(to: .source, readiness: { .ready }, pauseOutgoing: { _ in true }, dropQueue: { _ in }) }
        collect { _ = try open.acceptSpanDACData(readiness: { .notRunning }) }
        XCTAssertTrue(sentences.contains("SpanDAC on this Mac is SpanDAC is not running; still using MusicTUI"), "\(sentences)")
        XCTAssertTrue(sentences.contains("Couldn't confirm MusicTUI paused; still using it"), "\(sentences)")
        XCTAssertTrue(sentences.contains("SpanDAC is asleep. Still using MusicTUI."), "\(sentences)")
        XCTAssertTrue(sentences.contains("Couldn't clear MusicTUI's queue; still using it"), "\(sentences)")
        XCTAssertTrue(sentences.contains { $0.hasPrefix("Couldn't save the playback mode; MusicTUI's queue was cleared, still using MusicTUI") },
                      "\(sentences)")

        // The new columns' refusals, and the TUI column's own reasons.
        for selection in allSelections() {
            for surface in InvocationSurface.allCases {
                for action in MusicTUIAction.allCases {
                    let routed = routeAction(action, selection: selection, from: surface)
                    // Column 3's CLI clause keeps D7's not-served sentences,
                    // which tests outside this step pin; the naming sweep owns them.
                    guard surface == .tui || !selection.isSpanDACOutputColumn else { continue }
                    if case .refused(let why) = routed.sound { sentences.append(why) }
                    if case .refused(let why) = routed.data { sentences.append(why) }
                }
            }
        }
        sentences += [finishSwitchingToSpanDAC, notAvailableWithSpanDACData, sourceChangedNothingPlayed,
                      switchMusicTUIToSpanDACFirst, listFromBeforeSpanDACSwitch, resultFromBeforeSpanDACSwitch(2),
                      currentTrackIsStaleInBridge]
        for sentence in Set(sentences) {
            XCTAssertFalse(sentence.contains("Music.app"), sentence)
        }
    }
}

private extension EffectiveSelection {
    /// Column 3, whose CLI clause keeps D7's not-served sentences for now.
    var isSpanDACOutputColumn: Bool {
        if case .consistent(.spandacMac, let output) = self { return output.usesSource }
        return false
    }
}
