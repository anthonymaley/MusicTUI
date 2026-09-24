import XCTest
@testable import music

/// The Library tab's SONGS list, with Bridge selected: the rows are Bridge's own
/// MusicKit library and a row plays by the id Bridge gave it.
///
/// This is "two modes, two libraries" (Anthony, 2026-09-23) at the scene: the
/// selected output owns both the data and the playback, so the
/// `(title, artist, album)` join disappears from this path entirely.
///
/// No live calls: every Bridge answer is canned through the real
/// `SourceAppControl(path:transport:)`, so these exercise the framing and the
/// refusal decoding the app actually uses. The AppleScript source is injected
/// and records whether anything asked it, which is how "never fall back" is a
/// test and not a comment.
final class BridgeLibrarySceneTests: XCTestCase {

    private let frame = shellLayout(width: 100, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - A canned Bridge

    /// Answers `slice.librarySongs` from a scripted list of pages, in order, and
    /// records every request. `gateAt` holds the Nth page request until the test
    /// releases it — which is the only way these assertions are about state the
    /// list actually held: the canned walk is far faster than the tick loop that
    /// drains it, so an ungated test would keep missing the moment it means to
    /// observe.
    private final class Wire {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []
        private let pages: [String]
        private let gateAt: Set<Int>
        private var gates: [Int: DispatchSemaphore] = [:]
        private var pageRequests = 0
        /// Scripted `slice.queue` answers, in order; afterwards it succeeds.
        private var queueReplies: [String]
        private var queueRequests = 0
        /// C2 harness addition: scripted `slice.libraryAlbums` /
        /// `slice.libraryArtists` pages, for the rewritten tests that need
        /// Albums or Artists to answer from Bridge alongside Songs.
        private let albumPages: [String]
        private var albumRequests = 0
        private let artistPages: [String]
        private var artistRequests = 0

        static let queued = """
        {"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"Aquarama","artist":"Moomin",
         "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
        """
        static let status = """
        {"ok":true,"op":"slice.status","status":{"playback":"playing","title":"Aquarama","artist":"Moomin",
         "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
        """
        /// A page nobody scripted. Loud on purpose: an over-walk must fail a
        /// test, not quietly read as an empty library.
        static let unscripted = """
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"bad_request","detail":"unscripted page request"}}
        """
        static let unscriptedAlbums = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"bad_request","detail":"unscripted album page request"}}
        """
        static let unscriptedArtists = """
        {"ok":false,"op":"slice.libraryArtists","error":{"kind":"bad_request","detail":"unscripted artist page request"}}
        """

        convenience init(pages: [String], gateAt: Int) { self.init(pages: pages, gateAt: [gateAt]) }

        init(pages: [String], gateAt: Set<Int> = [], queueReplies: [String] = [],
            albumPages: [String] = [], artistPages: [String] = []) {
            self.pages = pages
            self.gateAt = gateAt
            self.queueReplies = queueReplies
            self.albumPages = albumPages
            self.artistPages = artistPages
            for i in gateAt { gates[i] = DispatchSemaphore(value: 0) }
        }

        func transport(_ path: String, _ line: String) throws -> String {
            let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
            let op = body["op"] as? String ?? ""
            lock.lock()
            requests.append(body)
            var n = -1
            var reply: String
            switch op {
            case "slice.librarySongs":
                n = pageRequests
                pageRequests += 1
                reply = n < pages.count ? pages[n] : Self.unscripted
            case "slice.queue":
                let q = queueRequests
                queueRequests += 1
                reply = q < queueReplies.count ? queueReplies[q] : Self.queued
            case "slice.libraryAlbums":
                let a = albumRequests
                albumRequests += 1
                reply = a < albumPages.count ? albumPages[a] : Self.unscriptedAlbums
            case "slice.libraryArtists":
                let a = artistRequests
                artistRequests += 1
                reply = a < artistPages.count ? artistPages[a] : Self.unscriptedArtists
            default:             reply = Self.status
            }
            let gate = gates[n]
            lock.unlock()
            _ = gate?.wait(timeout: .now() + 5)
            return reply
        }

        /// Let the held request answer. `at` names the page request by index.
        func release(at n: Int = 0) {
            lock.lock(); let gate = gates[n]; lock.unlock()
            gate?.signal()
        }

        /// Whether the gated request has actually been issued, so a test waits
        /// for the walk to arrive rather than for a duration.
        func reached(_ n: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return pageRequests > n
        }

        func sent(_ op: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { ($0["op"] as? String) == op }
        }
    }

    // MARK: - Pages

    private let page1 = """
    {"ok":true,"op":"slice.librarySongs","generation":7,"total":15646,"items":[
      {"id":"i.aaa","title":"Aquarama","artist":"Moomin","album":"Aquarama - Single","kind":"song"},
      {"id":"i.bbb","title":"Lotus Flower","artist":"Radiohead","album":"The King of Limbs","kind":"song"}],
     "next_cursor":"cursor-1"}
    """
    private let page2 = """
    {"ok":true,"op":"slice.librarySongs","generation":7,"total":15646,"items":[
      {"id":"i.ccc","title":"Nude","artist":"Radiohead","album":"In Rainbows","kind":"song"}],
     "next_cursor":null}
    """
    /// A whole list in one page, from a LATER observation of the library.
    private let regenerated = """
    {"ok":true,"op":"slice.librarySongs","generation":9,"total":2,"items":[
      {"id":"i.zzz","title":"Teardrop","artist":"Massive Attack","album":"Mezzanine","kind":"song"}],
     "next_cursor":null}
    """
    private let staleRefusal = """
    {"ok":false,"op":"slice.librarySongs","error":{"kind":"stale_generation",
     "detail":"the library changed while you were reading it; start again"}}
    """
    private let noAccess = """
    {"ok":false,"op":"slice.librarySongs","error":{"kind":"unauthorized","detail":"no access"}}
    """

    // MARK: - Harness

    /// Records whether anything asked the AppleScript source. The Bridge branch
    /// must never touch it: a Bridge failure is Bridge's failure (rule 3).
    private final class AppleScriptSpy {
        private let lock = NSLock()
        private var asked = false
        let rows: [LibrarySong]
        let albums: [LibraryAlbum]
        let artists: [LibraryArtist]
        /// false makes the Music.app bulk read FAIL, which is how "a Music.app
        /// failure does not mark the Bridge list unreadable" becomes a test.
        let albumsSucceed: Bool

        init(rows: [LibrarySong] = [], albums: [LibraryAlbum] = [],
             artists: [LibraryArtist] = [], albumsSucceed: Bool = true) {
            self.rows = rows
            self.albums = albums
            self.artists = artists
            self.albumsSucceed = albumsSucceed
        }
        var wasAsked: Bool { lock.lock(); defer { lock.unlock() }; return asked }
        /// How many times the Music.app bulk read was started. The shared retry
        /// chain re-reads on a failure, so this counts as a probe of whose
        /// failure state was touched.
        var albumReads: Int { lock.lock(); defer { lock.unlock() }; return albumReadCount }
        private var albumReadCount = 0
        /// C2 harness addition: the same probe as `albumReads`, for Artists —
        /// needed once Artists can ALSO be Bridge-sourced, so "the Music.app
        /// source is asked 0 times" is provable for all three lists, not two.
        var artistReads: Int { lock.lock(); defer { lock.unlock() }; return artistReadCount }
        private var artistReadCount = 0
        func sources() -> LibraryDataSources {
            LibraryDataSources(onAlbums: { [self] page in
                                   lock.lock(); albumReadCount += 1; lock.unlock()
                                   guard albumsSucceed else { return false }
                                   return albums.isEmpty ? true : page(albums)
                               },
                               onSongs: { [self] page in
                                   lock.lock(); asked = true; lock.unlock()
                                   return page(rows)
                               },
                               onArtists: { [self] page in
                                   lock.lock(); artistReadCount += 1; lock.unlock()
                                   return artists.isEmpty ? true : page(artists)
                               },
                               onAlbumTracks: { _, _ in [] },
                               onArtistAlbums: { _ in [] },
                               onAlbumCover: { _ in nil })
        }
    }

    private func routing(_ mode: PlaybackMode) -> RoutingCoordinator {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        return RoutingCoordinator(store: store, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent") })
    }

    /// Every warm-up wait this scene took, instead of taking it. A bounded
    /// retry rule should be provable without the suite sleeping through it.
    private final class Waits {
        private let lock = NSLock()
        private var taken: [TimeInterval] = []
        var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return taken }
        func record(_ seconds: TimeInterval) { lock.lock(); taken.append(seconds); lock.unlock() }
    }

    /// The production shape of the factory: a provider only in Bridge mode.
    private func scene(mode: PlaybackMode, wire: Wire, spy: AppleScriptSpy,
                       status: StatusStore, waits: Waits = Waits()) -> LibraryScene {
        let route = routing(mode)
        return LibraryScene(backend: AppleScriptBackend(), routing: route,
                            sources: spy.sources(), appQueue: AppQueueStore(),
                            status: status, actions: ActionRunner(status: status),
                            makeProvider: {
                                route.mode == .source
                                    ? BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent",
                                                                                    transport: wire.transport))
                                    : nil
                            },
                            warmUpSleep: { waits.record($0) },
                            // Never the real ~/.config/music/artist-tiers.json (C2 isolation).
                            resultCache: temporaryResultCache().cache)
    }

    /// `[` / `]` cycle artists → albums → songs; land on Songs from wherever the
    /// scene starts, then let `tick` kick the load.
    private func toSongs(_ s: LibraryScene) { go(s, to: .songs) }

    private func go(_ s: LibraryScene, to sub: LibrarySubView) {
        for _ in 0..<LibrarySubView.allCases.count where s.subViewForTest != sub {
            _ = s.handle(.char("]"))
        }
        XCTAssertEqual(s.subViewForTest, sub)
    }

    @discardableResult
    private func settle(_ s: LibraryScene, seconds: Double = 3.0,
                        until: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = s.tick(snapshot: idle)
            if until() { return true }
            usleep(5_000)
        }
        _ = s.tick(snapshot: idle)
        return until()
    }

    // MARK: - The rows

    /// Bridge's ids travel unchanged into the list. They are what playback uses
    /// now, so a list that dropped or rewrote them would be unplayable.
    func testTheSongsListIsBridgesLibraryWithItsOwnIds() {
        let wire = Wire(pages: [page1, page2])
        let spy = AppleScriptSpy(rows: [LibrarySong(id: "as1", title: "FromAppleScript", artist: "X", album: "Y")])
        let s = scene(mode: .source, wire: wire, spy: spy, status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 }, "the walk never finished")
        XCTAssertEqual(s.songsForTest.map(\.id), ["i.aaa", "i.bbb", "i.ccc"])
        XCTAssertEqual(s.songsForTest.map(\.title), ["Aquarama", "Lotus Flower", "Nude"])
        XCTAssertFalse(spy.wasAsked, "Bridge mode read the AppleScript library as well")
    }

    /// The second page is asked for with the cursor the first one returned, and
    /// the first page asks for none at all.
    func testTheNextPageIsAskedForWithTheCursorTheLastOneReturned() {
        let wire = Wire(pages: [page1, page2])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })

        let asked = wire.sent("slice.librarySongs")
        XCTAssertEqual(asked.count, 2, "walked more pages than the list has")
        XCTAssertNil(asked[0]["cursor"], "a first page sends no cursor at all")
        XCTAssertEqual(asked[0]["limit"] as? Int, 100)
        XCTAssertEqual(asked[1]["cursor"] as? String, "cursor-1")
    }

    /// Streaming, not all-or-nothing: the first page is on screen while the
    /// second is still in flight.
    func testTheFirstPageIsVisibleWhileTheRestAreStillComing() {
        let wire = Wire(pages: [page1, page2], gateAt: 1)   // page 2 blocks
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 2 }, "the first page never reached the list")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Aquarama"), "page one is not on screen: \(out)")
        XCTAssertEqual(s.songsForTest.count, 2, "page two arrived while it was still gated")

        wire.release(at: 1)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 }, "page two never landed")
    }

    // MARK: - The list says which library it is

    /// The two modes show different libraries, so the list names the one it is
    /// showing and its size — from Bridge's own `total`, before it has them all.
    func testTheSongsListNamesBridgeAndBridgesCount() {
        let wire = Wire(pages: [page1, page2], gateAt: 1)
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 2 })

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Songs \u{2014} Bridge library (15,646)"),
                      "the list did not say which library it is showing: \(out)")
        wire.release(at: 1)
    }

    /// Music.app mode is untouched: the rows come from the AppleScript source
    /// and the header says nothing about Bridge.
    func testMusicAppModeStillReadsAppleScriptAndKeepsItsHeader() {
        let wire = Wire(pages: [page1])
        let spy = AppleScriptSpy(rows: [LibrarySong(id: "as1", title: "FromAppleScript", artist: "X", album: "Y")])
        let s = scene(mode: .musicApp, wire: wire, spy: spy, status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 1 }, "the AppleScript list never landed")
        XCTAssertEqual(s.songsForTest.map(\.id), ["as1"])
        XCTAssertTrue(spy.wasAsked)
        XCTAssertTrue(wire.sent("slice.librarySongs").isEmpty, "Music.app mode asked Bridge for the library")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Bridge library"), "Music.app mode named Bridge: \(out)")
        XCTAssertTrue(out.contains("FromAppleScript"))
    }

    // MARK: - A library that changes underneath

    /// Restart ONCE, from the first page, and keep nothing from the observation
    /// that no longer exists. Two generations never share one list.
    func testAStaleGenerationRestartsOnceAndNeverMixesGenerations() {
        let wire = Wire(pages: [page1, staleRefusal, regenerated])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.map(\.id) == ["i.zzz"] },
                      "the restarted walk did not replace the list; got \(s.songsForTest.map(\.id))")
        let asked = wire.sent("slice.librarySongs")
        XCTAssertEqual(asked.count, 3)
        XCTAssertNil(asked[2]["cursor"], "a restart begins at the first page, not where it stopped")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Aquarama"), "a row from the old generation survived: \(out)")
        XCTAssertTrue(out.contains("Songs \u{2014} Bridge library (2)"),
                      "the count is still the old observation's: \(out)")
    }

    /// Twice is not a transient. The second one stops the walk and is said out
    /// loud, in Bridge's own sentence.
    func testASecondStaleGenerationStopsAndSaysSo() {
        let status = StatusStore()
        let wire = Wire(pages: [page1, staleRefusal, page1, staleRefusal])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: status)
        toSongs(s)

        XCTAssertTrue(settle(s) { status.current() != nil }, "a second stale generation was silent")
        XCTAssertEqual(status.current()?.text, "the library changed while you were reading it; start again")
        XCTAssertEqual(status.current()?.isError, true)
        XCTAssertEqual(wire.sent("slice.librarySongs").count, 4, "it restarted more than once")
    }

    // MARK: - A failure is Bridge's failure

    /// No fall back, no generic sentence, no empty library standing in for a
    /// refusal.
    func testAProviderFailureNeverProducesAppleScriptRows() {
        let status = StatusStore()
        let wire = Wire(pages: [noAccess])
        let spy = AppleScriptSpy(rows: [LibrarySong(id: "as1", title: "FromAppleScript", artist: "X", album: "Y")])
        let s = scene(mode: .source, wire: wire, spy: spy, status: status)
        toSongs(s)

        XCTAssertTrue(settle(s) { status.current() != nil }, "the failure was silent")
        XCTAssertEqual(status.current()?.text, "Bridge has not been granted Apple Music access")
        XCTAssertTrue(s.songsForTest.isEmpty, "a failed Bridge read produced rows anyway")
        XCTAssertFalse(spy.wasAsked, "Bridge mode fell back to the AppleScript library")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Bridge has not been granted Apple Music access"),
                      "the list showed a generic message: \(out)")
        XCTAssertFalse(out.contains("(no songs)"), "a refusal rendered as an empty library: \(out)")
    }

    /// Bridge may serve FEWER rows than were asked for and say so
    /// (`"clamped":true` — a 500-row request came back as 484 rows, measured
    /// 2026-09-23). A short page is not the end of the list: only a null cursor
    /// is. The walk reads the rows it was given and never compares them to the
    /// limit it sent.
    func testAClampedShortPageIsNotTheEndOfTheList() {
        let clamped = """
        {"ok":true,"op":"slice.librarySongs","generation":7,"total":15697,"clamped":true,"items":[
          {"id":"i.aaa","title":"Aquarama","artist":"Moomin","album":"Aquarama - Single","kind":"song"}],
         "next_cursor":"cursor-1"}
        """
        let tail = """
        {"ok":true,"op":"slice.librarySongs","generation":7,"total":15697,"clamped":false,"items":[
          {"id":"i.ccc","title":"Nude","artist":"Radiohead","album":"In Rainbows","kind":"song"}],
         "next_cursor":null}
        """
        let wire = Wire(pages: [clamped, tail])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 2 },
                      "a page shorter than the limit was read as the end of the list")
        XCTAssertEqual(s.songsForTest.map(\.id), ["i.aaa", "i.ccc"])
        XCTAssertEqual(wire.sent("slice.librarySongs").count, 2)
        // The count is Bridge's, read from the wire, never assumed here.
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Songs \u{2014} Bridge library (15,697)"),
                      "the count did not come from Bridge: \(s.render(frame: frame, snapshot: idle))")
    }

    // MARK: - Not ready yet is not empty

    private let warming = """
    {"ok":false,"op":"slice.librarySongs","error":{"kind":"warming",
     "detail":"preparing your library","retry_after":1.0}}
    """

    /// A cold Bridge with no snapshot says "not ready yet". The list SAYS so and
    /// the walk asks again on Bridge's own hint. It must never render as an
    /// empty library, which is what a person saw on 2026-09-23.
    func testWarmingShowsThePreparingLineAndAsksAgainOnTheHint() {
        let waits = Waits()
        // The third request (the first real page) is held, so the assertion lands
        // while the list is genuinely still waiting on Bridge rather than in a
        // gap between two instant retries.
        let wire = Wire(pages: [warming, warming, page1, page2], gateAt: 2)
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(),
                      status: StatusStore(), waits: waits)
        toSongs(s)

        XCTAssertTrue(settle(s) { wire.reached(2) }, "the walk never retried past the first warming")
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("Preparing your library\u{2026}") },
                      "the list did not say it was preparing; got: \(s.render(frame: frame, snapshot: idle))")
        let waiting = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(waiting.contains("(no songs)"), "a warming library rendered as an empty one: \(waiting)")
        XCTAssertFalse(waiting.contains("Bridge library (0)"), "it claimed a count it does not have: \(waiting)")
        XCTAssertTrue(s.songsForTest.isEmpty, "rows appeared before any page did")

        wire.release(at: 2)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 }, "the walk never got past warming")
        XCTAssertEqual(s.songsForTest.map(\.id), ["i.aaa", "i.bbb", "i.ccc"])
        XCTAssertEqual(waits.all, [1.0, 1.0], "it did not wait the hint Bridge gave")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Preparing your library"), "it is still claiming to be preparing: \(out)")
    }

    /// A hint is the provider's; the bounds are ours. A silly hint is clamped
    /// rather than obeyed, so no reply can spin or hang this process.
    func testAnAbsurdHintIsClampedRatherThanObeyed() {
        let waits = Waits()
        let wire = Wire(pages: ["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"warming","detail":"x","retry_after":0}}
        """, """
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"warming","detail":"x","retry_after":3600}}
        """, page1, page2])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(),
                      status: StatusStore(), waits: waits)
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })
        XCTAssertEqual(waits.all, [LibraryWarmUp.minWait, LibraryWarmUp.maxWait])
    }

    /// Patience runs out, and when it does the person is told it has STOPPED,
    /// with a way to ask again. An endless "Preparing…" would be its own lie.
    ///
    /// **Bounded by 60 s of waiting (D5), not by an attempt count.** `warming`'s
    /// hint is 1.0 s, so the budget holds for exactly sixty 1.0 s waits before
    /// it gives up on the 61st request — the same shape `WarmUpPatienceTests`
    /// proves against the policy directly; this proves it reaches the scene.
    func testWarmingIsBoundedAndEndsInAVisibleMessage() {
        let status = StatusStore()
        let requests = Int(LibraryWarmUp.maxTotalWait) + 1
        let wire = Wire(pages: Array(repeating: warming, count: requests))
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: status)
        toSongs(s)

        XCTAssertTrue(settle(s, seconds: 5) { status.current() != nil },
                      "it waited forever without saying so")
        XCTAssertEqual(status.current()?.text, LibraryWarmUp.gaveUp)
        XCTAssertEqual(status.current()?.isError, true)
        XCTAssertEqual(wire.sent("slice.librarySongs").count, requests,
                       "the retries were not bounded at \(LibraryWarmUp.maxTotalWait)s of waiting")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Bridge is still preparing your library - press r to retry"),
                      "the list did not say it had stopped: \(out)")
        XCTAssertFalse(out.contains("(no songs)"), "it rendered as an empty library: \(out)")
    }

    /// `stale` and `refreshing` are information about the snapshot, not a
    /// failure: the rows render exactly as a fresh page's do.
    func testAStaleRefreshingPageRendersLikeAnyOther() {
        let servedFromAnOldSnapshot = """
        {"ok":true,"op":"slice.librarySongs","generation":7,"total":15697,"stale":true,"refreshing":true,
         "items":[{"id":"i.aaa","title":"Aquarama","artist":"Moomin","album":"A","kind":"song"}],
         "next_cursor":null}
        """
        let wire = Wire(pages: [servedFromAnOldSnapshot])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.count == 1 }, "a stale page was refused")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Aquarama"))
        XCTAssertTrue(out.contains("Songs \u{2014} Bridge library (15,697)"))
        XCTAssertFalse(out.contains("Preparing your library"), "freshness was reported as warming: \(out)")
        XCTAssertFalse(out.contains("press r to retry"), "freshness was reported as a failure: \(out)")
    }

    // MARK: - A restart does not blank the list

    /// The list a person is reading stays up while the replacement is fetched,
    /// and is then replaced WHOLESALE — never half of one generation beside half
    /// of another.
    func testARestartKeepsTheOldRowsUntilTheNewFirstPageArrives() {
        // Two gates. The first holds the stale refusal until page one is actually
        // ON SCREEN — the canned walk otherwise outruns the drain and there is no
        // "old list" to keep. The second holds the replacement's first page, which
        // is the window this whole rule is about.
        let wire = Wire(pages: [page1, staleRefusal, regenerated], gateAt: [1, 2])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)

        XCTAssertTrue(settle(s) { s.songsForTest.map(\.id) == ["i.aaa", "i.bbb"] },
                      "page one never reached the list")
        wire.release(at: 1)                                  // now the library changes underneath

        XCTAssertTrue(settle(s) { wire.reached(2) }, "the restart never asked for a new first page")
        XCTAssertEqual(s.songsForTest.map(\.id), ["i.aaa", "i.bbb"],
                       "the list blanked itself while the replacement was in flight")
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Aquarama"),
                      "the rows on screen vanished during the restart")

        wire.release(at: 2)
        XCTAssertTrue(settle(s) { s.songsForTest.map(\.id) == ["i.zzz"] },
                      "the new generation never replaced the old; got \(s.songsForTest.map(\.id))")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Aquarama"), "two generations are on screen together: \(out)")
    }

    // MARK: - A cold queue waits rather than failing to play

    private let queueWarming = """
    {"ok":false,"op":"slice.queue","error":{"kind":"warming",
     "detail":"preparing your library","retry_after":1.0}}
    """

    /// Pressing Enter on a cold Bridge must not fail to play. The queue is
    /// re-sent on Bridge's own hint — safe, because no player state changes
    /// before Bridge has its snapshot — and the row plays once it is ready.
    func testAColdQueueWaitsOnTheHintAndThenPlays() {
        let status = StatusStore()
        let waits = Waits()
        let wire = Wire(pages: [page1, page2],
                        queueReplies: [queueWarming, queueWarming])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: status, waits: waits)
        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })

        _ = s.handle(.down)                                  // second row
        XCTAssertEqual(s.handle(.enter), .push(.nowPlaying))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").count < 3 { usleep(5_000) }

        let queued = wire.sent("slice.queue")
        XCTAssertEqual(queued.count, 3, "the cold queue was not retried")
        XCTAssertTrue(queued.allSatisfy { ($0["library_ids"] as? [String]) == ["i.bbb"] },
                      "a retry sent something other than the unchanged request")
        XCTAssertEqual(waits.all, [1.0, 1.0], "it did not wait the hint Bridge gave")
        XCTAssertEqual(status.current()?.text,
                       "Preparing your library \u{2014} 'Lotus Flower' will play when it's ready\u{2026}",
                       "the wait was silent")
        XCTAssertEqual(status.current()?.isError, false, "waiting is not an error")
    }

    /// And it does not wait forever. When patience runs out the person is told,
    /// rather than being left with a row that never plays and no explanation.
    ///
    /// **Bounded by 60 s of waiting (D5), not by an attempt count** — the same
    /// change as the list walk's, because it is the same shared policy.
    func testAColdQueueGivesUpVisiblyRatherThanWaitingForever() {
        let status = StatusStore()
        let requests = Int(LibraryWarmUp.maxTotalWait) + 1
        let wire = Wire(pages: [page1, page2],
                        queueReplies: Array(repeating: queueWarming, count: requests))
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: status)
        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })

        _ = s.handle(.enter)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && status.current()?.text != LibraryWarmUp.gaveUp { usleep(5_000) }

        XCTAssertEqual(status.current()?.text, LibraryWarmUp.gaveUp, "the give-up was silent")
        XCTAssertEqual(status.current()?.isError, true)
        XCTAssertEqual(wire.sent("slice.queue").count, requests,
                       "the queue retries were not bounded at \(LibraryWarmUp.maxTotalWait)s of waiting")
    }

    // MARK: - Two backends, two failure states

    /// C2 rewrite of `testABridgeFailureLeavesTheMusicAppListsAlone`: with
    /// D1/D7, Bridge selected means Albums is ALSO Bridge-sourced, not
    /// Music.app's — a Songs refusal must not mark it failed, and it must
    /// show Bridge's own rows, never having asked Music.app at all.
    func testABridgeSongsFailureLeavesTheBridgeAlbumsListAlone() {
        let status = StatusStore()
        let albumPage = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
         "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],
         "next_cursor":null}
        """
        let wire = Wire(pages: [noAccess], albumPages: [albumPage])
        let spy = AppleScriptSpy()
        let s = scene(mode: .source, wire: wire, spy: spy, status: status)
        toSongs(s)
        XCTAssertTrue(settle(s) { status.current() != nil }, "the Bridge Songs failure was silent")

        go(s, to: .albums)
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "Albums did not show Bridge's own rows; got: \(s.render(frame: frame, snapshot: idle))")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Bridge has not been granted"),
                       "the Songs failure bled into the Albums list: \(out)")
        XCTAssertFalse(out.contains("Couldn't read the Music library"),
                       "Albums read Music.app instead of Bridge: \(out)")
        XCTAssertEqual(spy.albumReads, 0, "Albums asked Music.app instead of Bridge")
        XCTAssertFalse(spy.wasAsked, "the Music.app source was asked at all")
    }

    /// C2 rewrite of `testAMusicAppFailureLeavesTheBridgeListAlone`: in Bridge
    /// mode no list reads Music.app any more (D1), so a Music.app source that
    /// would fail is simply never consulted — every spy count stays 0 across
    /// all three lists.
    func testInBridgeModeNoListReadsMusicApp() {
        let emptyAlbums = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":0,"items":[],"next_cursor":null}
        """
        let emptyArtists = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":0,"items":[],"next_cursor":null}
        """
        let wire = Wire(pages: [page1, page2], albumPages: [emptyAlbums], artistPages: [emptyArtists])
        // A Music.app source that would FAIL every read, so any list that
        // reached it would show the generic failure text.
        let spy = AppleScriptSpy(albumsSucceed: false)
        let s = scene(mode: .source, wire: wire, spy: spy, status: StatusStore())

        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })
        go(s, to: .albums)
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("(no albums)") },
                      "Albums never settled; got: \(s.render(frame: frame, snapshot: idle))")
        go(s, to: .artists)
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("(no artists)") },
                      "Artists never settled; got: \(s.render(frame: frame, snapshot: idle))")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Couldn't read the Music library"),
                       "a list read the failing Music.app source: \(out)")
        XCTAssertEqual(spy.albumReads, 0)
        XCTAssertEqual(spy.artistReads, 0)
        XCTAssertFalse(spy.wasAsked)
    }

    /// `r` on a failed Bridge list asks BRIDGE again — its own retry, not the
    /// shared AppleScript budget.
    func testRetryOnAFailedBridgeListAsksBridgeAgain() {
        let status = StatusStore()
        let wire = Wire(pages: [noAccess, page1, page2])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: status)
        toSongs(s)
        XCTAssertTrue(settle(s) { status.current() != nil })
        XCTAssertEqual(wire.sent("slice.librarySongs").count, 1)

        _ = s.handle(.char("r"))
        XCTAssertEqual(status.current()?.text, "Asking Bridge for your library again\u{2026}")
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 }, "the retry never re-read Bridge")
        XCTAssertEqual(s.songsForTest.map(\.id), ["i.aaa", "i.bbb", "i.ccc"])
    }

    // MARK: - All three lists say what they show

    /// C2 rewrite of `testInBridgeModeAlbumsAndArtistsNameMusicAppAsTheirLibrary`:
    /// with D1, Albums and Artists are ALSO Bridge's now, and the count each
    /// header shows comes from the wire's own `total` — never predicted here.
    func testInBridgeModeAllThreeListsNameBridgeAndItsCount() {
        let albumPage = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":3012,
         "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],
         "next_cursor":null}
        """
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1801,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let wire = Wire(pages: [page1, page2], albumPages: [albumPage], artistPages: [artistPage])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())

        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })
        XCTAssertTrue(s.render(frame: frame, snapshot: idle)
                       .contains("Songs \u{2014} Bridge library (15,646)"))

        go(s, to: .albums)
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        XCTAssertTrue(s.render(frame: frame, snapshot: idle)
                       .contains("Albums \u{2014} Bridge library (3,012)"),
                      "the Albums count did not come from the wire: \(s.render(frame: frame, snapshot: idle))")

        go(s, to: .artists)
        XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        XCTAssertTrue(s.render(frame: frame, snapshot: idle)
                       .contains("Artists \u{2014} Bridge library (1,801)"),
                      "the Artists count did not come from the wire: \(s.render(frame: frame, snapshot: idle))")
    }

    /// In Music.app mode there is only one library, so no list says anything —
    /// all three headers are exactly what they have always been.
    func testInMusicAppModeNoListNamesALibrary() {
        let wire = Wire(pages: [page1])
        let spy = AppleScriptSpy(rows: [LibrarySong(id: "as1", title: "FromAppleScript", artist: "X", album: "Y")],
                                 albums: [LibraryAlbum(id: "al1", name: "In Rainbows", artist: "Radiohead", trackCount: 10)],
                                 artists: [LibraryArtist(id: "ar1", name: "Radiohead")])
        let s = scene(mode: .musicApp, wire: wire, spy: spy, status: StatusStore())

        let expected: [LibrarySubView: String] = [.albums: "In Rainbows", .artists: "Radiohead",
                                                  .songs: "FromAppleScript"]
        for sub in LibrarySubView.allCases {
            go(s, to: sub)
            let row = expected[sub]!
            XCTAssertTrue(settle(s) { s.render(frame: frame, snapshot: idle).contains(row) },
                          "\(sub) never loaded its rows")
            let out = s.render(frame: frame, snapshot: idle)
            XCTAssertFalse(out.contains("Music.app library"), "\(sub) named a library: \(out)")
            XCTAssertFalse(out.contains("Bridge library"), "\(sub) named Bridge: \(out)")
        }
        XCTAssertTrue(wire.sent("slice.librarySongs").isEmpty, "Music.app mode asked Bridge for the library")
    }

    // MARK: - Playing a row

    /// The reason the seam exists: Enter plays the row by the id Bridge gave it.
    /// No `rows` join, no `ids` (those are catalogue ids), and no album needed.
    func testEnterPlaysTheRowByBridgesOwnId() {
        let wire = Wire(pages: [page1, page2])
        let s = scene(mode: .source, wire: wire, spy: AppleScriptSpy(), status: StatusStore())
        toSongs(s)
        XCTAssertTrue(settle(s) { s.songsForTest.count == 3 })

        _ = s.handle(.down)                       // second row: Lotus Flower
        let action = s.handle(.enter)
        XCTAssertEqual(action, .push(.nowPlaying), "a play still jumps to Now Playing")

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").isEmpty { usleep(5_000) }
        let queued = wire.sent("slice.queue")
        XCTAssertEqual(queued.count, 1, "the row never reached Bridge")
        XCTAssertEqual(queued[0]["library_ids"] as? [String], ["i.bbb"])
        XCTAssertNil(queued[0]["rows"], "no (title, artist, album) join may be sent")
        XCTAssertNil(queued[0]["ids"], "library ids are not catalogue ids")
    }
}

