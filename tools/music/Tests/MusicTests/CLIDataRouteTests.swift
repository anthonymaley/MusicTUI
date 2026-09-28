// tools/music/Tests/MusicTests/CLIDataRouteTests.swift
//
// Score: data route and output, step 6. The CLI obeys the same two
// selections as the TUI: where music DATA comes from (MusicTUI's own, or
// SpanDAC on this Mac) and where SOUND goes (the MusicTUI output, or a SpanDAC
// output), read from temp `mode.json` and `data.json` files through the
// production coordinator init that takes a data store.
//
// Every store, lock, cache and favourites file is under NSTemporaryDirectory();
// no default-path store, coordinator or starter is built. SpanDAC is two
// scripted wires (the Mac's data socket and the output), each counted; the
// external-call tripwire is armed around every command, so a test that
// reached AppleScript, REST or an app launch would record it. The MusicTUI
// output's own bodies are counting closures; nothing plays, sleeps or reads
// `~/.config/music`.
import ArgumentParser
import XCTest
@testable import music

/// What a test's `data.json` holds.
enum CLIDataFile {
    case missing, accepted, declined, explicitOpen, corrupt, unknownValue

    static let blocking: [CLIDataFile] = [.missing, .declined, .explicitOpen, .corrupt, .unknownValue]
}

/// Records every library play request the MusicTUI output was asked for, and
/// whether the output lock was held at that moment.
final class RecordingLibraryPlay: CLIMusicTUILibraryPlaying {
    private(set) var requests: [CLIMusicTUILibraryPlayRequest] = []
    private(set) var locked: [Bool] = []
    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws {
        requests.append(request)
        locked.append(!OutputLockTestSupport.isFree(env.routing.outputLock!.path))
    }
}

/// The catalogue counterpart of `RecordingLibraryPlay`.
final class RecordingCataloguePlay: CLIMusicTUICataloguePlaying {
    private(set) var requests: [CLIMusicTUICataloguePlayRequest] = []
    private(set) var locked: [Bool] = []
    func play(_ request: CLIMusicTUICataloguePlayRequest, env: CLIBridgeEnv) throws {
        requests.append(request)
        locked.append(!OutputLockTestSupport.isFree(env.routing.outputLock!.path))
    }
}

/// A starter that never launches anything and answers a fixed outcome.
final class CLIFakeMacStarter: MacSpanDACStarting {
    let outcome: MacSpanDACStartOutcome
    private(set) var starts = 0
    init(_ outcome: MacSpanDACStartOutcome) { self.outcome = outcome }
    var isInstalled: Bool { true }
    var isRunning: Bool { false }
    var isStarting: Bool { false }
    func ensureStarted() -> MacSpanDACStartOutcome { starts += 1; return outcome }
    func bringForward() {}
    func newAttempt() {}
}

/// A CLI env on both selections, with counted client factories.
final class CLIDataRouteHarness {
    let env: CLIBridgeEnv
    let io = CLIBridgeTestIO()
    let dataWire: BridgeLibraryReadsWire
    let outputWire: BridgeLibraryReadsWire
    let directory: String
    let library = RecordingLibraryPlay()
    let catalogue = RecordingCataloguePlay()
    private let counts = NSLock()
    private var _dataClients = 0
    private var _outputClients = 0
    var dataClientsBuilt: Int { counts.lock(); defer { counts.unlock() }; return _dataClients }
    var outputClientsBuilt: Int { counts.lock(); defer { counts.unlock() }; return _outputClients }
    var modePath: String { directory + "/mode.json" }
    var dataPath: String { directory + "/data.json" }

