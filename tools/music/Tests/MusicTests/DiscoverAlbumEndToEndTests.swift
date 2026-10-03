// tools/music/Tests/MusicTests/DiscoverAlbumEndToEndTests.swift
//
// Discover "play from here" on an ALBUM, end to end over fakes (album-cleanup
// score step W). The REAL lifecycle coordinator, album transaction, journal
// and B side file (in a temporary directory), S7 recorder, sequencer, proof
// collector, song guard, cleaner, reconciler and deletion guard, composed by
// the production composer `composeDiscoverPlayRuntime`, run over the shipped
// `FakeDiscoverCopyPlayer`, `FakeLibraryRelations` and `FakeAlbumLibrary`, and
// a fake `ScriptRunner` that answers the B-script, the P-read, the song-guard
// script, the find-by-name script, the watcher's read and the container's end
// script from one scripted fake library.
//
// The fake library MODELS each script's contract; it does not run AppleScript.
// The script texts themselves are A2-A5's tests. No Music.app, no osascript,
// no socket, no audio, nothing under ~/.config/music. Built and tested with
// fakes: nothing here says it works against Music.app or Apple.
import XCTest
@testable import music

/// One row of the fake library.
struct WLibraryRow {
    var hex: String
    var title: String
    var artist: String
    var durationMS: Int
    var dateAdded: Int
    var cloud: String
    var loved = false
    var albumLoved = false
    /// The catalogue id this row is related to (what `slice.libraryRelations`
    /// counts), and from when the relation reads.
    var relatedTo: String?
    var relationVisibleAt: Date?
}

/// One user playlist of the fake library.
struct WLibraryList {
    var hex: String
    var name: String
    var smart: Bool
    var tracks: [String]
}

/// A relations reader that refreshes `FakeLibraryRelations` from the model
/// immediately before every read, then asks it (so its record holds).
final class WLiveRelations: SpanDACLibraryRelationsReading {
    private unowned let world: WAlbumWorld
    init(world: WAlbumWorld) { self.world = world }
    var offersAlbumCleanup: Bool { world.relations.offersAlbumCleanup }
    func relations(catalogueIDs: [String]) throws -> [String: [String?]] {
        world.relationsCallCount += 1
        world.beforeRelationsRead?(world.relationsCallCount)
        world.refreshRelations()
        return try world.relations.relations(catalogueIDs: catalogueIDs)
    }
}

/// Fails the journal update `failUpdate` picks (given the entry before and
/// after the change); every other call goes to the real file journal.
final class WJournal: DiscoverCopyJournalStore {
    let inner: FileDiscoverCopyJournalStore
    var failUpdate: ((_ before: DiscoverCopyEntry, _ after: DiscoverCopyEntry) -> Bool)?
    init(inner: FileDiscoverCopyJournalStore) { self.inner = inner }
    func entries() throws -> [DiscoverCopyEntry] { try inner.entries() }
    func insert(_ entry: DiscoverCopyEntry) throws { try inner.insert(entry) }
    @discardableResult
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        if let failUpdate, let before = try inner.entries().first(where: { $0.txn == txn }) {
            var after = before
            change(&after)
            if failUpdate(before, after) { throw DiscoverCopyJournalError.writeFailed("injected") }
        }
        return try inner.update(txn: txn, change)
    }
}

/// Everything an album play reaches, faked, and the production composition
/// over it. One album, one fake library, one player.
final class WAlbumWorld {
    static let relationsDelay: TimeInterval = 41

    let directory: URL
    let fileJournal: FileDiscoverCopyJournalStore
    let journal: WJournal
    let relations = FakeLibraryRelations()
    let library = FakeAlbumLibrary()
    let ops = FakeCatalogPlaylistOps()
    let player = FakeDiscoverCopyPlayer(hex: "0000000000000000", ids: [], trackK:
                                            DiscoverCopyTrack(title: "", artist: "", durationMS: nil))
    let clock = DFH6Clock()
    let status = StatusStore()
    let album: DiscoverItem
    let rows: [DiscoverItem]

    // The fake library.
    var tracks: [WLibraryRow] = []
    var lists: [WLibraryList] = []
    /// Every playlist hex the container end script may name (containers, and
    /// any copy a test registers).
    var containerHexes: [String] = []
    private(set) var beforeIDs: Set<String> = []
    private var nextAlias = 70_000

    /// How the ensure maps one catalogue id: return an existing row's hex to
    /// reuse it (a fold), or nil for the default (reuse a row related to the
    /// id, else a new subscription row added in the write's second).
    var mapOnEnsure: ((_ catalogueID: String) -> String?)?
    /// Changes a NEW row the ensure made, before it is stored.
    var tweakNewRow: ((_ catalogueID: String, _ row: inout WLibraryRow) -> Void)?
    /// Runs inside the ensure, after the rows and the container exist.
    var afterEnsure: (() -> Void)?
    /// Hexes whose P-read answers nothing (a failed call).
    var proofReadFails: Set<String> = []
    /// Told the 1-based index of every relations read, before it is answered.
    var beforeRelationsRead: ((Int) -> Void)?
    var relationsCallCount = 0

