// tools/music/Tests/MusicTests/SpanDACLibraryAddTests.swift
//
// Score: data route and output, step 10 (C-ADD). A song the person does not
// own plays on the MusicTUI output by the shipped add-then-play path, with
// SpanDAC on this Mac making the add instead of the developer key.
//
// Nothing here reaches a real SpanDAC, Apple's Music app, the library, the
// network or ~/.config/music. SpanDAC is `FakeSpanDACMac`, a scripted wire that
// keeps the library ops' semantics in memory; Apple's Music app is
// `FakeAppleLibrary`, a script runner answering the few AppleScript reads the
// path makes. Every play is a fake container build; the watcher launch is a
// counting closure. The external-call tripwire is armed wherever a production
// object is built, so an AppleScript, REST or launch call would be recorded.
import XCTest
@testable import music

// MARK: - Fakes

/// The library as AppleScript sees it, and as SpanDAC's ops change it.
final class FakeAppleLibrary {
    struct Track {
        let pid: String
        let name: String
        let artist: String
        let album: String
        /// The name read after which this row is visible (sync lag).
        let visibleAfter: Int
    }

    private let lock = NSLock()
    private var tracks: [Track] = []
    private var nextPID: UInt64 = 0xA0
    /// Catalogue id → what an add of it creates.
    var catalogue: [String: (name: String, artist: String, album: String)] = [:]
    /// Catalogue id → the persistent ID of its library copy, once owned.
    private(set) var owned: [String: String] = [:]
    /// Whether `libraryLookup` reports an owned song's alias.
    var aliasVisible = true
    /// How many rows one add creates (2 = an ambiguous arrival).
    var copiesPerAdd = 1
    /// Name reads after an add before its rows show.
    var rowLag = 0
    /// Name reads fail (an unreadable library).
    var nameReadsFail = false

    private(set) var nameReads = 0
    private(set) var events: [String] = []
    private(set) var seeded: [String] = []
    private(set) var launches = 0

    private func log(_ e: String) { events.append(e) }
    func record(_ e: String) { lock.lock(); log(e); lock.unlock() }
    var allEvents: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var allSeeded: [String] { lock.lock(); defer { lock.unlock() }; return seeded }

    static func alias(_ pid: String) -> String { String(UInt64(pid, radix: 16)!) }

    /// A song already in the library.
    @discardableResult
    func own(catalogueID: String?, name: String, artist: String, album: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let pid = mint()
        tracks.append(Track(pid: pid, name: name, artist: artist, album: album, visibleAfter: 0))
        if let catalogueID { owned[catalogueID] = pid }
        return pid
    }

    private func mint() -> String {
        nextPID += 1
        return String(format: "%016llX", nextPID)
    }

    /// SpanDAC's add, applied: idempotent for a song already owned.
    func applyAdd(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids where owned[id] == nil {
            guard let meta = catalogue[id] else { continue }
            var first: String?
            for _ in 0..<copiesPerAdd {
                let pid = mint()
                first = first ?? pid
                tracks.append(Track(pid: pid, name: meta.name, artist: meta.artist, album: meta.album,
                                    visibleAfter: nameReads + rowLag))
            }
            owned[id] = first
        }
    }

    /// A song added to a playlist SpanDAC makes: the playlist's track is the
    /// library copy (one persistent ID), made now when the song is not owned.
    func ownForPlaylist(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let pid = owned[id] { return pid }
        let meta = catalogue[id] ?? (name: "Song \(id)", artist: "Artist", album: "Album")
        let pid = mint()
        tracks.append(Track(pid: pid, name: meta.name, artist: meta.artist, album: meta.album, visibleAfter: 0))
        owned[id] = pid
        return pid
    }

    /// The identity read (`persistentIDVerificationScript`) through this
    /// library's own script answers.
    var persistentIDReader: AppleScriptPersistentIDReader {
        struct Unreadable: Error {}
        return AppleScriptPersistentIDReader(run: { [unowned self] script in
            guard let out = self.answer(script) else { throw Unreadable() }
            return out
        })
    }

