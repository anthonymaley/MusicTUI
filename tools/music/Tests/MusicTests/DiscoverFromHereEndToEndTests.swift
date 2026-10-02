// tools/music/Tests/MusicTests/DiscoverFromHereEndToEndTests.swift
//
// Discover "play from here" on Apple's own copy, end to end over fakes (score
// step C6, design section 9 item 9: the G0 cases). The real lifecycle
// coordinator, transaction, journal (in a temporary directory), sequencer,
// start function, mode guard, deletion guard and end watcher, composed by the
// production composer, run over a fake player, fake SpanDAC ops and a fake
// script runner. No Music.app, no AppleScript, no socket, no audio, and
// nothing under ~/.config/music. Built and tested with fakes: nothing here
// says it works against Music.app or Apple.
import XCTest
@testable import music

/// A clock that only moves when something sleeps on it or a test advances it.
final class DFH6Clock {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time = time.addingTimeInterval(seconds); lock.unlock() }
}

/// Everything a copy play reaches, faked, and the production composition over
/// it. One library with at most one copy of one playlist, whose persistent ID
/// is `hex`; one player; his shuffle and repeat.
final class DFH6World {
    static let alias = "4660"
    static let hex = "0000000000001234"

    let directory: URL
    let journal: FileDiscoverCopyJournalStore
    let ops = FakeCatalogPlaylistOps()
    let player: FakeDiscoverCopyPlayer
    let clock = DFH6Clock()
    let rows: [DiscoverItem]

    // His modes, and every set that reached them.
    var shuffle = true
    var songRepeat: RepeatMode = .all
    private(set) var modeSets: [String] = []

    // His library, as the deletion guard's script sees it.
    private(set) var inLibrary = false
    private(set) var deletes: [String] = []
    private(set) var scripts: [String] = []

    // What the composition asked for.
    private(set) var requests: [DiscoverCopyRequest] = []
    private(set) var pendingEnds: [() -> Void] = []
    /// Runs inside the fake add, on the play's own thread.
    var duringAdd: (() -> Void)?
    /// Told `"ops.offers"`, `"ops.copies"`, `"ops.add"`, `"script"`,
    /// `"player.<call>"` as each fake is reached, in order.
    var onFake: ((String) -> Void)?
    private(set) var runtime: (seams: DiscoverCopySeams, watcher: DiscoverCopyWatcher)!

    /// Persistent IDs for the copy's tracks, one per row.
    static func trackIDs(_ count: Int) -> [String] { (0..<count).map { String(format: "%016X", 0xA000 + $0) } }