    // His modes.
    var shuffle = false
    var songRepeat: RepeatMode = .off

    // What the composition sent.
    struct GuardScript: Equatable { let hex: String; let live: [String]; let delete: Bool }
    private(set) var guardScripts: [GuardScript] = []
    /// Every script, by kind, in order: "before", "proof:<hex>", "guard:<hex>",
    /// "find", "observe", "end:delete:<hex>", "end:check:<hex>", "unknown".
    private(set) var scripts: [String] = []
    private(set) var toasts: [DiscoverToast] = []
    private(set) var albumRequests: [DiscoverCopyRequest] = []

    // The action queue: every item, and the scripts each one sent.
    private var queue: [() -> Void] = []
    private var currentItem: [String]?
    private(set) var items: [[String]] = []

    private(set) var runtime: DiscoverPlayRuntime!
    private(set) var lifecycle: DiscoverLifecycleCoordinator!

    init(rows: [DiscoverItem], album: DiscoverItem? = nil,
         spandacDataSelected: (() -> Bool)? = nil) {
        self.rows = rows
        self.album = album ?? DiscoverItem(id: albumTestAlbumID, name: albumTestAlbum, subtitle: "Album Artist",
                                           url: nil, artworkURL: nil,
                                           detail: .album(trackCount: rows.count, year: nil, genre: nil))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-w-album-\(UUID().uuidString)")
        precondition(!directory.path.contains("/.config/music"), "a test journal must be temporary")
        fileJournal = FileDiscoverCopyJournalStore(paths: DiscoverCopyPaths(directory: directory))
        journal = WJournal(inner: fileJournal)

        // His library before any play: two songs of his, on no album here.
        tracks = [
            WLibraryRow(hex: "00000000000ABC01", title: "His Song", artist: "Someone", durationMS: 200_000,
                        dateAdded: 1_300_000_000, cloud: "subscription"),
            WLibraryRow(hex: "00000000000ABC02", title: "His Other Song", artist: "Someone", durationMS: 210_000,
                        dateAdded: 1_300_000_100, cloud: "matched"),
        ]
        library.onEnsure = { [unowned self] in ensure() }
        let liveRelations = WLiveRelations(world: self)
        let parts = DiscoverCopyRuntimeParts(
            journal: journal,
            ops: { [unowned self] in ops },
            spandacDataSelected: spandacDataSelected ?? { true },
            player: player,
            modes: DiscoverModeGuard.Seams(
                read: { [unowned self] in (shuffle, songRepeat) },
                setShuffle: { [unowned self] on in shuffle = on; return true },
                setRepeat: { [unowned self] mode in songRepeat = mode; return true },
                restore: { [unowned self] request in
                    dfhModeRestoreContract(request, modes: (shuffle, songRepeat), player: playerRead) { s, r in
                        if let s { shuffle = s }
                        if let r { songRepeat = r }
                        return (shuffle, songRepeat)
                    }
                }),
            run: { [unowned self] in run($0) },
            now: { [clock] in clock.now() },
            sleep: { [clock] in clock.advance($0) },
            log: { _ in },
            enqueue: { [unowned self] in queue.append($0) })
        let poster = discoverToastPoster(status: status)
        var composed = composeDiscoverPlayRuntime(parts, album: DiscoverAlbumRuntimeParts(
            beforeSet: fileJournal,
            library: { [unowned self] in library },
            relations: { liveRelations },
            runBeforeSet: { [unowned self] in run($0) },
            runProofRead: { [unowned self] in run($0) },
            runGuard: { [unowned self] in run($0) },
            post: { [unowned self] toast in toasts.append(toast); poster(toast) }))
        var albumSeams = composed.album
        let sequence = albumSeams.sequence
        albumSeams.sequence = { [unowned self] hex, txn, request, gate, progress, commit in
            albumRequests.append(request)
            return sequence(hex, txn, request, gate, progress, commit)
        }
        composed = DiscoverPlayRuntime(copy: composed.copy, album: albumSeams, watcher: composed.watcher,
                                       collector: composed.collector, cleaner: composed.cleaner,
                                       handleEnd: composed.handleEnd)
        runtime = composed
        let coordinator = makeDiscoverLifecycleCoordinator(backend: AppleScriptBackend(), status: status,
                                                           copy: composed.copy, album: composed.album)
        coordinator.completeLaunchSweep(.swept)
        lifecycle = coordinator
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    // MARK: The model

    func hexFor(alias: Int) -> String { persistentIDHex(fromAlias: "\(alias)")! }

    private func mintAlias() -> Int {
        nextAlias += 1
        return nextAlias
    }

    /// Adds a row of his before any play (it is then in B).
    @discardableResult
    func addHisRow(title: String, artist: String = "Album Artist", durationMS: Int, dateAdded: Int,
                   cloud: String, relatedTo: String? = nil) -> String {
        let hex = hexFor(alias: mintAlias())
        tracks.append(WLibraryRow(hex: hex, title: title, artist: artist, durationMS: durationMS,
                                  dateAdded: dateAdded, cloud: cloud, relatedTo: relatedTo,
                                  relationVisibleAt: relatedTo == nil ? nil : clock.now()))
        return hex
    }

    func row(_ hex: String) -> WLibraryRow? { tracks.first { $0.hex == hex } }

    /// FakeLibraryRelations answers the model as it is now: every row related
    /// to an id, once its relation reads.
    func refreshRelations() {
        let now = clock.now()
        var map: [String: [String?]] = [:]
        for item in rows { map[item.id] = [] }
        for track in tracks {
            guard let id = track.relatedTo, let at = track.relationVisibleAt, at <= now else { continue }
            let alias = String(UInt64(track.hex, radix: 16)!)
            map[id, default: []].append(alias)
        }
        relations.results = [.success(map)]
    }

    /// The ensure: the container, and a row per catalogue id.
    private func ensure() {
        guard let call = library.calls.last, call.hasPrefix("ensure:") else { return }
        let body = String(call.dropFirst("ensure:".count))
        guard let split = body.lastIndex(of: ":") else { return }
        let name = String(body[..<split])
        let ids = body[body.index(after: split)...].split(separator: ",").map(String.init)
        let now = clock.now()
        var hexes: [String] = []
        for id in ids {
            if let mapped = mapOnEnsure?(id) {
                hexes.append(mapped)
                continue
            }
            if let related = tracks.first(where: { $0.relatedTo == id }) {
                hexes.append(related.hex)
                continue
            }
            guard let item = rows.first(where: { $0.id == id }) else { continue }
            var ms = 0
            if case .milliseconds(let value) = item.length { ms = value }
            var new = WLibraryRow(hex: hexFor(alias: mintAlias()), title: item.name, artist: item.subtitle ?? "",
                                  durationMS: ms, dateAdded: Int(floor(now.timeIntervalSince1970)),
                                  cloud: "subscription", relatedTo: id,
                                  relationVisibleAt: now.addingTimeInterval(Self.relationsDelay))
            tweakNewRow?(id, &new)
            tracks.append(new)
            hexes.append(new.hex)
        }
        let containerAlias = mintAlias()
        let containerHex = hexFor(alias: containerAlias)
        lists.append(WLibraryList(hex: containerHex, name: name, smart: false, tracks: hexes))
        containerHexes.append(containerHex)
        library.ensureResults = [.success((created: true, id: "p.W\(containerAlias)", alias: "\(containerAlias)"))]
        // What Music.app would play: the container, track 1 of the slice.
        player.hex = containerHex
        player.ids = hexes
        if let first = ids.first, let item = rows.first(where: { $0.id == first }) {
            var ms: Int?
            if case .milliseconds(let value) = item.length { ms = value }
            player.trackK = DiscoverCopyTrack(title: item.name, artist: item.subtitle ?? "", durationMS: ms)
        }
        afterEnsure?()
    }

    var playerRead: DiscoverCopyPlayerRead {
        let state: String
        switch player.state {
        case .stopped: state = "stopped"
        case .playing: state = "playing"
        case .paused: state = "paused"
        }
        let track = player.currentIndex.flatMap { player.ids.indices.contains($0) ? player.ids[$0] : nil }
        return DiscoverCopyPlayerRead(state: state, playlistID: player.currentPlaylist, trackID: track)
    }

    private static let hexPattern = try! NSRegularExpression(pattern: #"persistent ID is "([0-9A-F]{16})""#)
    private static let livePattern = try! NSRegularExpression(pattern: #"plIDText is "([0-9A-F]{16})""#)
    private static let namePattern = try! NSRegularExpression(pattern: #"if plNameText is "((?:[^"\\]|\\.)*)" then"#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func note(_ kind: String) {
        scripts.append(kind)
        currentItem?.append(kind)
    }

    /// The fake `ScriptRunner`, answering each script's contract from the model.
    private func run(_ script: String) -> String? {
        if script == discoverCopyObservationScript {
            note("observe")
            let read = playerRead
            return "\(read.state)|\(read.playlistID ?? "")|\(read.trackID ?? "")"
        }
        if script == discoverAlbumBeforeSetScript {
            note("before")
            return tracks.map(\.hex).joined(separator: "\n")
        }
        for hex in containerHexes {
            for delete in [true, false] where script == discoverCopyEndScript(hex: hex, delete: delete) {
                note((delete ? "end:delete:" : "end:check:") + hex)
                guard let index = lists.firstIndex(where: { $0.hex == hex }) else { return "gone" }
                if player.state != .stopped, player.currentPlaylist == hex { return "spared" }
                guard delete else { return "kept" }
                lists.remove(at: index)
                return "deleted"
            }
        }
        if script.contains("foundText") {
            note("find")
            guard let wanted = Self.matches(Self.namePattern, script).first else { return nil }
            let found = lists.filter { escapeAppleScriptString($0.name) == wanted }.map(\.hex)
            return (["ok"] + found).joined(separator: "\n")
        }
        if script.contains("fieldSep") {
            guard let hex = Self.matches(Self.hexPattern, script).first else { return nil }
            note("proof:" + hex)
            if proofReadFails.contains(hex) { return nil }
            let sep = "\u{1F}"
            let hits = tracks.filter { $0.hex == hex }
            guard hits.count == 1, let found = hits.first else { return "count\(sep)\(hits.count)" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let added = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(found.dateAdded)))
            return ["ok", found.title, found.artist, "\(found.durationMS)", added, found.cloud].joined(separator: sep)
        }
        if script.contains("liveHolds") {
            guard let hex = Self.matches(Self.hexPattern, script).first else { return nil }
            let live = Self.matches(Self.livePattern, script)
            let delete = script.contains("delete songRef")
            note("guard:" + hex)
            guardScripts.append(GuardScript(hex: hex, live: live, delete: delete))
            let hits = tracks.filter { $0.hex == hex }
            if hits.isEmpty { return "gone" }
            if hits.count != 1 { return "unreadable" }
            var liveHolds = false
            for list in lists where !list.smart && list.tracks.contains(hex) {
                if live.contains(list.hex) { liveHolds = true } else { return "kept|playlist|" + list.name }
            }
            if liveHolds { return "spared" }
            let found = hits[0]
            if found.loved { return "kept|loved" }
            if found.albumLoved { return "kept|album" }
            if player.state != .stopped {
                let current = playerRead.trackID
                if current == nil || current == hex { return "spared" }
            }
            guard delete else { return "checked" }
            tracks.removeAll { $0.hex == hex }
            for index in lists.indices { lists[index].tracks.removeAll { $0 == hex } }
            return "deleted"
        }
        note("unknown")
        return nil
    }

    // MARK: Driving it

    /// Runs the action queue to empty, recording each item's scripts.
    func runQueue() {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            currentItem = []
            item()
            items.append(currentItem ?? [])
            currentItem = nil
        }
    }

    /// The poller: one tick a second, then the queue.
    func advance(_ seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(1)
            runtime.watcher.tick()
            runtime.collector.tick()
            runtime.cleaner.tick()
            runQueue()
        }
    }