    func lookupAlias(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard aliasVisible, let pid = owned[id] else { return nil }
        return Self.alias(pid)
    }

    /// The runner handed to the path under test.
    lazy var run: ScriptRunner = { [unowned self] script in self.answer(script) }
    lazy var launch: ProcessLauncher = { [unowned self] _, _ in
        self.lock.lock(); self.launches += 1; self.lock.unlock(); return true
    }

    private func pid(in script: String) -> String? {
        guard let r = script.range(of: #"persistent ID is "([0-9A-F]+)""#, options: .regularExpression) else { return nil }
        return String(script[r].dropFirst("persistent ID is \"".count).dropLast())
    }

    private func answer(_ script: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if script.contains("make new playlist") {
            let p = pid(in: script) ?? "?"
            seeded.append(p); log("build:\(p)")
            return "1"
        }
        if script.contains("set ids to persistent ID") { return seeded.last }
        if script.contains("repeat with idRef in {") {
            // The one identity check's read: a line per track found.
            let list = script.components(separatedBy: "repeat with idRef in {").dropFirst().first?
                .components(separatedBy: "}").first ?? ""
            let fs = "\u{1F}"
            var out = ""
            for p in list.components(separatedBy: ", ").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }) {
                log("verify:\(p)")
                for (i, t) in tracks.enumerated() where t.pid == p && t.visibleAfter < nameReads + 1 {
                    out += [p, "L", "db\(i)", "\(i + 1)", t.name].joined(separator: fs) + "\n"
                }
            }
            return out
        }
        if script.contains("whose name contains") {
            nameReads += 1
            log("nameRead")
            if nameReadsFail { return nil }
            let title = script.components(separatedBy: "whose name contains \"").dropFirst().first?
                .components(separatedBy: "\")").first ?? ""
            let rows = tracks.filter { $0.name.contains(title) && $0.visibleAfter < nameReads }
            let fs = "\u{1F}", rs = "\u{1E}"
            return "\(rows.count)" + rs + rows.map {
                [$0.pid, $0.name, $0.artist, $0.album, "subscribed"].joined(separator: fs) + rs
            }.joined()
        }
        return ""
    }

    var seams: CatalogAddPlaySeams {
        CatalogAddPlaySeams(run: run, launch: launch, wait: { _ in })
    }
}

/// SpanDAC on this Mac, as its library ops behave on the wire: a scripted
/// transport over `FakeAppleLibrary`.
final class FakeSpanDACMac {
    enum Write {
        case apply
        /// Carried out, then the reply is lost (the client times out).
        case applyThenLoseReply
        /// Lost before SpanDAC read it (the client times out).
        case loseBeforeApply
        /// SpanDAC answers `outcome: unknown` after carrying it out.
        case unknownReply
        case refuse(String)
    }

    let library: FakeAppleLibrary
    var offersOps = true
    /// Per write, in order; `.apply` once exhausted.
    var adds: [Write] = []
    var ensures: [Write] = []
    var duplicateName = false
    var playlistAlias = true
    /// How many ensure replies for one playlist carry `alias: null` before it
    /// is reported (a playlist just made has no persistent ID for a moment).
    var aliasAfterEnsures = 0
    /// Rewrites a playlist's track order as AppleScript reads it back.
    var containerOrder: (([String]) -> [String])?
    /// Runs inside an ensure before it answers (how a test looks at the
    /// coordinator's state at the moment the request is made).
    var onEnsure: ((String) -> Void)?

    private let lock = NSLock()
    private(set) var requests: [[String: Any]] = []
    private(set) var playlists: [String: (id: String, pid: String)] = [:]
    private(set) var creates = 0
    private var ensureCounts: [String: Int] = [:]
    /// Playlist persistent ID -> its tracks' persistent IDs, in order.
    private var playlistTracks: [String: [String]] = [:]

    /// The playlist's track persistent IDs as AppleScript reads them, in the
    /// playlist's order; nil when no playlist has this persistent ID.
    func containerTrackIDs(_ hex: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let ids = playlistTracks[hex] else { return nil }
        return containerOrder?(ids) ?? ids
    }

    init(library: FakeAppleLibrary) { self.library = library }