    init(rows: [DiscoverItem], selected: Int, spandacDataSelected: @escaping () -> Bool = { true }) {
        self.rows = rows
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-dfh6-\(UUID().uuidString)")
        precondition(!directory.path.contains("/.config/music"), "a test journal must be temporary")
        journal = FileDiscoverCopyJournalStore(paths: DiscoverCopyPaths(directory: directory))
        player = FakeDiscoverCopyPlayer(hex: Self.hex, ids: Self.trackIDs(rows.count),
                                        trackK: DFH6World.copyTrack(matching: rows, selected: selected))
        let copy = CatalogPlaylistCopy(alias: Self.alias)
        ops.copiesResults = [.success([]), .success([copy])]
        ops.addOutcome = .added(copies: [copy])
        ops.onAdd = { [unowned self] in
            onFake?("ops.add")
            inLibrary = true
            duringAdd?()
        }
        player.onCall = { [unowned self] name in onFake?("player." + name) }

        let composed = composeDiscoverCopyRuntime(DiscoverCopyRuntimeParts(
            journal: journal,
            ops: { [unowned self] in DFH6Ops(inner: ops, onFake: { [unowned self] in onFake?($0) }) },
            spandacDataSelected: spandacDataSelected,
            player: player,
            modes: DiscoverModeGuard.Seams(
                read: { [unowned self] in (shuffle, songRepeat) },
                setShuffle: { [unowned self] on in modeSets.append("shuffle:\(on)"); shuffle = on; return true },
                setRepeat: { [unowned self] mode in modeSets.append("repeat:\(mode.rawValue)"); songRepeat = mode; return true }),
            run: { [unowned self] in run($0) },
            now: { [clock] in clock.now() },
            sleep: { [clock] in clock.advance($0) },
            log: { _ in },
            enqueue: { [unowned self] in pendingEnds.append($0) }))
        var seams = composed.seams
        let sequence = seams.sequence
        seams.sequence = { [unowned self] hex, txn, request, gate, progress, commit in
            requests.append(request)
            return sequence(hex, txn, request, gate, progress, commit)
        }
        runtime = (seams, composed.watcher)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Track k of the copy as it would read when it matches the shown row.
    static func copyTrack(matching rows: [DiscoverItem], selected: Int) -> DiscoverCopyTrack {
        guard rows.indices.contains(selected) else { return DiscoverCopyTrack(title: "", artist: "", durationMS: nil) }
        let row = rows[selected]
        var ms: Int?
        if case .milliseconds(let value) = row.length { ms = value }
        return DiscoverCopyTrack(title: row.name, artist: row.subtitle ?? "", durationMS: ms)
    }

    /// The fake `ScriptRunner`: the watcher's one read, and the deletion
    /// guard's script, answered from the model. Anything else fails.
    private func run(_ script: String) -> String? {
        onFake?("script")
        if script == discoverCopyObservationScript {
            scripts.append("observe")
            let state: String
            switch player.state {
            case .stopped: state = "stopped"
            case .playing: state = "playing"
            case .paused: state = "paused"
            }
            let track = player.currentIndex.flatMap { player.ids.indices.contains($0) ? player.ids[$0] : nil } ?? ""
            return "\(state)|\(player.currentPlaylist ?? "")|\(track)"
        }
        for delete in [true, false] where script == discoverCopyEndScript(hex: Self.hex, delete: delete) {
            scripts.append(delete ? "end:delete" : "end:check")
            guard inLibrary else { return "gone" }
            if player.state != .stopped, player.currentPlaylist == Self.hex { return "spared" }
            guard delete else { return "kept" }
            inLibrary = false
            deletes.append(Self.hex)
            return "deleted"
        }
        scripts.append("unknown")
        return nil
    }

    func entries() -> [DiscoverCopyEntry] { (try? journal.entries()) ?? [] }

    /// Runs what the watcher enqueued, as the action queue would.
    func runEnds() {
        let ends = pendingEnds
        pendingEnds = []
        ends.forEach { $0() }
    }

    /// He stopped: the watcher sees `stopped` twice, three seconds apart.
    func stopAndWatchTheEnd() {
        _ = player.stop()
        runtime.watcher.tick()
        clock.advance(DiscoverCopyTiming.endEvidenceGap)
        runtime.watcher.tick()
        runEnds()
    }

    /// The production lifecycle coordinator over these seams, posting to
    /// `status` exactly as the shell's does. Its launch sweep is done.
    func lifecycle(status: StatusStore) -> DiscoverLifecycleCoordinator {
        let coordinator = makeDiscoverLifecycleCoordinator(backend: AppleScriptBackend(), status: status,
                                                           copy: runtime.seams)
        coordinator.completeLaunchSweep(.swept)
        return coordinator
    }
}

/// `FakeCatalogPlaylistOps` with every call announced (its own record has no
/// hook for the capability read or the copies read).
struct DFH6Ops: SpanDACCatalogPlaylistOps {
    let inner: FakeCatalogPlaylistOps
    let onFake: (String) -> Void
    var offersCatalogPlaylist: Bool { onFake("ops.offers"); return inner.offersCatalogPlaylist }
    func copies(ofCatalogPlaylist id: String) throws -> [CatalogPlaylistCopy] {
        onFake("ops.copies")
        return try inner.copies(ofCatalogPlaylist: id)
    }
    func addCatalogPlaylist(id: String) -> CatalogPlaylistAddOutcome { inner.addCatalogPlaylist(id: id) }
}

/// Five rows of a playlist as SpanDAC sends them, lengths 200 s, 201 s, ...
func dfh6Rows(_ count: Int = 5) -> [DiscoverItem] {
    dfhRows((0..<count).map { .milliseconds(200_000 + $0 * 1_000) })
}

final class DiscoverFromHereEndToEndTests: XCTestCase {