    /// Enter on row `selected` of the album: phase A, then phase B on this thread.
    @discardableResult
    func play(from selected: Int) -> DiscoverPlayRequestOutcome? {
        if beforeIDs.isEmpty { beforeIDs = Set(tracks.map(\.hex)) }
        guard let request = discoverAlbumRequest(container: album, rows: rows, selected: selected),
              case .reserved(let slot) = lifecycle.reserveCopyPlay(request) else { return nil }
        let outcome = lifecycle.runCopyPlay(slot, gate: FakeDiscoverCopyGate().gate)
        runQueue()
        return outcome
    }

    /// He stops: the watcher sees `stopped` long enough, and the end runs.
    func stop() {
        _ = player.stop()
        advance(5)
    }

    /// A relaunch's journal replay (the launch sweep's reconcile), on the real reconciler.
    func relaunchReconcile() {
        DiscoverCopyReconciler(copy: runtime.copy, post: { [unowned self] in toasts.append($0) },
                               albumReplay: runtime.album.replay).run(atLaunch: true)
        runQueue()
    }

    func entries() -> [DiscoverCopyEntry] { (try? fileJournal.entries()) ?? [] }
    func entry(_ index: Int = 0) -> DiscoverCopyEntry? { entries().indices.contains(index) ? entries()[index] : nil }
    func songStates(_ index: Int = 0) -> [DiscoverAlbumSongState] { entry(index)?.songs?.map(\.state) ?? [] }
    func entryHexes(_ index: Int = 0) -> [String] { entry(index)?.entryIDs ?? [] }