    func ops(_ op: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0["op"] as? String == op }
    }
    var allOps: [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0["op"] as? String } }

    var client: SpanDACLibraryAdd { SpanDACLibraryAdd(path: "/nonexistent/fake-mac.sock", transport: transport) }

    lazy var transport: (String, String) throws -> String = { [unowned self] _, line in
        let body = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        let op = body["op"] as? String ?? ""
        self.lock.lock(); self.requests.append(body); self.lock.unlock()
        let ids = body["ids"] as? [String] ?? []
        switch op {
        case "slice.status":
            return self.offersOps ? self.statusWithOps
                : #"{"ok":true,"op":"slice.status","status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":["slice.status"]}}"#
        case "slice.libraryLookup" where self.offersOps:
            self.library.record("lookup")
            let items = ids.map { id -> String in
                let alias = self.library.lookupAlias(id).map { "\"\($0)\"" } ?? "null"
                return #"{"id":"\#(id)","alias":\#(alias)}"#
            }.joined(separator: ",")
            return #"{"ok":true,"op":"slice.libraryLookup","items":[\#(items)]}"#
        case "slice.libraryAdd" where self.offersOps:
            self.library.record("add")
            let behaviour = self.next(&self.adds)
            return try self.answerWrite(op, behaviour, apply: { self.library.applyAdd(ids) },
                                        ok: #"{"ok":true,"op":"slice.libraryAdd"}"#)
        case "slice.libraryEnsurePlaylist" where self.offersOps:
            let name = body["name"] as? String ?? ""
            self.onEnsure?(name)
            if self.duplicateName {
                return #"{"ok":false,"op":"slice.libraryEnsurePlaylist","error":{"kind":"duplicate_name","detail":"More than one playlist has this name; nothing was created."}}"#
            }
            let behaviour = self.next(&self.ensures)
            var created = false
            return try self.answerWrite(op, behaviour, apply: {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.playlists[name] == nil {
                    self.creates += 1
                    created = true
                    let pid = String(format: "%016llX", 0xF00 + UInt64(self.creates))
                    self.playlists[name] = ("p.\(self.creates)", pid)
                    self.lock.unlock()
                    let tracks = ids.map { self.library.ownForPlaylist($0) }
                    self.lock.lock()
                    self.playlistTracks[pid] = tracks
                }
                self.ensureCounts[name, default: 0] += 1
            }, ok: {
                self.lock.lock(); defer { self.lock.unlock() }
                let p = self.playlists[name]!
                let reported = self.playlistAlias && self.ensureCounts[name, default: 0] > self.aliasAfterEnsures
                let alias = reported ? "\"\(FakeAppleLibrary.alias(p.pid))\"" : "null"
                return #"{"ok":true,"op":"slice.libraryEnsurePlaylist","created":\#(created),"playlist":{"id":"\#(p.id)","alias":\#(alias)}}"#
            })
        default:
            return #"{"ok":false,"op":"\#(op)","error":{"kind":"unknown_op","detail":"unknown op"}}"#
        }
    }

    private func next(_ queue: inout [Write]) -> Write {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? .apply : queue.removeFirst()
    }

    private func answerWrite(_ op: String, _ behaviour: Write, apply: () -> Void,
                             ok: @autoclosure () -> String) throws -> String {
        switch behaviour {
        case .apply:
            apply(); return ok()
        case .applyThenLoseReply:
            apply(); throw SourceAppError.timedOut
        case .loseBeforeApply:
            throw SourceAppError.timedOut
        case .unknownReply:
            apply()
            return #"{"ok":false,"op":"\#(op)","error":{"kind":"outcome_unknown","detail":"SpanDAC couldn't confirm it."},"outcome":"unknown"}"#
        case .refuse(let detail):
            return #"{"ok":false,"op":"\#(op)","error":{"kind":"refused","detail":"\#(detail)"}}"#
        }
    }

    private func answerWrite(_ op: String, _ behaviour: Write, apply: () -> Void,
                             ok: () -> String) throws -> String {
        try answerWrite(op, behaviour, apply: apply, ok: ok())
    }
}