    private let playlistID = "pl.u-abc"
    private let title = "Boom Bap"
    private var status: StatusStore!

    override func setUp() {
        super.setUp()
        status = StatusStore()
        // Every test here runs armed: an AppleScript or REST call that got
        // past the fakes is recorded, blocked, and fails the test below.
        ExternalCallTripwire.shared.arm()
    }

    override func tearDown() {
        let escaped = ExternalCallTripwire.shared.disarm()
        XCTAssertEqual(escaped.count, 0, "a call escaped the fakes: \(escaped)")
        super.tearDown()
    }

    private let alwaysHolds: DiscoverCopyGate = { body in body(); return .ran }

    /// One Enter on row `selected`, both phases, with a reservation that holds.
    @discardableResult
    private func play(_ world: DFH6World, _ lifecycle: DiscoverLifecycleCoordinator, rows: [DiscoverItem]? = nil,
                      selected: Int, file: StaticString = #filePath, line: UInt = #line) -> DiscoverPlayRequestOutcome? {
        let request = DiscoverCopyRequest(playlistID: playlistID, playlistTitle: title,
                                          rows: rows ?? world.rows, selected: selected)
        guard case .reserved(let slot) = lifecycle.reserveCopyPlay(request) else {
            XCTFail("the copy play was not reserved", file: file, line: line)
            return nil
        }
        let outcome = lifecycle.runCopyPlay(slot, gate: alwaysHolds)
        XCTAssertFalse(lifecycle.copyPlaySlotIsHeld, "the slot was not given back", file: file, line: line)
        return outcome
    }

    private func isListening(_ outcome: DiscoverPlayRequestOutcome?) -> Bool {
        if case .completed(.listening)? = outcome { return true }
        return false
    }

    // MARK: - (a) The ordinary case, and its end