    /// The before file's path for entry `index`, if recorded.
    func beforeFilePath(_ index: Int = 0) -> String? {
        entry(index)?.beforeFile.map { directory.appendingPathComponent($0).path }
    }

    /// The text of every toast, in order.
    var toastTexts: [String] {
        toasts.map { toast in
            switch toast {
            case .outcome(let outcome, let title): return discoverToastMessage(for: outcome, title: title).text
            case .progress(let text): return text
            case .startupCleanup: return discoverStartupCleanupToastText
            }
        }
    }
}

/// Four album songs, 200 s to 203 s long.
func wAlbumRows(_ count: Int = 4) -> [DiscoverItem] {
    albumTestRows((0..<count).map { .milliseconds(200_000 + $0 * 1_000) })
}

final class DiscoverAlbumEndToEndTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ExternalCallTripwire.shared.arm()
    }

    override func tearDown() {
        let escaped = ExternalCallTripwire.shared.disarm()
        XCTAssertEqual(escaped.count, 0, "a call escaped the fakes: \(escaped)")
        super.tearDown()
    }

    /// Plays from row 0, lets the relations appear and the proof finish.
    private func playAndProve(_ world: WAlbumWorld, from selected: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) {
        let outcome = world.play(from: selected)
        guard case .completed(.listening)? = outcome else {
            return XCTFail("the album did not play: \(String(describing: outcome))", file: file, line: line)
        }
        world.advance(60)
    }

    // MARK: (a) ordinary

    /// Four new rows; the relations appear at fake 41 s; every song is
    /// `owned`. The end deletes the container, then the songs in album order,
    /// one action-queue item each, and the library is back to its before-set.
    func testOrdinaryPlayProvesEverySongThenTheEndRemovesTheContainerThenEachSong() throws {
        let world = WAlbumWorld(rows: wAlbumRows())

        let outcome = world.play(from: 0)

        guard case .completed(.listening)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(world.albumRequests.first?.kind, .albumContainer)
        XCTAssertEqual(world.player.currentPlaylist, world.lists.last?.hex, "the container plays")
        XCTAssertEqual(world.status.current()?.text, "Playing " + discoverAlbumPlayingTail(song: "Track 1"))
        let newRows = world.entryHexes()
        XCTAssertEqual(newRows.count, 4)
        XCTAssertTrue(world.beforeIDs.isDisjoint(with: newRows), "four NEW rows")
        XCTAssertEqual(world.songStates(), [.pending, .pending, .pending, .pending])
        let beforeFile = try XCTUnwrap(world.beforeFilePath())
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeFile), "B is on disk beside the journal")

        world.advance(40)
        XCTAssertEqual(world.songStates(), [.pending, .pending, .pending, .pending], "no relation before 41 s")
        world.advance(20)
        XCTAssertEqual(world.songStates(), [.owned, .owned, .owned, .owned])
        XCTAssertEqual(world.guardScripts, [], "nothing is deleted while he listens")

        let itemsBefore = world.items.count
        world.stop()

        let endItems = Array(world.items[itemsBefore...]).filter { !$0.isEmpty }
        let container = try XCTUnwrap(world.containerHexes.first)
        XCTAssertEqual(endItems.first, ["end:delete:\(container)"], "the container goes first, alone")
        XCTAssertEqual(Array(endItems.dropFirst()), newRows.map { ["guard:\($0)"] },
                       "then each song, in album order, one item each")
        XCTAssertEqual(world.guardScripts.map(\.delete), [true, true, true, true])
        XCTAssertEqual(Set(world.tracks.map(\.hex)), world.beforeIDs, "the library is back to its before-set")
        XCTAssertEqual(world.lists.map(\.hex), [], "the container is gone")
        XCTAssertEqual(world.songStates(), [.deleted, .deleted, .deleted, .deleted])
        XCTAssertEqual(world.entry()?.state, .closed)
        XCTAssertEqual(world.toastTexts.last, discoverAlbumAllRemovedText(album: albumTestAlbum))
        XCTAssertFalse(FileManager.default.fileExists(atPath: beforeFile), "B's side file goes on close")
    }

    // MARK: (b) design test 5

    /// R2 reads a relation for song 2 (he added it between R1 and R2): it is
    /// `preexisting`, the play goes on, and no song-guard script ever names it.
    func testASongWithARelationAtR2IsPreexistingAndNoGuardScriptNamesIt() throws {
        let world = WAlbumWorld(rows: wAlbumRows())
        var his: String?
        world.beforeRelationsRead = { [unowned world] call in
            guard call == 2, his == nil else { return }
            his = world.addHisRow(title: "Track 2", artist: "Album Artist", durationMS: 201_000,
                                  dateAdded: 1_700_000_000, cloud: "subscription",
                                  relatedTo: albumTestCatalogueID(2))
        }

        playAndProve(world)
        world.stop()

        let hisHex = try XCTUnwrap(his)
        XCTAssertEqual(world.entry()?.songs?[1].relationsBefore, [0, 1])
        XCTAssertEqual(world.entryHexes()[1], hisHex, "the ensure reused his row")
        XCTAssertEqual(world.songStates(), [.deleted, .preexisting, .deleted, .deleted])
        XCTAssertFalse(world.guardScripts.contains { $0.hex == hisHex }, "a guard script named his song")
        XCTAssertNotNil(world.row(hisHex), "his song is still in his library")
        XCTAssertEqual(world.entry()?.state, .closed)
    }

    // MARK: (c) design test 8

    /// The S7 recorder's write fails: nothing plays, the container is deleted,
    /// every song is `uncertain` (P3's first half cannot hold) and he is told,
    /// at the end and once more at the next launch; then the entry closes.
    func testAFailedRecorderWriteLeavesEverySongUncertainAndTold() throws {
        let world = WAlbumWorld(rows: wAlbumRows())
        world.journal.failUpdate = { before, after in before.entryIDs == nil && after.entryIDs != nil }

        let outcome = world.play(from: 0)

        guard case .completed(.failedBeforePlay(_, .identity))? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(world.player.commands, [], "nothing played")
        XCTAssertEqual(world.lists.map(\.hex), [], "the container was deleted")
        XCTAssertEqual(world.entry()?.containerGone, true)
        XCTAssertEqual(world.status.current()?.text,
                       discoverAlbumRefusalText(.unconfirmed(title: "Track 1"), album: albumTestAlbum))
        let added = Set(world.tracks.map(\.hex)).subtracting(world.beforeIDs)
        XCTAssertEqual(added.count, 4)

        world.advance(60)

        XCTAssertEqual(world.songStates(), [.uncertain, .uncertain, .uncertain, .uncertain])
        XCTAssertEqual(world.entry()?.endTold, true)
        let left = discoverAlbumLeftText(titles: ["Track 1", "Track 2", "Track 3", "Track 4"], album: albumTestAlbum)
        XCTAssertEqual(world.toastTexts.last, left, "told at the end")
        XCTAssertEqual(world.guardScripts, [], "no song reached the guard")
        XCTAssertEqual(Set(world.tracks.map(\.hex)).subtracting(world.beforeIDs), added, "every song was left")
        XCTAssertNotEqual(world.entry()?.state, .closed, "open until the launch repeat")

        world.relaunchReconcile()

        XCTAssertEqual(world.toastTexts.last, left, "told once more at the next launch")
        XCTAssertEqual(world.entry()?.songs?.map(\.toldAtLaunch), [true, true, true, true])
        XCTAssertEqual(world.entry()?.state, .closed)
        let toldCount = world.toastTexts.filter { $0 == left }.count
        world.relaunchReconcile()
        XCTAssertEqual(world.toastTexts.filter { $0 == left }.count, toldCount, "never a third time")
    }

    // MARK: (d) design test 21

    /// Decision 5, pinned so the accepted residual stays visible: he adds song
    /// 2 himself while it plays, and Apple folds his add into OUR row (same
    /// e_i, still one relation). Nothing tells the two apart, so it is deleted.
    func testHisAddFoldedIntoOurRowIsDeleted() {
        let world = WAlbumWorld(rows: wAlbumRows())
        playAndProve(world)
        let ours = world.entryHexes()[1]
        // The fold: no new row, the same relation; the model is unchanged.
        let rowsBefore = world.tracks.count
        world.refreshRelations()
        XCTAssertEqual(world.tracks.filter { $0.relatedTo == albumTestCatalogueID(2) }.map(\.hex), [ours])
        XCTAssertEqual(world.tracks.count, rowsBefore)

        world.stop()

        XCTAssertEqual(world.songStates()[1], .deleted)
        XCTAssertTrue(world.guardScripts.contains { $0.hex == ours && $0.delete })
        XCTAssertNil(world.row(ours), "his folded add went with our row (decision 5)")
    }

    // MARK: (e) design test 22

    private enum Arm3: String, CaseIterable {
        case relationBefore, reusedInBFreshDate, reusedMatchedWithRelation, titleMismatch,
             addedOneSecondEarly, addedThreeSecondsLate, addedTwoSecondsLate, measured, duplicateRow,
             unreadableRead
    }

    /// Every row of section 5's table, each one alone, with song 3 his: his
    /// original's ID appears in no song-guard script ever sent, and his row is
    /// still in his library after the end.
    func testArmThreeRowsNeverNameHisOriginalInAGuardScript() {
        for arm in Arm3.allCases {
            let world = WAlbumWorld(rows: wAlbumRows())
            let c3 = albumTestCatalogueID(3)
            var expected3: DiscoverAlbumSongState
            let his: String
            switch arm {
            case .relationBefore:
                his = world.addHisRow(title: "Track 3", durationMS: 202_000, dateAdded: 1_382_000_000,
                                      cloud: "subscription", relatedTo: c3)
                expected3 = .preexisting
            case .reusedInBFreshDate:
                his = world.addHisRow(title: "Something Else", durationMS: 202_000, dateAdded: 1_382_000_000,
                                      cloud: "subscription")
                world.mapOnEnsure = { [unowned world] id in
                    guard id == c3 else { return nil }
                    if let index = world.tracks.firstIndex(where: { $0.hex == his }) {
                        world.tracks[index].dateAdded = Int(world.clock.now().timeIntervalSince1970)
                    }
                    return his
                }
                expected3 = .preexisting
            case .reusedMatchedWithRelation:
                his = world.addHisRow(title: "Track 3", durationMS: 202_000, dateAdded: 1_382_000_000,
                                      cloud: "matched")
                world.mapOnEnsure = { [unowned world] id in
                    guard id == c3 else { return nil }
                    if let index = world.tracks.firstIndex(where: { $0.hex == his }) {
                        world.tracks[index].relatedTo = c3
                        world.tracks[index].relationVisibleAt = world.clock.now().addingTimeInterval(41)
                    }
                    return his
                }
                expected3 = .preexisting
            case .titleMismatch, .addedOneSecondEarly, .addedThreeSecondsLate, .addedTwoSecondsLate,
                 .unreadableRead, .duplicateRow:
                his = world.addHisRow(title: "Track 3", durationMS: 202_000, dateAdded: 1_382_000_000,
                                      cloud: "matched")
                expected3 = .uncertain
                world.tweakNewRow = { [unowned world] id, row in
                    guard id == c3 else { return }
                    switch arm {
                    case .titleMismatch: row.title = "track 3"
                    case .addedOneSecondEarly: row.dateAdded -= 1
                    case .addedThreeSecondsLate: row.dateAdded += 3
                    case .addedTwoSecondsLate: row.dateAdded += 2
                    case .unreadableRead: world.proofReadFails.insert(row.hex)
                    case .duplicateRow:
                        if let index = world.tracks.firstIndex(where: { $0.hex == his }) {
                            world.tracks[index].relatedTo = c3
                            world.tracks[index].relationVisibleAt = row.relationVisibleAt
                        }
                    default: break
                    }
                }
                if arm == .addedTwoSecondsLate { expected3 = .deleted }
            case .measured:
                his = world.addHisRow(title: "Track 3", durationMS: 202_100, dateAdded: 1_382_468_207,
                                      cloud: "matched")
                world.mapOnEnsure = { id in id == c3 ? his : nil }
                expected3 = .preexisting
            }

            playAndProve(world)
            world.stop()
            world.advance(Int(DiscoverAlbumTiming.retryInterval) + 2)

            XCTAssertFalse(world.guardScripts.contains { $0.hex == his },
                           "\(arm): a guard script named his original")
            XCTAssertNotNil(world.row(his), "\(arm): his original left his library")
            XCTAssertEqual(world.songStates(), [.deleted, .deleted, expected3, .deleted], "\(arm)")
            if expected3 == .uncertain {
                let third = world.entryHexes()[2]
                XCTAssertNotNil(world.row(third), "\(arm): an unproven row was deleted")
                XCTAssertTrue(world.toastTexts.last?.contains("Track 3") == true, "\(arm): he is told")
            }
        }
    }

    // MARK: (f) L2-shaped

    /// Before he stops, he loves song 2 and puts song 3 in a scratch playlist:
    /// both are kept and named, the other two removed.
    func testALovedSongAndASongInHisPlaylistAreKeptAndTold() {
        let world = WAlbumWorld(rows: wAlbumRows())
        playAndProve(world)
        let hexes = world.entryHexes()
        if let index = world.tracks.firstIndex(where: { $0.hex == hexes[1] }) { world.tracks[index].loved = true }
        world.lists.append(WLibraryList(hex: "00000000000F00D5", name: "Scratch", smart: false, tracks: [hexes[2]]))

        world.stop()

        XCTAssertEqual(world.songStates(), [.deleted, .kept, .kept, .deleted])
        XCTAssertEqual(world.entry()?.songs?[1].keptReason, "loved")
        XCTAssertEqual(world.entry()?.songs?[2].keptReason, "playlist")
        XCTAssertEqual(world.entry()?.songs?[2].keptPlaylist, "Scratch")
        XCTAssertNotNil(world.row(hexes[1]))
        XCTAssertNotNil(world.row(hexes[2]))
        XCTAssertNil(world.row(hexes[0]))
        XCTAssertNil(world.row(hexes[3]))
        let kept = world.entry()?.songs?.filter { $0.state == .kept } ?? []
        XCTAssertEqual(world.toastTexts.last, discoverAlbumKeptText(kept: kept, album: albumTestAlbum, removed: 2))
        XCTAssertEqual(world.toastTexts.last,
                       "Kept 'Track 2' (loved) and 'Track 3' (in 'Scratch') from 'Test Album'; removed the other 2.")
        XCTAssertEqual(world.entry()?.state, .closed)
    }

    // MARK: (g) CH15

    /// A second play of the same album, from song 3, while the first's songs
    /// await the guard: the second container reuses rows 3 and 4 (his now, so
    /// `preexisting` there). When the first play ends, songs 1 and 2 go; 3 and
    /// 4 are `spared` while the second container lives, and go once it is gone.
    func testASecondPlayOfTheSameAlbumSparesTheSharedSongsUntilItsContainerIsGone() throws {
        let world = WAlbumWorld(rows: wAlbumRows())
        playAndProve(world)
        let first = world.entryHexes()
        XCTAssertEqual(world.songStates(), [.owned, .owned, .owned, .owned])

        let outcome = world.play(from: 2)

        guard case .completed(.listening)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(world.entries().count, 2)
        XCTAssertEqual(world.entryHexes(1), [first[2], first[3]], "the second container reuses rows 3 and 4")
        XCTAssertEqual(world.songStates(1), [.preexisting, .preexisting])
        XCTAssertEqual(world.status.current()?.text, "Playing " + discoverAlbumPlayingOwnedTail(song: "Track 3"))
        let second = try XCTUnwrap(world.entry(1)?.hex)

        // The first container is no longer current: the watcher ends it.
        world.advance(5)

        XCTAssertEqual(world.entry()?.containerGone, true)
        XCTAssertEqual(world.songStates(), [.deleted, .deleted, .owned, .owned])
        let shared = world.guardScripts.filter { $0.hex == first[2] || $0.hex == first[3] }
        XCTAssertEqual(shared.map(\.hex), [first[2], first[3]])
        XCTAssertTrue(shared.allSatisfy { $0.live == [second] }, "the live container is named in the scan")
        XCTAssertNotNil(world.row(first[2]))
        XCTAssertNotNil(world.row(first[3]))

        // Still playing the second container: spared again at the retry.
        world.advance(Int(DiscoverAlbumTiming.retryInterval) + 1)
        XCTAssertEqual(world.songStates(), [.deleted, .deleted, .owned, .owned])
        XCTAssertNotNil(world.row(first[2]))

        // He stops: the second container goes, then the shared songs.
        world.stop()
        XCTAssertEqual(world.entry(1)?.state, .closed)
        world.advance(Int(DiscoverAlbumTiming.retryInterval) + 1)

        XCTAssertEqual(world.songStates(), [.deleted, .deleted, .deleted, .deleted])
        XCTAssertEqual(world.guardScripts.last(where: { $0.hex == first[3] })?.live, [])
        XCTAssertEqual(Set(world.tracks.map(\.hex)), world.beforeIDs)
        XCTAssertEqual(world.entry()?.state, .closed)
        XCTAssertEqual(world.toastTexts.last, discoverAlbumAllRemovedText(album: albumTestAlbum))
    }

    // MARK: The composition's own seams

    /// The production runtime builds with a temporary path and writes nothing
    /// until a play does; its watcher, collector and cleaner run no script and
    /// enqueue nothing while they have nothing to do.
    func testTheProductionPlayRuntimeIsInertUntilAPlay() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-w-album-\(UUID().uuidString)")
        let stores = NSTemporaryDirectory() + "music-w-routing-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: stores, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stores) }
        let routing = RoutingCoordinator(store: PlaybackModeStore(path: stores + "/mode.json"), surface: .tui,
                                         dataStore: DataProviderStore(path: stores + "/data.json"),
                                         makeSourceFor: { _ in SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) },
                                         makeDataClient: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) },
                                         starter: NeverStartsMacSpanDAC())
        var enqueued = 0
        let runtime = makeDiscoverPlayRuntime(backend: AppleScriptBackend(), routing: routing,
                                              paths: DiscoverCopyPaths(directory: directory),
                                              status: StatusStore(), enqueue: { _ in enqueued += 1 })

        runtime.watcher.tick()
        runtime.collector.tick()
        runtime.cleaner.tick()
        XCTAssertFalse(runtime.copy.spandacDataSelected(), "MusicTUI's own data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(enqueued, 0)
        XCTAssertEqual(ExternalCallTripwire.shared.recorded.count, 0)
    }

    /// One watcher ends both kinds: a copy entry's end goes through the copy
    /// path's end (closed, no song phase), an album entry's through the album
    /// end (container gone, then its songs).
    func testTheOneWatcherDispatchesTheEndByEntryKind() throws {
        let world = WAlbumWorld(rows: wAlbumRows())
        playAndProve(world)
        let albumTxn = try XCTUnwrap(world.entry()?.txn)

        // A copy entry beside it, whose copy is not in the library.
        let copyTxn = "C0C0C0C0-0000-4000-8000-00000000C0C0"
        try world.fileJournal.insert(DiscoverCopyEntry(
            txn: copyTxn, playlistID: "pl.x", title: "A Playlist", state: .listening,
            hex: "0000000000C0FFEE", copiesRead: 1, watching: true, copySeen: true, toldAtLaunch: false,
            priorShuffle: nil, priorRepeat: nil, createdAt: 5, updatedAt: 5))
        world.containerHexes.append("0000000000C0FFEE")
        _ = world.player.stop()

        world.runtime.handleEnd(copyTxn)
        world.runQueue()
        XCTAssertEqual(world.entries().first { $0.txn == copyTxn }?.state, .closed, "the copy end closes a copy")
        XCTAssertEqual(world.guardScripts, [])

        world.runtime.handleEnd(albumTxn)
        world.runQueue()
        let album = try XCTUnwrap(world.entries().first { $0.txn == albumTxn })
        XCTAssertEqual(album.containerGone, true)
        XCTAssertEqual(album.listeningEnded, true)
        XCTAssertEqual(album.songs?.map(\.state), [.deleted, .deleted, .deleted, .deleted])
        XCTAssertEqual(album.state, .closed)
    }
}