// MARK: - Tests

final class SpanDACLibraryAddTests: XCTestCase {

    private let teardrop = SpanDACCatalogueSong(catalogueID: "1440857999", title: "Teardrop",
                                                artist: "Massive Attack", album: "Mezzanine")

    private func rig(owned: Bool = false) -> (lib: FakeAppleLibrary, mac: FakeSpanDACMac, player: SpanDACCataloguePlayer) {
        let lib = FakeAppleLibrary()
        lib.catalogue[teardrop.catalogueID] = ("Teardrop", "Massive Attack", "Mezzanine")
        if owned { lib.own(catalogueID: teardrop.catalogueID, name: "Teardrop", artist: "Massive Attack", album: "Mezzanine") }
        return (lib, FakeSpanDACMac(library: lib), SpanDACCataloguePlayer(seams: lib.seams))
    }

    private func tripwired<T>(_ body: () -> T) -> (T, [ExternalCall]) {
        var value: T!
        let calls = withTripwire { value = body() }.calls
        return (value, calls)
    }

    // MARK: Owned songs

    func testAnOwnedSongFoundByLookupPlaysWithoutAnAdd() {
        let r = rig(owned: true)
        let pid = r.lib.owned[teardrop.catalogueID]!

        let (outcome, calls) = tripwired { r.player.play(teardrop, library: r.mac.client) }

        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 0, "an owned song is never added")
        XCTAssertEqual(r.lib.allSeeded, [pid], "exactly that track plays")
        XCTAssertFalse(r.lib.allEvents.contains("nameRead"), "no title search: the identity decides")
        XCTAssertEqual(r.lib.launches, 1)
        XCTAssertEqual(calls, [])
    }

    // MARK: Not-owned songs

    func testANotOwnedSongIsAddedBySpanDACThenResolvedAndPlayed() {
        let r = rig()

        let (outcome, calls) = tripwired { r.player.play(teardrop, library: r.mac.client) }

        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil))
        XCTAssertEqual(r.mac.allOps.filter { $0 != "slice.status" }.first, "slice.libraryLookup",
                       "SpanDAC is asked first whether the song is owned")
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1)
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").first?["ids"] as? [String], [teardrop.catalogueID])
        let added = r.lib.owned[teardrop.catalogueID]!
        XCTAssertEqual(r.lib.allSeeded, [added], "the row the add made is the one that plays")
        let events = r.lib.allEvents
        XCTAssertLessThan(events.firstIndex(of: "nameRead")!, events.firstIndex(of: "add")!,
                          "the baseline is read before the add")
        XCTAssertEqual(calls, [])
    }

    /// Two identical rows arrive (the set difference alone would refuse as
    /// ambiguous), and SpanDAC's alias, appearing only after the add, names
    /// exactly one of them: the alias wins.
    func testAnAliasThatAppearsAfterTheAddIsPreferred() {
        let r = rig()
        r.lib.copiesPerAdd = 2

        let outcome = r.player.play(teardrop, library: r.mac.client)

        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil))
        let aliased = r.lib.owned[teardrop.catalogueID]!
        XCTAssertEqual(r.lib.allSeeded, [aliased])
        XCTAssertGreaterThanOrEqual(r.mac.ops("slice.libraryLookup").count, 2, "looked up before and after the add")
    }

    /// No alias is reported: the shipped set difference picks the new row,
    /// and a same-titled row by someone else that was already there is not it.
    func testWithoutAnAliasTheSetDifferenceResolverDecides() {
        let r = rig()
        r.lib.aliasVisible = false
        let other = r.lib.own(catalogueID: nil, name: "Teardrop", artist: "Elizabeth Fraser", album: "Demo")

        let outcome = r.player.play(teardrop, library: r.mac.client)

        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil))
        let added = r.lib.owned[teardrop.catalogueID]!
        XCTAssertNotEqual(added, other)
        XCTAssertEqual(r.lib.allSeeded, [added])
    }

    func testTheBaselineIsReadBeforeTheAddAndAnUnreadableBaselineRefusesBeforeAdding() {
        let r = rig()
        r.lib.nameReadsFail = true

        let outcome = r.player.play(teardrop, library: r.mac.client)

        XCTAssertEqual(outcome, .refused("Could not read your library, so 'Teardrop' was not added and nothing was played."))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 0, "nothing is added over an unreadable baseline")
        XCTAssertEqual(r.lib.allSeeded, [])
    }

    func testAFailedAddRefusesAndPlaysNothing() {
        let r = rig()
        r.mac.adds = [.refuse("Apple Music didn't add that to your library.")]

        let outcome = r.player.play(teardrop, library: r.mac.client)

        guard case .refused(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.contains("Apple Music didn't add that to your library."), why)
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1, "never retried")
        XCTAssertEqual(r.lib.allSeeded, [])
        XCTAssertEqual(r.lib.launches, 0)
        XCTAssertFalse(r.player.isAwaitingReconciliation(teardrop.catalogueID),
                       "a confirmed failure leaves nothing to reconcile")
    }

    func testAnAmbiguousNewRowRefusesAsShipped() {
        let r = rig()
        r.lib.aliasVisible = false
        r.lib.copiesPerAdd = 2

        let outcome = r.player.play(teardrop, library: r.mac.client)

        XCTAssertEqual(outcome, .refused(catalogRowResolutionMessage(.ambiguous(count: 2, amongPreExisting: false),
                                                                     title: "Teardrop")!))
        XCTAssertEqual(r.lib.allSeeded, [])
    }

    /// The SpanDAC path takes no auth at all: no developer key, no user token,
    /// no REST call. The tripwire would record a REST or AppleScript call made
    /// by any production backend; the add reached SpanDAC.
    func testNoDeveloperKeyIsReadOnTheSpanDACPath() {
        let r = rig()
        let (outcome, calls) = tripwired { r.player.play(teardrop, library: r.mac.client) }
        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil))
        XCTAssertEqual(calls, [], "no REST or AppleScript backend was reached")
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1, "the add went to SpanDAC")
        XCTAssertTrue(liveCLIMusicTUICataloguePlay() is SpanDACCLICataloguePlay,
                      "the CLI's catalogue seam is the SpanDAC one, not the REST add")
    }

    func testASpanDACWithoutTheOpsSaysUpdate() {
        let r = rig()
        r.mac.offersOps = false

        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .refused(updateSpanDACToPlayOnMusicTUI))
        XCTAssertEqual(r.mac.allOps, ["slice.status"], "nothing but the capability check is sent")

        // A SpanDAC that advertises the ops but answers `unknown_op` says the same.
        XCTAssertThrowsError(try SpanDACLibraryAdd(path: "/x", transport: { _, _ in
            #"{"ok":false,"op":"slice.libraryAdd","error":{"kind":"unknown_op","detail":"no"}}"#
        }).add(catalogueIDs: ["1"])) { XCTAssertEqual($0 as? SpanDACLibraryOpError, .notOffered) }
    }

    // MARK: Unknown outcomes

    /// The add's reply is lost. Nothing retries by itself. The person's retry
    /// looks it up first: the add landed, so it plays with NO second add; or it
    /// did not, so one more add is sent.
    func testAnAddReplyLostReconcilesByLookupBeforeAnyRetry() {
        // Landed, reply lost.
        var r = rig()
        r.mac.adds = [.applyThenLoseReply]
        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .outcomeUnknown(title: "Teardrop"))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1, "no automatic retry")
        XCTAssertEqual(r.lib.allSeeded, [], "nothing played")
        XCTAssertTrue(r.player.isAwaitingReconciliation(teardrop.catalogueID))

        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .playing(title: "Teardrop", note: nil))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1, "the lookup found it: no second add")
        XCTAssertEqual(r.lib.allSeeded, [r.lib.owned[teardrop.catalogueID]!])
        XCTAssertFalse(r.player.isAwaitingReconciliation(teardrop.catalogueID))

        // Lost before SpanDAC read it: the lookup finds nothing, one more add.
        r = rig()
        r.mac.adds = [.loseBeforeApply]
        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .outcomeUnknown(title: "Teardrop"))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 1)
        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .playing(title: "Teardrop", note: nil))
        XCTAssertEqual(r.mac.ops("slice.libraryAdd").count, 2, "exactly one more add, on the person's retry")

        // SpanDAC's own `outcome: unknown` is the same state.
        r = rig()
        r.mac.adds = [.unknownReply]
        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .outcomeUnknown(title: "Teardrop"))
    }

    /// The first add landed but no alias is reported, and the row became
    /// visible between the attempts. The retry must resolve against the
    /// baseline taken before the FIRST add: the row is then new (the set
    /// difference), not a copy the person already owned.
    func testTheBaselineIsNeverRetakenAfterAnUnknownOutcome() {
        let r = rig()
        r.lib.aliasVisible = false
        r.mac.adds = [.applyThenLoseReply]

        XCTAssertEqual(r.player.play(teardrop, library: r.mac.client), .outcomeUnknown(title: "Teardrop"))
        let firstAttempt = r.lib.allEvents.count

        let outcome = r.player.play(teardrop, library: r.mac.client)

        let retry = Array(r.lib.allEvents[firstAttempt...])
        XCTAssertFalse(retry.prefix(upTo: retry.firstIndex(of: "add")!).contains("nameRead"),
                       "no baseline is read before the retry's add: \(retry)")
        XCTAssertEqual(outcome, .playing(title: "Teardrop", note: nil),
                       "resolved as the NEW row, never as one already owned")
        XCTAssertEqual(r.lib.allSeeded, [r.lib.owned[teardrop.catalogueID]!])
    }

    // MARK: The wire

    /// Each way an answer can go missing is an unknown outcome for a write,
    /// never a confirmed failure; a request that never left is confirmed.
    func testWriteOutcomesAreClassifiedHonestly() {
        func add(_ transport: @escaping (String, String) throws -> String) -> Error? {
            do { try SpanDACLibraryAdd(path: "/x", transport: transport).add(catalogueIDs: ["1"]); return nil }
            catch { return error }
        }
        XCTAssertNil(add { _, _ in #"{"ok":true,"op":"slice.libraryAdd"}"# })
        for lost in [SourceAppError.timedOut, .unreadable] {
            guard case .outcomeUnknown? = add({ _, _ in throw lost }) as? SpanDACLibraryOpError else {
                return XCTFail("\(lost) must be unknown")
            }
        }
        guard case .outcomeUnknown? = add({ _, _ in "not json" }) as? SpanDACLibraryOpError else {
            return XCTFail("an unreadable reply to a write is unknown")
        }
        guard case .outcomeUnknown? = add({ _, _ in
            #"{"ok":false,"error":{"kind":"outcome_unknown","detail":"d"},"outcome":"unknown"}"#
        }) as? SpanDACLibraryOpError else { return XCTFail("outcome unknown") }
        XCTAssertEqual(add { _, _ in #"{"ok":false,"error":{"kind":"refused","detail":"No."}}"# } as? SpanDACLibraryOpError,
                       .failed("No."))
        guard case .failed? = add({ _, _ in throw SourceAppError.notRunning }) as? SpanDACLibraryOpError else {
            return XCTFail("a connect that failed sent nothing: confirmed")
        }
        // An ensure whose ok reply carries no playlist may have made one.
        XCTAssertThrowsError(try SpanDACLibraryAdd(path: "/x", transport: { _, _ in #"{"ok":true,"created":true}"# })
            .ensurePlaylist(name: "n", catalogueIDs: ["1"])) {
            guard case .outcomeUnknown? = $0 as? SpanDACLibraryOpError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Switches and isolation

    /// A read's stamp is checked before any SpanDAC write: a Discover play
    /// whose data source changed after its tracks were read ensures nothing,
    /// looks nothing up and adds nothing.
    func testAnAddThatCrossedASwitchPlaysNothing() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let lib = FakeAppleLibrary()
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: inertLifecycle(), routing: routing, opener: SceneRecordingOpener())
        let mac = FakeSpanDACMac(library: lib)
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        scene.libraryOps = mac.client

        // Read under SpanDAC data, then stop using SpanDAC before the play.
        let read = DiscoverScene.RowsRead(try routing.choose(.discoverFeed, musicApp: { 0 }, source: { _ in 1 }))
        XCTAssertTrue(read.spandacData)
        _ = try routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })

        let calls = withTripwire {
            scene.playCatalogSlice(catalogIDs: ["901"], containerTitle: "Boom Bap", trackName: "T1",
                                   trackArtist: "A", read: read)
            scene.playCatalogSlice(catalogIDs: ["901", "902"], containerTitle: "Boom Bap", trackName: "T1", read: read)
            drain(actions)
        }.calls

        XCTAssertEqual(status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(mac.allOps, [], "nothing was looked up, added or ensured")
        XCTAssertEqual(lib.allEvents, [])
        XCTAssertEqual(calls, [])
    }

    /// Enter on one Discover track, on the MusicTUI output with SpanDAC data:
    /// SpanDAC on this Mac adds it, and exactly that song plays. No
    /// container is made and nothing is queued on any SpanDAC.
    func testADiscoverTrackIsAddedBySpanDACAndPlayedOnMusicTUI() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let lib = FakeAppleLibrary()
        lib.catalogue["901"] = ("T1", "A", "Boom Bap")
        let mac = FakeSpanDACMac(library: lib)
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: inertLifecycle(), routing: routing, opener: SceneRecordingOpener())
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        scene.libraryOps = mac.client
        let read = DiscoverScene.RowsRead(try routing.choose(.discoverFeed, musicApp: { 0 }, source: { _ in 1 }))

        let calls = withTripwire {
            scene.playCatalogSlice(catalogIDs: ["901"], containerTitle: "Boom Bap", trackName: "T1",
                                   trackArtist: "A", read: read)
            drain(actions)
        }.calls

        XCTAssertEqual(status.current()?.text, "Playing T1")
        XCTAssertEqual(mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["901"])
        XCTAssertEqual(mac.ops("slice.libraryEnsurePlaylist").count, 0, "one song is not a container")
        XCTAssertEqual(lib.allSeeded, [lib.owned["901"]!])
        XCTAssertEqual(rig.sent("slice.queue").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
        XCTAssertEqual(calls, [])
    }

    /// The library ops go over the DATA client's own path and transport, and
    /// no other: a test's client carries a fake transport, so they can never
    /// reach a real SpanDAC through them. The CLI's production seam, run on a
    /// test harness, reaches no AppleScript, REST or launch, never asks the
    /// scripted data wire to write, and says why.
    func testTestsNeverReachARealAdd() throws {
        var sent: [(path: String, line: String)] = []
        let client = SourceAppClient(path: "/nonexistent/pinned.sock", transport: { path, line in
            sent.append((path, line))
            return #"{"ok":true,"status":{"playback":"stopped","capabilities":[]}}"#
        })
        let ops = client.libraryWrites()
        XCTAssertEqual((ops as? SpanDACLibraryAdd)?.path, "/nonexistent/pinned.sock")
        XCTAssertEqual(sent.count, 0, "building the ops sends nothing")
        XCTAssertFalse(ops.canAdd, "a SpanDAC that does not name the ops is not offered them")
        XCTAssertEqual(sent.map(\.path), ["/nonexistent/pinned.sock"], "the client's own transport carried it")
        XCTAssertTrue(sent.first?.line.contains("slice.status") ?? false)
        // Production's data client: the same socket its reads use. Built, never sent on.
        let mac = SourceAppClient.macData(starter: CLIFakeMacStarter(.notInstalled))
        XCTAssertEqual((mac.libraryWrites() as? SpanDACLibraryAdd)?.path, mac.path)
        XCTAssertEqual(mac.path, SourceAppStationSearch.socketPath)

        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, recordSeams: false)
        try h.env.cache.writeSongs([SongResult(index: 1, title: "Teardrop", artist: "Massive Attack", album: "",
                                               catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857999")])
        let calls = withTripwire {
            _ = try? runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false,
                             env: h.env, musicAppDeps: PlayMusicAppDeps(readSongs: { [] }, resolveIndexed: { _, _ in }))
        }.calls
        XCTAssertEqual(calls, [])
        XCTAssertFalse(h.dataWire.requests.contains { spandacLibraryOpNames.contains($0["op"] as? String ?? "") })
        XCTAssertEqual(h.io.out, [updateSpanDACToPlayOnMusicTUI])
    }

    /// A found-owned or just-added song is checked by the SAME identity check
    /// as a library row: the same read, exactly one track, the title when one
    /// is known, and nothing on a failed read.
    func testAnAliasIsVerifiedByTheOneIdentityCheck() {
        let alias = FakeAppleLibrary.alias("00000000000000A1")
        let hex = "00000000000000A1", fs = "\u{1F}"
        func line(_ db: String, _ name: String) -> String { [hex, "L", db, "7", name].joined(separator: fs) + "\n" }
        var scripts: [String] = []
        func verify(_ title: String?, _ answer: String?) -> (hex: String, name: String)? {
            verifySpanDACAlias(alias, title: title, run: { scripts.append($0); return answer })
        }
        XCTAssertEqual(verify("Teardrop", line("1", "Teardrop"))?.name, "Teardrop")
        XCTAssertEqual(scripts, [persistentIDVerificationScript([hex])], "the hand-off's own read")
        XCTAssertEqual(verify(nil, line("1", "Teardrop"))?.hex, hex, "a song link has no title to check")
        XCTAssertNil(verify("Teardrop", line("1", "Angel")), "the title must match")
        XCTAssertNil(verify("Teardrop", line("1", "Teardrop") + line("2", "Teardrop")), "two tracks is ambiguous")
        XCTAssertNil(verify("Teardrop", ""), "not found")
        XCTAssertNil(verify("Teardrop", nil), "a failed read verifies nothing")
        XCTAssertNil(verifySpanDACAlias("not-a-number", title: nil, run: { _ in XCTFail("read"); return nil }))
    }

    // MARK: The CLI

    /// `music play N` of a SpanDAC catalogue row adds through SpanDAC and
    /// plays, showing the shipped now-playing display; an unknown outcome
    /// says so and plays nothing.
    func testCLIPlayNAddsThroughSpanDACAndPlays() throws {
        let lib = FakeAppleLibrary()
        lib.catalogue["1440857999"] = ("Teardrop", "Massive Attack", "Mezzanine")
        let mac = FakeSpanDACMac(library: lib)
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, recordSeams: false)
        var shown: [Bool] = []
        var env = h.env
        env.cataloguePlay = SpanDACCLICataloguePlay(seams: lib.seams, showPlaying: { shown.append($0) },
                                                    library: { _ in mac.client })
        try h.env.cache.writeSongs([SongResult(index: 1, title: "Teardrop", artist: "Massive Attack", album: "",
                                               catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857999")])
        func play() -> [ExternalCall] {
            withTripwire {
                _ = try? runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false,
                                 env: env, musicAppDeps: PlayMusicAppDeps(readSongs: { [] }, resolveIndexed: { _, _ in }))
            }.calls
        }

        mac.adds = [.applyThenLoseReply]
        XCTAssertEqual(play(), [])
        XCTAssertEqual(h.io.out.last, cliSpanDACAddOutcomeUnknown("Teardrop"))
        XCTAssertEqual(shown, [])

        XCTAssertEqual(play(), [])
        XCTAssertEqual(shown, [false], "the retry found the add by lookup and played")
        XCTAssertEqual(mac.ops("slice.libraryAdd").count, 1)
        XCTAssertEqual(lib.allSeeded, [lib.owned["1440857999"]!])
    }

    // MARK: Helpers

    private func inertLifecycle() -> DiscoverLifecycleCoordinator {
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, _ in XCTFail("the web-service create ran") }, readCount: { _ in 0 },
            play: { _ in XCTFail("played") }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }
}

extension FakeSpanDACMac {
    /// A `slice.status` reply that advertises the three library ops.
    var statusWithOps: String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":["slice.status","slice.libraryAdd","slice.libraryLookup","slice.libraryEnsurePlaylist"]}}"#
    }
}