    /// `recordSeams` swaps the refusing production seams for recording ones.
    init(output: PlaybackMode, data: CLIDataFile,
         dataReplies: [String: [String]] = [:], outputReplies: [String: [String]] = [:],
         starter: MacSpanDACStarting = NeverStartsMacSpanDAC(),
         dataTransport: ((String, String) throws -> String)? = nil,
         recordSeams: Bool = true) {
        let dir = NSTemporaryDirectory() + "music-test-cli-data-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        directory = dir
        let store = PlaybackModeStore(path: dir + "/mode.json")
        precondition(store.set(output) && store.mode() == output, "the temp mode store must hold \(output)")
        let dataStore = DataProviderStore(path: dir + "/data.json")
        switch data {
        case .missing:      break
        case .accepted:     precondition(dataStore.accept())
        case .declined:     precondition(dataStore.decline())
        case .explicitOpen: try! Data(#"{"data":"open","ceremony":"never_shown"}"#.utf8).write(to: URL(fileURLWithPath: dir + "/data.json"))
        case .corrupt:      try! Data(#"{"data":"spandac_ma"#.utf8).write(to: URL(fileURLWithPath: dir + "/data.json"))
        case .unknownValue: try! Data(#"{"data":"spandac_cloud","ceremony":"accepted"}"#.utf8).write(to: URL(fileURLWithPath: dir + "/data.json"))
        }
        for path in [dir + "/mode.json", dir + "/data.json", store.lockPath] {
            precondition(isUnderTemporaryDirectory(path))
        }
        let dataWire = BridgeLibraryReadsWire(dataReplies)
        let outputWire = BridgeLibraryReadsWire(outputReplies)
        self.dataWire = dataWire
        self.outputWire = outputWire
        var bump: (Bool) -> Void = { _ in }
        let routing = RoutingCoordinator(
            store: store, surface: .cli, outputLock: OutputLock(path: store.lockPath),
            dataStore: dataStore,
            makeSourceFor: { _ in
                bump(false)
                return SourceAppClient(path: "/nonexistent/cli-data-output.sock", transport: outputWire.transport)
            },
            makeDataClient: {
                bump(true)
                return SourceAppClient(path: "/nonexistent/cli-data-mac.sock",
                                       transport: dataTransport ?? dataWire.transport)
            },
            starter: starter)
        let cache = ResultCache(directory: dir + "/cache")
        precondition(isUnderTemporaryDirectory(cache.directory))
        var env = CLIBridgeEnv(routing: routing, modeStore: store, cache: cache,
                               out: io.writeOut, err: io.writeErr, sleep: io.sleep)
        if recordSeams {
            env.libraryPlay = library
            env.cataloguePlay = catalogue
        }
        self.env = env
        bump = { [unowned self] isData in
            self.counts.lock()
            if isData { self._dataClients += 1 } else { self._outputClients += 1 }
            self.counts.unlock()
        }
    }

    func fileBytes() -> [Data?] {
        [FileManager.default.contents(atPath: modePath), FileManager.default.contents(atPath: dataPath)]
    }
}

/// A ready status with no DAC on this Mac: a DATA read must not care.
private let readyWithoutADAC =
    #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"output":{"dac":"not_connected"}}}"#

final class CLIDataRouteTests: XCTestCase {

    private typealias C = CLIBridgeCatalogueReplies
    private typealias L = CLIBridgeLibraryReplies
    private typealias Q = CLIBridgeRadioReplies

    private func tripwired(_ body: () throws -> Void) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire { do { try body() } catch { thrown = error } }.calls
        return (thrown, calls)
    }

    private func noMusicApp(file: StaticString = #filePath, line: UInt = #line) -> PlayMusicAppDeps {
        PlayMusicAppDeps(readSongs: { XCTFail("the shipped body read the cache", file: file, line: line); return [] },
                         resolveIndexed: { _, _ in XCTFail("the shipped body played", file: file, line: line) })
    }

    private func play(_ h: CLIDataRouteHarness, _ args: [String] = [], playlist: String? = nil, album: String? = nil,
                      song: String? = nil, artist: String? = nil, json: Bool = false) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runPlay(args: args, playlist: playlist, album: album, song: song, artist: artist, json: json,
                        env: h.env, musicAppDeps: noMusicApp())
        }
    }