    /// Song 3 of 5: the copy starts, is paused on song 1, steps to song 3 with
    /// each landing verified against the exact ID, and only then plays. The
    /// entry is `listening`, the watcher has it, and stopping ends it.
    func testOrdinaryPlayLandsOnTheChosenRowThenEndsWhenHeStops() {
        let world = DFH6World(rows: dfh6Rows(), selected: 2)
        let lifecycle = world.lifecycle(status: status)
        let ids = DFH6World.trackIDs(5)

        XCTAssertTrue(isListening(play(world, lifecycle, selected: 2)))

        XCTAssertEqual(world.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "play"])
        let calls = world.player.calls
        let landings = calls.filter { $0.hasPrefix("landing:") && $0.hasSuffix(":false") }
        XCTAssertEqual(landings.compactMap { $0.split(separator: ":").dropFirst().first.map(String.init) }
                               .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } },
                       [ids[1], ids[2]], "each landing P[2...k] was verified by its exact ID")
        let play = calls.lastIndex(of: "play")!
        XCTAssertTrue(calls.lastIndex(where: { $0.hasPrefix("landing:") })! < play, "`play` only after the last landing")
        XCTAssertTrue(calls[(play + 1)...].contains("confirm:\(ids[2])"), "confirmed on the chosen track")
        XCTAssertEqual(world.player.currentIndex, 2)
        XCTAssertEqual(world.player.state, .playing)

        XCTAssertEqual(world.ops.calls, ["copies:\(playlistID)", "add:\(playlistID)"])
        XCTAssertEqual(world.requests.map(\.selected), [2])
        let entry = world.entries().first
        XCTAssertEqual(world.entries().count, 1)
        XCTAssertEqual(entry?.state, .listening)
        XCTAssertEqual(entry?.hex, DFH6World.hex)
        XCTAssertEqual(entry?.watching, true)
        XCTAssertEqual(entry?.priorShuffle, true)
        XCTAssertEqual(entry?.priorRepeat, RepeatMode.all.rawValue)
        XCTAssertEqual(world.shuffle, false)
        XCTAssertEqual(world.songRepeat, .off)
        XCTAssertEqual(status.current()?.text, "Playing \(title)")
        XCTAssertEqual(world.deletes, [])

        // Still playing: the watcher reads our copy and signals nothing.
        world.runtime.watcher.tick()
        world.clock.advance(10)
        world.runtime.watcher.tick()
        XCTAssertEqual(world.pendingEnds.count, 0)
        XCTAssertEqual(world.scripts.filter { $0 == "observe" }.count, 2, "the watcher adopted the copy")

        // Stopped twice: deleted, modes back, closed.
        world.stopAndWatchTheEnd()
        XCTAssertEqual(world.deletes, [DFH6World.hex])
        XCTAssertEqual(world.shuffle, true)
        XCTAssertEqual(world.songRepeat, .all)
        XCTAssertEqual(world.entries().first?.state, .closed)
        XCTAssertEqual(world.entries().first?.watching, false)
        XCTAssertNil(world.entries().first?.priorShuffle)

        // Nothing is watched any more: a tick runs no script.
        let before = world.scripts.count
        world.runtime.watcher.tick()
        XCTAssertEqual(world.scripts.count, before)
    }

    /// One stopped read is not an end: the gap must pass first.
    func testOneStoppedReadDoesNotEndTheCopy() {
        let world = DFH6World(rows: dfh6Rows(), selected: 0)
        let lifecycle = world.lifecycle(status: status)
        XCTAssertTrue(isListening(play(world, lifecycle, selected: 0)))

        _ = world.player.stop()
        world.runtime.watcher.tick()
        world.clock.advance(1)
        world.runtime.watcher.tick()
        world.runEnds()

        XCTAssertEqual(world.deletes, [])
        XCTAssertEqual(world.entries().first?.state, .listening)
    }

    // MARK: - (b) The copy differs from the rows he was shown

    private func assertRefusedAndCleanedUp(_ world: DFH6World, _ outcome: DiscoverPlayRequestOutcome?,
                                           text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(isListening(outcome), file: file, line: line)
        XCTAssertEqual(world.player.commands, [], "no command reached the player", file: file, line: line)
        XCTAssertEqual(world.deletes, [DFH6World.hex], "the owned copy was deleted", file: file, line: line)
        XCTAssertEqual(world.entries().map(\.state), [.closed], file: file, line: line)
        XCTAssertEqual(status.current()?.text, text, file: file, line: line)
        XCTAssertEqual(status.current()?.isError, true, file: file, line: line)
        XCTAssertEqual(world.shuffle, true, "his modes were never touched", file: file, line: line)
    }

    func testACopyWithOneSongInsertedRefusesAndIsDeleted() {
        let world = DFH6World(rows: dfh6Rows(), selected: 2)
        world.player.ids = DFH6World.trackIDs(6)
        let outcome = play(world, world.lifecycle(status: status), selected: 2)
        assertRefusedAndCleanedUp(world, outcome, text: discoverCopyChangedText(playlist: title))
    }

    func testACopyWithOneSongRemovedRefusesAndIsDeleted() {
        let world = DFH6World(rows: dfh6Rows(), selected: 2)
        world.player.ids = DFH6World.trackIDs(4)
        let outcome = play(world, world.lifecycle(status: status), selected: 2)
        assertRefusedAndCleanedUp(world, outcome, text: discoverCopyChangedText(playlist: title))
    }

    func testACopyWhoseChosenSongWasEditedRefusesAndIsDeleted() {
        let rows = dfh6Rows()
        let world = DFH6World(rows: rows, selected: 2)
        world.player.trackK = DiscoverCopyTrack(title: "Song 3 (Live)", artist: "Artist", durationMS: 202_000)
        let outcome = play(world, world.lifecycle(status: status), selected: 2)
        assertRefusedAndCleanedUp(world, outcome,
                                  text: discoverCopyUnconfirmedText(title: "Song 3", playlist: title))
    }

    // MARK: - (c) Availability of the chosen row

    func testAPlayableChosenRowPasses() {
        let world = DFH6World(rows: dfh6Rows(), selected: 4)
        XCTAssertTrue(isListening(play(world, world.lifecycle(status: status), selected: 4)))
        XCTAssertEqual(world.player.currentIndex, 4, "the LAST row is reached by position")
        XCTAssertEqual(world.player.commands.filter { $0 == "nextTrack" }.count, 4)
    }

    /// A row that never starts playing: the refusal names the song, the copy
    /// stays in his library and stays `owned`, and the modes are put back.
    func testAnUnplayableChosenRowRefusesAtS13AndLeavesTheCopyProtected() {
        let world = DFH6World(rows: dfh6Rows(), selected: 2)
        world.player.onConfirm = { _ in .notYet }
        let outcome = play(world, world.lifecycle(status: status), selected: 2)

        XCTAssertFalse(isListening(outcome))
        XCTAssertEqual(status.current()?.text, discoverWontPlayText(title: "Song 3"))
        XCTAssertEqual(status.current()?.staysUntilStateChange, true)
        XCTAssertEqual(world.deletes, [], "the copy is NOT deleted")
        XCTAssertFalse(world.scripts.contains("end:delete"))
        XCTAssertEqual(world.entries().map(\.state), [.owned])
        XCTAssertEqual(world.player.commands.last, "stop")
        XCTAssertEqual(world.shuffle, true)
        XCTAssertEqual(world.songRepeat, .all)
    }

    func testACopyOneShorterIsTheCountRefusal() {
        let world = DFH6World(rows: dfh6Rows(), selected: 0)
        world.player.ids = DFH6World.trackIDs(4)
        let outcome = play(world, world.lifecycle(status: status), selected: 0)
        guard case .completed(.failedBeforePlay(_, let stage))? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(stage, .identity)
        XCTAssertEqual(status.current()?.text, discoverCopyChangedText(playlist: title))
    }

    // MARK: - (d) Two rows sharing a title

    private var twinRows: [DiscoverItem] {
        var rows = dfh6Rows()
        rows[3] = DiscoverItem(id: "4", name: "Song 2", subtitle: "Artist", url: nil, artworkURL: nil,
                               detail: .song, length: .milliseconds(305_000))
        return rows
    }

    func testTwoRowsSharingATitlePassAtTheSelectedPositionWithAllMetadataEqual() {
        let world = DFH6World(rows: twinRows, selected: 3)
        XCTAssertTrue(isListening(play(world, world.lifecycle(status: status), selected: 3)))
        XCTAssertEqual(world.player.currentIndex, 3, "the second 'Song 2', by position, never by title search")
    }

    /// The copy's track 4 reads as the OTHER 'Song 2' (same title and artist,
    /// the first one's length): any difference refuses.
    func testTwoRowsSharingATitleRefuseWhenTheCopyHoldsTheOtherOne() {
        let rows = twinRows
        let world = DFH6World(rows: rows, selected: 3)
        world.player.trackK = DFH6World.copyTrack(matching: rows, selected: 1)
        let outcome = play(world, world.lifecycle(status: status), selected: 3)
        assertRefusedAndCleanedUp(world, outcome,
                                  text: discoverCopyUnconfirmedText(title: "Song 2", playlist: title))
    }

    // MARK: - (e) A song he already owns

    /// The copy's track is his own library version: it passes when title,
    /// artist and length agree (case and spacing aside)...
    func testAnOwnedRowWhoseCopyMetadataMatchesPasses() {
        let world = DFH6World(rows: dfh6Rows(), selected: 1)
        world.player.trackK = DiscoverCopyTrack(title: "SONG  2", artist: " artist", durationMS: 201_400)
        XCTAssertTrue(isListening(play(world, world.lifecycle(status: status), selected: 1)))
    }

    /// ...and refuses when it does not.
    func testAnOwnedRowWhoseCopyMetadataDiffersRefuses() {
        let world = DFH6World(rows: dfh6Rows(), selected: 1)
        world.player.trackK = DiscoverCopyTrack(title: "Song 2", artist: "Another Artist", durationMS: 201_000)
        let outcome = play(world, world.lifecycle(status: status), selected: 1)
        assertRefusedAndCleanedUp(world, outcome,
                                  text: discoverCopyUnconfirmedText(title: "Song 2", playlist: title))
    }

    // MARK: - The same copy replayed

    /// While listening, Enter on another row of the same playlist: no second
    /// add, one journal entry, no end signalled in between, his original modes
    /// still the ones recorded, and both restored after the final end.
    func testASecondEnterOnTheSamePlaylistReusesTheCopy() {
        let rows = dfh6Rows()
        let world = DFH6World(rows: rows, selected: 1)
        let lifecycle = world.lifecycle(status: status)
        XCTAssertTrue(isListening(play(world, lifecycle, selected: 1)))
        world.runtime.watcher.tick()

        world.player.trackK = DFH6World.copyTrack(matching: rows, selected: 3)
        XCTAssertTrue(isListening(play(world, lifecycle, selected: 3)))

        XCTAssertEqual(world.ops.calls.filter { $0.hasPrefix("add:") }.count, 1, "no second add")
        XCTAssertEqual(world.entries().count, 1, "one journal entry")
        XCTAssertEqual(world.entries().first?.state, .listening)
        XCTAssertEqual(world.player.currentIndex, 3)
        XCTAssertEqual(world.entries().first?.priorShuffle, true, "still his originals, not the (off, off) of play one")
        XCTAssertEqual(world.entries().first?.priorRepeat, RepeatMode.all.rawValue)
        XCTAssertEqual(world.deletes, [])

        world.runtime.watcher.tick()
        XCTAssertEqual(world.pendingEnds.count, 0, "the watcher signalled no end in between")

        world.stopAndWatchTheEnd()
        XCTAssertEqual(world.deletes, [DFH6World.hex])
        XCTAssertEqual(world.shuffle, true)
        XCTAssertEqual(world.songRepeat, .all)
        XCTAssertEqual(world.entries().map(\.state), [.closed])
    }

    // MARK: - Messages through the real StatusStore (item 7)

    /// A copy-path refusal is posted as a lasting error: still showing long
    /// after any ttl, gone at the next state change.
    func testACopyRefusalStaysPastItsTTLAndGoesAtAStateChange() {
        let world = DFH6World(rows: dfh6Rows(), selected: 2)
        world.player.ids = DFH6World.trackIDs(4)
        play(world, world.lifecycle(status: status), selected: 2)

        let later = Date().addingTimeInterval(3_600)
        XCTAssertEqual(status.current(now: later)?.text, discoverCopyChangedText(playlist: title))
        XCTAssertEqual(status.current(now: later)?.isError, true)
        XCTAssertEqual(status.current(now: later)?.staysUntilStateChange, true)
        status.stateChanged()
        XCTAssertNil(status.current())
    }

    /// The preflight refusals, the same way: a SpanDAC with no capability, and
    /// a row with no length. Neither reaches SpanDAC's ops or the journal.
    func testPreflightRefusalsStayUntilAStateChangeAndTouchNothing() {
        let noCapability = DFH6World(rows: dfh6Rows(), selected: 0)
        noCapability.ops.offers = false
        XCTAssertEqual(play(noCapability, noCapability.lifecycle(status: status), selected: 0),
                       .refused(.libraryOpsNotOffered))
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3_600))?.text, updateSpanDACToPlayOnMusicTUI)
        XCTAssertEqual(noCapability.ops.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noCapability.directory.path))

        var rows = dfh6Rows()
        rows[1].length = .null
        let noLength = DFH6World(rows: rows, selected: 2)
        XCTAssertEqual(play(noLength, noLength.lifecycle(status: status), selected: 2), .refused(.preflight))
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3_600))?.text,
                       discoverNoLengthText(title: "Song 2"))
        XCTAssertEqual(status.current()?.staysUntilStateChange, true)
        XCTAssertEqual(noLength.ops.calls, [])
        status.stateChanged()
        XCTAssertNil(status.current())
    }

    /// A progress line is transient (the production mapping gives it a minute)
    /// and is not an error; the success line replaces it.
    func testProgressIsTransientAndNotAnError() {
        let world = DFH6World(rows: dfh6Rows(), selected: 0)
        var seen: [StatusToast] = []
        world.duringAdd = { [status] in if let toast = status!.current() { seen.append(toast) } }
        XCTAssertTrue(isListening(play(world, world.lifecycle(status: status), selected: 0)))

        XCTAssertEqual(seen.map(\.text), [discoverAddingText(playlist: title)])
        XCTAssertEqual(seen.first?.isError, false)
        XCTAssertEqual(seen.first?.staysUntilStateChange, false)
        XCTAssertEqual(status.current()?.text, "Playing \(title)")
    }

    // MARK: - The composition's own seams

    /// The production runtime builds with a temporary path and writes nothing
    /// until a play does; its watcher runs no script while nothing is watched.
    func testTheProductionRuntimeIsInertUntilAPlay() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-dfh6-\(UUID().uuidString)")
        let stores = NSTemporaryDirectory() + "music-dfh6-routing-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: stores, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stores) }
        let routing = RoutingCoordinator(store: PlaybackModeStore(path: stores + "/mode.json"), surface: .tui,
                                         dataStore: DataProviderStore(path: stores + "/data.json"),
                                         makeSourceFor: { _ in SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) },
                                         makeDataClient: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) },
                                         starter: NeverStartsMacSpanDAC())
        var enqueued = 0
        let runtime = makeDiscoverCopyRuntime(backend: AppleScriptBackend(), routing: routing,
                                              paths: DiscoverCopyPaths(directory: directory),
                                              enqueue: { _ in enqueued += 1 })

        runtime.watcher.tick()
        XCTAssertFalse(runtime.seams.spandacDataSelected(), "MusicTUI's own data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(enqueued, 0)
        XCTAssertEqual(ExternalCallTripwire.shared.recorded.count, 0)
    }

    func testOnlyACataloguePlaylistGetsACopyRequest() {
        let rows = dfh6Rows()
        func item(_ id: String, _ detail: DiscoverItemDetail) -> DiscoverItem {
            DiscoverItem(id: id, name: "X", subtitle: nil, url: nil, artworkURL: nil, detail: detail)
        }
        let playlist = discoverCopyRequest(container: item("pl.abc", .playlist(description: nil)), rows: rows, selected: 4)
        XCTAssertEqual(playlist, DiscoverCopyRequest(playlistID: "pl.abc", playlistTitle: "X", rows: rows, selected: 4))
        XCTAssertNil(discoverCopyRequest(container: item("p.libraryPlaylist", .playlist(description: nil)), rows: rows, selected: 0))
        XCTAssertNil(discoverCopyRequest(container: item("pl.abc", .album(trackCount: nil, year: nil, genre: nil)), rows: rows, selected: 0))
        XCTAssertNil(discoverCopyRequest(container: item("1440", .album(trackCount: nil, year: nil, genre: nil)), rows: rows, selected: 0))
        XCTAssertNil(discoverCopyRequest(container: item("pl.abc", .song), rows: rows, selected: 0))
        XCTAssertNil(discoverCopyRequest(container: item("ra.1", .station(isLive: false)), rows: rows, selected: 0))
    }
}