/// The paged walk on its own, against a fake provider — the restart rule without
/// a scene, a socket or a thread.
final class LibrarySongWalkTests: XCTestCase {

    /// Answers from a script of outcomes, one per call, and records the cursor
    /// it was asked with each time.
    private final class Fake: MusicDataProvider {
        private(set) var cursors: [String?] = []
        private let script: [Result<MusicPage, MusicProviderError>]
        private var calls = 0

        init(_ script: [Result<MusicPage, MusicProviderError>]) { self.script = script }

        func librarySongs(cursor: String?, limit: Int) throws -> MusicPage {
            cursors.append(cursor)
            let n = calls
            calls += 1
            guard n < script.count else { throw MusicProviderError.unavailable("unscripted call") }
            switch script[n] {
            case .success(let page): return page
            case .failure(let error): throw error
            }
        }
        func play(ids: [String]) throws -> BridgeNow.Queue {
            throw MusicProviderError.notImplemented("not used here")
        }
        func nowPlaying() throws -> SourceStatus {
            throw MusicProviderError.notImplemented("not used here")
        }
    }

    private func page(_ ids: [String], generation: Int?, next: String?) -> MusicPage {
        MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .song) },
                  nextCursor: next, total: ids.count, generation: generation)
    }

    func testAWalkFollowsEveryCursorAndStopsAtTheEnd() {
        let fake = Fake([.success(page(["a"], generation: 1, next: "c1")),
                         .success(page(["b"], generation: 1, next: nil))])
        var seen: [String] = []
        let error = walkLibrarySongs(fake, onPage: { seen += $0.rows.map(\.id); return true },
                                     onRestart: { XCTFail("nothing changed underneath") })
        XCTAssertNil(error)
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(fake.cursors, [nil, "c1"])
    }

    /// A generation that changes BETWEEN pages is stale even when the provider
    /// did not say so — the page's own boundary is what decides.
    func testAGenerationThatChangesBetweenPagesRestarts() {
        let fake = Fake([.success(page(["a"], generation: 1, next: "c1")),
                         .success(page(["b"], generation: 2, next: "c2")),
                         .success(page(["z"], generation: 3, next: nil))])
        var seen: [String] = []
        var restarts = 0
        let error = walkLibrarySongs(fake, onPage: { seen += $0.rows.map(\.id); return true },
                                     onRestart: { restarts += 1; seen = [] })
        XCTAssertNil(error)
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(seen, ["z"], "rows from two observations were mixed")
        XCTAssertEqual(fake.cursors, [nil, "c1", nil], "the restart did not begin at the first page")
    }

    func testASecondStaleGenerationEndsTheWalk() {
        let fake = Fake([.failure(.staleGeneration("changed once")),
                         .failure(.staleGeneration("changed twice"))])
        let error = walkLibrarySongs(fake, onPage: { _ in true }, onRestart: {})
        XCTAssertEqual(error, .staleGeneration("changed twice"))
    }

    func testAnOrdinaryFailureEndsTheWalkWithItsOwnWords() {
        let fake = Fake([.failure(.refused("limit must be 1...500"))])
        let error = walkLibrarySongs(fake, onPage: { _ in true },
                                     onRestart: { XCTFail("a refusal is not a restart") })
        XCTAssertEqual(error, .refused("limit must be 1...500"))
    }

    /// A caller that has gone away ends the walk with no error: nothing failed,
    /// there is just nobody to tell.
    func testACallerThatStopsListeningEndsTheWalkQuietly() {
        let fake = Fake([.success(page(["a"], generation: 1, next: "c1")),
                         .success(page(["b"], generation: 1, next: nil))])
        let error = walkLibrarySongs(fake, onPage: { _ in false }, onRestart: {})
        XCTAssertNil(error)
        XCTAssertEqual(fake.cursors, [nil], "it kept walking after the caller stopped")
    }

    /// A warming mid-walk re-asks for the SAME page. It is not a restart: the
    /// library did not change, the provider was just not ready for that page
    /// yet, and starting over would throw away everything already collected.
    func testWarmingRetriesTheSamePageAndNotTheWholeWalk() {
        let fake = Fake([.success(page(["a"], generation: 1, next: "c1")),
                         .failure(.warming("hold on", retryAfter: 2)),
                         .success(page(["b"], generation: 1, next: nil))])
        var seen: [String] = []
        var hints: [TimeInterval] = []
        var slept: [TimeInterval] = []
        let error = walkLibrarySongs(fake, onPage: { seen += $0.rows.map(\.id); return true },
                                     onRestart: { XCTFail("warming is not a restart") },
                                     onWarming: { hints.append($0) },
                                     sleep: { slept.append($0) })
        XCTAssertNil(error)
        XCTAssertEqual(seen, ["a", "b"], "the walk started over instead of resuming")
        XCTAssertEqual(fake.cursors, [nil, "c1", "c1"], "it did not re-ask for the page it was refused")
        XCTAssertEqual(hints, [2])
        XCTAssertEqual(slept, [2])
    }

    /// Bounded, and the last word is that it STOPPED preparing — not a silent
    /// give-up and not an endless wait.
    ///
    /// **Bounded by 60 s of waiting (D5), not by an attempt count.** A 1 s hint
    /// gives exactly sixty waits before the budget is spent, so the 61st
    /// request is the one that gives up.
    func testWarmingStopsAfterItsBoundedAttempts() {
        let requests = Int(LibraryWarmUp.maxTotalWait) + 1
        let script = Array(repeating: Result<MusicPage, MusicProviderError>
                            .failure(.warming("still going", retryAfter: 1)),
                           count: requests)
        let fake = Fake(script)
        var slept: [TimeInterval] = []
        let error = walkLibrarySongs(fake, onPage: { _ in true }, onRestart: {},
                                     onWarming: { _ in }, sleep: { slept.append($0) })
        guard case .warming(let why, _)? = error else {
            return XCTFail("expected a warming give-up, got \(String(describing: error))")
        }
        XCTAssertEqual(why, LibraryWarmUp.gaveUp)
        XCTAssertEqual(fake.cursors.count, requests)
        XCTAssertEqual(slept.count, Int(LibraryWarmUp.maxTotalWait), "it slept after giving up")
        XCTAssertEqual(slept.reduce(0, +), LibraryWarmUp.maxTotalWait, accuracy: 0.0001,
                       "the recorded waits did not sum to the budget")
    }

    func testTheHintIsClampedAtBothEnds() {
        XCTAssertEqual(LibraryWarmUp.wait(forHint: 0), LibraryWarmUp.minWait)
        XCTAssertEqual(LibraryWarmUp.wait(forHint: -5), LibraryWarmUp.minWait)
        XCTAssertEqual(LibraryWarmUp.wait(forHint: 1.0), 1.0)
        XCTAssertEqual(LibraryWarmUp.wait(forHint: 86_400), LibraryWarmUp.maxWait)
    }

    func testACountReadsTheSameWhateverTheMachinesLocaleIs() {
        XCTAssertEqual(groupedCount(15646), "15,646")
        XCTAssertEqual(groupedCount(999), "999")
        XCTAssertEqual(groupedCount(1000), "1,000")
        XCTAssertEqual(groupedCount(0), "0")
    }
}