    private func search(_ h: CLIDataRouteHarness, _ query: [String], library: Bool = false, json: Bool = false,
                        musicApp: @escaping () -> Void = { XCTFail("the shipped search ran") }) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runSearch(query: query, artist: nil, album: nil, types: "songs", library: library, limit: 10,
                          json: json, env: h.env, musicApp: { _, _, _, _, _, _, _ in musicApp() })
        }
    }

    private func cacheRows(_ h: CLIDataRouteHarness, _ rows: [SongResult]) throws {
        try h.env.cache.writeSongs(rows)
    }

    // MARK: - The matrix, every CLI verb, every column

    /// The four columns, and a network SpanDAC output for columns 2 and 3.
    private let columns: [(String, EffectiveSelection)] = [
        ("open data, MusicTUI", .consistent(data: .open, output: .musicApp)),
        ("blocked Mac", .outputBlocked(stored: .source)),
        ("blocked network", .outputBlocked(stored: .networkSource("D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"))),
        ("SpanDAC data, Mac output", .consistent(data: .spandacMac, output: .source)),
        ("SpanDAC data, network output", .consistent(data: .spandacMac, output: .networkSource("D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"))),
        ("SpanDAC data, MusicTUI", .consistent(data: .spandacMac, output: .musicApp)),
    ]

    /// Column 4 for every action a CLI verb reaches, written out by decision.
    private enum CLIColumn4 { case spandacRead, musicTUIShipped, musicTUIRowPath, refused(String), unaffected }

    private func column4(_ action: MusicTUIAction) -> CLIColumn4 {
        switch action {
        case .catalogSearch, .searchLibrary, .radioSearch, .radioStationLookup, .recent, .rotation,
             .similar, .playlistListing, .discoverFeed:
            return .spandacRead
        case .newReleases, .newReleasesLikeCurrentTrack, .suggest, .suggestFromCurrentTrack, .similarToCurrentTrack:
            return .refused(notAvailableWithSpanDACData)
        case .cliPlayQuery, .playlistTemp:
            return .refused(pickASpanDACOutput)
        case .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong, .cliPlayArtist, .cliPlayCatalogSong,
             .radioStationPlay:
            return .musicTUIRowPath
        case .radioAddURL, .auth:
            return .unaffected
        default:
            return .musicTUIShipped
        }
    }

    func testEveryCLIVerbIsClassifiedInEveryColumn() {
        let cliActions = MusicTUIAction.allCases.filter { $0.surfaces.contains(.cli) }
        XCTAssertFalse(cliActions.isEmpty)
        for action in cliActions {
            for (name, selection) in columns {
                let routed = routeAction(action, selection: selection, from: .cli)
                let gate = cliBridgeRefusal(action, selection: selection)
                switch selection {
                case .consistent(.open, .musicApp):
                    XCTAssertEqual(routed.sound, routeAction(action, in: .musicApp, from: .cli), "\(name) \(action)")
                    XCTAssertEqual(gate, cliBridgeRefusal(action, mode: .musicApp), "\(name) \(action)")
                    XCTAssertNotEqual(routed.data, .spandacMac, "\(name) \(action)")
                case .outputBlocked:
                    XCTAssertNotEqual(routed.sound, .source, "\(name) \(action): nothing reaches a SpanDAC")
                    XCTAssertNotEqual(routed.data, .spandacMac, "\(name) \(action)")
                    if action.touchesPlayback || musicTUIOutputVerbs.contains(action) {
                        XCTAssertEqual(routed.sound, .refused(finishSwitchingToSpanDAC), "\(name) \(action)")
                        XCTAssertEqual(gate, finishSwitchingToSpanDAC, "\(name) \(action)")
                    }
                case .consistent(.spandacMac, .musicApp):
                    switch column4(action) {
                    case .spandacRead:
                        XCTAssertEqual(routed, RoutedAction(data: .spandacMac, sound: .source), "\(name) \(action)")
                    case .refused(let why):
                        XCTAssertEqual(routed.sound, .refused(why), "\(name) \(action)")
                        XCTAssertEqual(gate, why, "\(name) \(action)")
                    case .musicTUIRowPath:
                        XCTAssertEqual(routed, RoutedAction(data: .spandacMac, sound: .musicApp), "\(name) \(action)")
                    case .musicTUIShipped:
                        XCTAssertEqual(routed, RoutedAction(data: .none, sound: .musicApp), "\(name) \(action)")
                        XCTAssertNil(gate, "\(name) \(action)")
                    case .unaffected:
                        XCTAssertEqual(routed.sound, .unaffected, "\(name) \(action)")
                        XCTAssertNil(gate, "\(name) \(action)")
                    }
                case .consistent(.spandacMac, let output):
                    XCTAssertEqual(routed.sound, routeAction(action, in: output, from: .cli), "\(name) \(action)")
                    XCTAssertEqual(gate, cliBridgeRefusal(action, mode: output), "\(name) \(action)")
                case .consistent(.open, _):
                    XCTFail("\(name) is not a committed column")
                }
            }
        }
        // Every CLI action is either dispatched or gated in the files; the
        // inventory test owns that walk. Here: column 4 decided each one.
        XCTAssertEqual(cliActions.filter { if case .musicTUIRowPath = column4($0) { return true }; return false }.count, 7)
    }

    // MARK: - Reads come from the Mac

    func testSearchWithSpanDACDataOnMusicTUIOutputReadsFromTheMac() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted,
                                    dataReplies: ["slice.status": [readyWithoutADAC], "slice.search": [C.mixed]])
        let (error, calls) = search(h, ["angel"])
        XCTAssertNil(error, "no DAC on this Mac is no reason to refuse a DATA read")
        XCTAssertEqual(calls, [], "no REST, no AppleScript, no launch")
        XCTAssertEqual(h.dataWire.requests.compactMap { $0["op"] as? String }, ["slice.status", "slice.search"])
        XCTAssertEqual(h.outputWire.requestCount, 0)
        XCTAssertEqual(h.outputClientsBuilt, 0, "a read never builds an output client")
        XCTAssertEqual(h.dataClientsBuilt, 1)
        let cached = try h.env.cache.readSongs()
        XCTAssertEqual(cached.map(\.origin), [.bridgeCatalog, .bridgeCatalog])
        XCTAssertEqual(cached.map(\.bridgeID), ["1440857781", "1440857999"])

        // The library search too: SpanDAC's own library, from the Mac.
        let lib = CLIDataRouteHarness(output: .musicApp, data: .accepted,
                                      dataReplies: ["slice.status": [readyWithoutADAC],
                                                    "slice.librarySongs": [L.songs([("l.1", "Angel", "Massive Attack", "Mezzanine")])]])
        XCTAssertNil(search(lib, ["angel"], library: true).error)
        XCTAssertEqual(lib.dataWire.requests.compactMap { $0["op"] as? String }, ["slice.status", "slice.librarySongs"])
        XCTAssertEqual(try lib.env.cache.readSongs().map(\.origin), [.bridgeLibrary])
        XCTAssertEqual(lib.outputClientsBuilt, 0)
    }

    // MARK: - play N and the named forms reach the two seams

    func testPlayNOfASpanDACRowReachesTheMusicTUIPlaySeams() throws {
        let h = CLIDataRouteHarness(
            output: .musicApp, data: .accepted,
            dataReplies: ["slice.status": [readyWithoutADAC],
                          "slice.librarySongs": [L.songs([("l.9", "Teardrop", "Massive Attack", "Mezzanine")])]])
        try cacheRows(h, [
            SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .bridgeLibrary, bridgeID: "l.1"),
            SongResult(index: 2, title: "Teardrop", artist: "Massive Attack", album: "", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "1440857999"),
        ])

        var r = play(h, ["1"])
        XCTAssertNil(r.error); XCTAssertEqual(r.calls, [])
        XCTAssertEqual(h.library.requests, [CLIMusicTUILibraryPlayRequest(
            kind: .song, label: "Angel",
            rows: [MusicRow(id: "l.1", title: "Angel", artist: "Massive Attack", album: "Mezzanine", kind: .song)],
            startAt: 1, shuffle: false, resultNumber: 1, json: false)])

        r = play(h, ["2"])
        XCTAssertNil(r.error); XCTAssertEqual(r.calls, [])
        XCTAssertEqual(h.catalogue.requests, [CLIMusicTUICataloguePlayRequest(
            catalogueID: "1440857999", title: "Teardrop", artist: "Massive Attack", album: nil,
            resultNumber: 2, json: false)])

        // A named form resolves against SpanDAC's library on this Mac, then
        // hands the ROWS over; a song link hands its catalogue id over.
        r = play(h, song: "Teardrop")
        XCTAssertNil(r.error); XCTAssertEqual(r.calls, [])
        XCTAssertEqual(h.library.requests.last?.rows.map(\.id), ["l.9"])
        XCTAssertEqual(h.library.requests.last?.kind, .song)
        r = play(h, ["https://music.apple.com/us/song/teardrop/1440857999"])
        XCTAssertNil(r.error)
        XCTAssertEqual(h.catalogue.requests.last?.catalogueID, "1440857999")
        XCTAssertNil(h.catalogue.requests.last?.resultNumber)

        XCTAssertEqual(h.library.locked, [true, true], "each play is made under the output lock")
        XCTAssertEqual(h.catalogue.locked, [true, true])
        XCTAssertEqual(h.outputClientsBuilt, 0, "nothing is sent to a SpanDAC output")
        XCTAssertEqual(h.outputWire.requestCount, 0)
        XCTAssertFalse(h.dataWire.requests.contains { ["slice.queue", "slice.play", "slice.playStation"].contains($0["op"] as? String ?? "") },
                       "the Mac's data socket is only read")

        // Production's seams refuse, with the score's sentence, and play nothing.
        let shipped = CLIDataRouteHarness(output: .musicApp, data: .accepted, recordSeams: false)
        try cacheRows(shipped, [SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                           catalogId: "", origin: .bridgeLibrary, bridgeID: "l.1"),
                                SongResult(index: 2, title: "Teardrop", artist: "Massive Attack", album: "",
                                           catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857999")])
        for n in ["1", "2"] {
            let refused = play(shipped, [n])
            XCTAssertEqual(refused.error as? ExitCode, .failure, n)
            XCTAssertEqual(refused.calls, [], n)
        }
        XCTAssertEqual(shipped.io.out, [pickASpanDACOutput, pickASpanDACOutput])
        XCTAssertEqual(shipped.outputClientsBuilt, 0)
    }

    // MARK: - radio play opens the station URL

    func testRadioPlayOnMusicTUIOutputOpensTheStationURL() throws {
        let appleMusic1 = "https://music.apple.com/us/station/apple-music-1/ra.978194965"
        let h = CLIDataRouteHarness(
            output: .musicApp, data: .accepted,
            dataReplies: ["slice.status": [readyWithoutADAC],
                          "slice.searchStations": [Q.search([Q.station("ra.1", "Radio One", slug: "radio-one")])]])
        let path = h.directory + "/stations.json"
        XCTAssertTrue(isUnderTemporaryDirectory(path))
        let stations = StationStore(path: path)
        let opener = CLIRadioCountingOpener()
        opener.lockPath = h.env.routing.outputLock!.path

        // A URL opens directly: no SpanDAC request at all.
        var r = tripwired {
            try runRadioPlay(query: [appleMusic1], env: h.env, opener: opener, stations: stations,
                             musicApp: { _ in XCTFail("the shipped radio body ran") })
        }
        XCTAssertNil(r.error); XCTAssertEqual(r.calls, [])
        XCTAssertEqual(opener.urls, [stationPlayURL(appleMusic1)!])
        XCTAssertEqual(h.dataWire.requestCount, 0)

        // A name is searched through SpanDAC on this Mac, then opened by URL.
        r = tripwired {
            try runRadioPlay(query: ["radio", "one"], env: h.env, opener: opener, stations: stations,
                             musicApp: { _ in XCTFail("the shipped radio body ran") })
        }
        XCTAssertNil(r.error); XCTAssertEqual(r.calls, [])
        XCTAssertEqual(opener.urls.last, stationPlayURL("https://music.apple.com/us/station/radio-one/ra.1"))
        XCTAssertEqual(opener.lockedDuringOpen, [true, true])
        XCTAssertEqual(h.dataWire.requests.compactMap { $0["op"] as? String }, ["slice.status", "slice.searchStations"])
        XCTAssertTrue(h.dataWire.sent("slice.playStation").isEmpty, "never played on a SpanDAC")
        XCTAssertEqual(h.outputClientsBuilt, 0)
        XCTAssertEqual(h.io.out, ["▶ Apple Music 1", "▶ Radio One"])

        // Two hits never pick one.
        let two = CLIDataRouteHarness(
            output: .musicApp, data: .accepted,
            dataReplies: ["slice.status": [readyWithoutADAC],
                          "slice.searchStations": [Q.search([Q.station("ra.1", "Radio One"), Q.station("ra.2", "Radio One Dance")])]])
        let none = CLIRadioCountingOpener()
        r = tripwired {
            try runRadioPlay(query: ["radio"], env: two.env, opener: none, stations: StationStore(path: two.directory + "/stations.json"),
                             musicApp: { _ in XCTFail("the shipped radio body ran") })
        }
        XCTAssertEqual(r.error as? ExitCode, .failure)
        XCTAssertEqual(none.urls, [])
    }

    // MARK: - A row from before the switch

    func testACachedRowFromBeforeTheSwitchRefuses() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted)
        try cacheRows(h, [
            SongResult(index: 3, title: "Angel", artist: "Massive Attack", album: "Mezzanine", catalogId: "1440857781"),
            SongResult(index: 4, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .library),
        ])
        for (n, json) in [(3, false), (4, true)] {
            let r = play(h, [String(n)], json: json)
            XCTAssertEqual(r.error as? ExitCode, .failure)
            XCTAssertEqual(r.calls, [])
            XCTAssertEqual(h.io.out.last, cliFailureText(resultFromBeforeSpanDACSwitch(n), json: json))
        }
        XCTAssertEqual(h.library.requests, [])
        XCTAssertEqual(h.catalogue.requests, [])
        XCTAssertEqual(h.dataClientsBuilt + h.outputClientsBuilt, 0)
    }

    // MARK: - Transport and now

    func testTransportAndNowActOnTheMusicTUIOutputWithSpanDACData() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted)
        var ran: [String] = []
        var locked: [Bool] = []
        let lockPath = h.env.routing.outputLock!.path
        let r = tripwired {
            try runPause(env: h.env, musicApp: { ran.append("pause"); locked.append(!OutputLockTestSupport.isFree(lockPath)) })
            try runSkip(json: false, env: h.env, musicApp: { _ in ran.append("skip") })
            try runBack(json: true, env: h.env, musicApp: { _ in ran.append("back") })
            try runStop(env: h.env, musicApp: { ran.append("stop") })
            try runNow(json: true, env: h.env, musicApp: { _ in ran.append("now"); locked.append(!OutputLockTestSupport.isFree(lockPath)) })
            try refuseInBridge(.volume, selection: h.env.routing.selection)
            try refuseInBridge(.airplayRoute, selection: h.env.routing.selection)
            try refuseInBridge(.loveTrack, selection: h.env.routing.selection)
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(ran, ["pause", "skip", "back", "stop", "now"])
        XCTAssertEqual(locked, [true, false], "a pause takes the output lock; now is a read of the output")
        XCTAssertEqual(h.dataClientsBuilt + h.outputClientsBuilt, 0, "no SpanDAC client for the MusicTUI output")
        XCTAssertEqual(h.dataWire.requestCount + h.outputWire.requestCount, 0)
        XCTAssertEqual(h.io.out, [])
    }

    // MARK: - Starting SpanDAC is said on stderr only

    func testStartingSpanDACNeverReachesStdoutOrJSON() throws {
        let io = CLIBridgeTestIO()
        let fake = CLIFakeMacStarter(.ready)
        let starter = CLIAnnouncingStarter(fake, err: io.writeErr)
        let wire = BridgeLibraryReadsWire(["slice.status": [readyWithoutADAC], "slice.search": [C.mixed]])
        var running = false
        let send: (String, String) throws -> String = { path, line in
            guard running else { throw SourceAppError.notRunning }
            return try wire.transport(path, line)
        }
        let started = CLIAnnouncingStarterProbe(starter) { running = true }
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, starter: started,
                                    dataTransport: retryingOnceAfterAStart(send, starter: started))
        // The harness's io is its own; route stderr through the announcing one.
        let env = CLIBridgeEnv(routing: h.env.routing, modeStore: h.env.modeStore, cache: h.env.cache,
                               out: io.writeOut, err: io.writeErr, sleep: io.sleep)
        let r = tripwired {
            try runSearch(query: ["angel"], artist: nil, album: nil, types: "songs", library: false, limit: 10,
                          json: true, env: env, musicApp: { _, _, _, _, _, _, _ in XCTFail("shipped search ran") })
        }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(fake.starts, 1, "one start, for the first request")
        XCTAssertEqual(io.err, [startingSpanDAC])
        XCTAssertFalse(io.stdoutBytes.contains("Starting"), io.stdoutBytes)
        XCTAssertEqual(io.out.count, 1)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(io.out[0].utf8)), "stdout is one JSON document")
        XCTAssertEqual(wire.requests.compactMap { $0["op"] as? String }, ["slice.status", "slice.search"])

        // A second start in the same process says nothing more.
        _ = starter.ensureStarted()
        XCTAssertEqual(io.err, [startingSpanDAC])
    }

    // MARK: - Data readiness never depends on a DAC

    /// With a SpanDAC OUTPUT selected, a pure read still asks only SpanDAC on
    /// this Mac for DATA. Whether this Mac has a DAC is the output's concern,
    /// so a Mac with none still serves a search, whether sound goes to an
    /// iPhone or to this Mac.
    func testDataReadsIgnoreTheMacDACWhenTheOutputIsAnIPhone() throws {
        for output in [PlaybackMode.networkSource("D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"), .source] {
            let label = "\(output)"
            let h = CLIDataRouteHarness(output: output, data: .accepted,
                                        dataReplies: ["slice.status": [readyWithoutADAC], "slice.search": [C.mixed]])
            XCTAssertEqual(h.env.routing.selection, .consistent(data: .spandacMac, output: output), label)
            let (error, calls) = search(h, ["angel"])
            XCTAssertNil(error, "\(label): no DAC on this Mac is no reason to refuse a DATA read")
            XCTAssertEqual(calls, [], label)
            XCTAssertEqual(h.io.out.filter { $0.contains("DAC") }, [], "\(label): no DAC refusal printed")
            XCTAssertEqual(h.dataWire.requests.compactMap { $0["op"] as? String }, ["slice.status", "slice.search"], label)
            XCTAssertEqual(h.outputWire.requestCount, 0, label)
            XCTAssertEqual(h.outputClientsBuilt, 0, "\(label): a read never builds an output client")
            XCTAssertEqual(try h.env.cache.readSongs().map(\.origin), [.bridgeCatalog, .bridgeCatalog], label)
        }
    }

    /// OUTPUT readiness is unchanged: playing on this Mac's SpanDAC still
    /// needs its DAC, and nothing is sent to play without one.
    func testPlayingOnTheMacSpanDACStillNeedsItsDAC() throws {
        let h = CLIDataRouteHarness(output: .source, data: .accepted,
                                    dataReplies: ["slice.status": [readyWithoutADAC]],
                                    outputReplies: ["slice.status": [readyWithoutADAC]])
        try cacheRows(h, [SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                     catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857781")])
        let (error, calls) = play(h, ["1"])
        XCTAssertNotNil(error, "no DAC: the play refuses")
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, [cliBridgeNotReadySentence(.unavailable("plug in your DAC"))])
        XCTAssertEqual(h.outputWire.requests.compactMap { $0["op"] as? String }, ["slice.status"],
                       "only the readiness check reaches the output; nothing plays")
        XCTAssertEqual(h.dataWire.requestCount, 0)
    }

    // MARK: - Blocked state

    func testBlockedStateCLIRefusesSoundAndReadsOpen() throws {
        for output in [PlaybackMode.source, .networkSource("D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F")] {
            for file in CLIDataFile.blocking {
                let label = "\(output) \(file)"
                let h = CLIDataRouteHarness(output: output, data: file)
                XCTAssertEqual(h.env.routing.selection, .outputBlocked(stored: output), label)
                let before = h.fileBytes()
                try cacheRows(h, [SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                             catalogId: "", origin: .bridgeLibrary, bridgeID: "l.1")])

                var ranShipped: [String] = []
                let r = tripwired {
                    XCTAssertThrowsError(try runPause(env: h.env, musicApp: { ranShipped.append("pause") }), label)
                    XCTAssertThrowsError(try runNow(json: true, env: h.env, musicApp: { _ in ranShipped.append("now") }), label)
                    XCTAssertThrowsError(try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil,
                                                     json: false, env: h.env, musicAppDeps: noMusicApp()), label)
                    let gated = captureStdout { try refuseInBridge(.volume, selection: h.env.routing.selection) }
                    XCTAssertEqual(gated.output, finishSwitchingToSpanDAC + "\n", label)
                    // Reads run MusicTUI's own data, as shipped.
                    try runSearch(query: ["angel"], artist: nil, album: nil, types: "songs", library: false, limit: 10,
                                  json: false, env: h.env, musicApp: { _, _, _, _, _, _, _ in ranShipped.append("search") })
                }
                XCTAssertNil(r.error, label)
                XCTAssertEqual(r.calls, [], label)
                XCTAssertEqual(ranShipped, ["search"], label)
                XCTAssertEqual(h.io.out, [finishSwitchingToSpanDAC, cliFailureText(finishSwitchingToSpanDAC, json: true),
                                          finishSwitchingToSpanDAC], label)
                XCTAssertEqual(h.dataClientsBuilt, 0, "\(label): no SpanDAC data client")
                XCTAssertEqual(h.outputClientsBuilt, 0, "\(label): no SpanDAC output client")
                XCTAssertEqual(h.dataWire.requestCount + h.outputWire.requestCount, 0, label)
                XCTAssertEqual(h.library.requests.count + h.catalogue.requests.count, 0, label)
                XCTAssertEqual(h.fileBytes(), before, "\(label): nothing rewritten")
            }
        }
    }

    // MARK: - Open data is the shipped CLI

    func testOpenDataCLIIsTheShippedBehaviour() throws {
        for file in [CLIDataFile.missing, .declined, .explicitOpen, .corrupt] {
            let h = CLIDataRouteHarness(output: .musicApp, data: file)
            XCTAssertEqual(h.env.routing.selection, .consistent(data: .open, output: .musicApp), "\(file)")
            for action in MusicTUIAction.allCases {
                XCTAssertEqual(cliBridgeRefusal(action, selection: h.env.routing.selection),
                               cliBridgeRefusal(action, mode: .musicApp), "\(file) \(action)")
            }
            var ran: [String] = []
            let stations = StationStore(path: h.directory + "/stations.json")
            let r = tripwired {
                try runPause(env: h.env, musicApp: { ran.append("pause") })
                try runNow(json: false, env: h.env, musicApp: { _ in ran.append("now") })
                try runSearch(query: ["angel"], artist: nil, album: nil, types: "songs", library: true, limit: 10,
                              json: false, env: h.env, musicApp: { _, _, _, _, _, _, _ in ran.append("search") })
                try runRadioPlay(query: ["radio"], env: h.env, stations: stations, musicApp: { _ in ran.append("radio") })
                try runRecent(limit: 5, json: false, env: h.env, musicApp: { ran.append("recent") })
                try refuseInBridge(.volume, selection: h.env.routing.selection)
                try refuseInBridge(.suggest, selection: h.env.routing.selection)
                try refuseInBridge(newReleasesAction(artist: nil, likeCurrent: false), selection: h.env.routing.selection)
            }
            XCTAssertNil(r.error, "\(file)")
            XCTAssertEqual(r.calls, [], "\(file)")
            XCTAssertEqual(ran, ["pause", "now", "search", "radio", "recent"], "\(file)")
            XCTAssertEqual(h.dataClientsBuilt + h.outputClientsBuilt, 0, "\(file): open data never builds a SpanDAC client")
            XCTAssertEqual(h.io.out, [], "\(file)")
        }
    }
}

/// Wraps an announcing starter so a test can flip its fake socket to
/// "running" the moment a start is asked for, as a real launch would.
final class CLIAnnouncingStarterProbe: MacSpanDACStarting {
    private let wrapped: MacSpanDACStarting
    private let onStart: () -> Void
    init(_ wrapped: MacSpanDACStarting, onStart: @escaping () -> Void) {
        self.wrapped = wrapped
        self.onStart = onStart
    }
    var isInstalled: Bool { wrapped.isInstalled }
    var isRunning: Bool { wrapped.isRunning }
    var isStarting: Bool { wrapped.isStarting }
    func ensureStarted() -> MacSpanDACStartOutcome {
        let outcome = wrapped.ensureStarted()
        if outcome == .ready { onStart() }
        return outcome
    }
    func bringForward() { wrapped.bringForward() }
    func newAttempt() { wrapped.newAttempt() }
}
