// tools/music/Tests/MusicTests/MarkedSetKeysTests.swift
import XCTest
@testable import music

/// Combined play, step 4: `m` marks on the Albums and Playlists rails, into ONE
/// `MarkedSetStore` both scenes share; marked rows show a glyph; Esc clears the
/// marks before it means back. Every AppleScript goes to a fake interpreter
/// (`HonestPlayingTests.FakeMusicInterpreter`), the mode file is a temp file,
/// the caches are temp files: nothing reaches Music, osascript, the SpanDAC
/// socket, the keychain or ~/.config/music.
final class MarkedSetKeysTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    private func musicAppRouting() -> RoutingCoordinator {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.musicApp)
        return RoutingCoordinator(store: modeStore, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "" }) })
    }

    private final class AlbumLog {
        private let lock = NSLock()
        private var value: [String] = []
        func add(_ s: String) { lock.lock(); value.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct LibraryRig {
        let scene: LibraryScene
        let status: StatusStore
        let actions: ActionRunner
        let store: AppQueueStore
        let fake: HonestPlayingTests.FakeMusicInterpreter
        let resolved: AlbumLog
    }

    private func libraryRig(marks: MarkedSetStore) -> LibraryRig {
        let fake = HonestPlayingTests.FakeMusicInterpreter()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let store = AppQueueStore()
        let resolved = AlbumLog()
        let albums = [LibraryAlbum(id: "al0", name: "Moon Safari", artist: "Air", trackCount: 2),
                      LibraryAlbum(id: "al1", name: "Mezzanine", artist: "Massive Attack", trackCount: 2)]
        let songs = [LibrarySong(id: "s0", title: "Teardrop", artist: "Massive Attack", album: "Mezzanine")]
        let sources = LibraryDataSources(onAlbums: { page in _ = page(albums); return true },
                                         onSongs: { page in _ = page(songs); return true },
                                         onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        let tracks = (1...2).map { TrackListEntry(index: 40 + $0, name: "T\($0)", artist: "Air", isCurrent: false) }
        let scene = LibraryScene(backend: fake.backend, routing: musicAppRouting(), sources: sources, appQueue: store,
                                 status: status, actions: actions,
                                 resolveAlbum: { _, title, _ in
                                     resolved.add(title)
                                     return AlbumResolution(tracks: tracks, matched: 2)
                                 },
                                 resultCache: temporaryResultCache().cache,
                                 screenWidth: { 160 },
                                 marks: marks)
        goToSubView(scene, .albums)
        XCTAssertTrue(settleScene(scene) { scene.render(frame: self.frame, snapshot: self.idle).contains("Moon Safari") },
                      "the albums never loaded")
        return LibraryRig(scene: scene, status: status, actions: actions, store: store, fake: fake, resolved: resolved)
    }

    private static let chillID = "00000000000000F1"
    private static let focusID = "00000000000000F2"

    private func playlistsScene(marks: MarkedSetStore, status: StatusStore = StatusStore(),
                                ids: [String?] = [MarkedSetKeysTests.chillID, MarkedSetKeysTests.focusID]) -> PlaylistsScene {
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Chill", "Focus"]
        spy.persistentIDs = ids
        return PlaylistsScene(backend: HonestPlayingTests.FakeMusicInterpreter().backend, routing: musicAppRouting(),
                              playlists: ["Chill", "Focus"], playlistIDs: ids, sources: spy.sources(),
                              appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                              metaCache: temporaryPlaylistMetaCache().cache,
                              loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                              makeSources: { spy.makeSources($0) },
                              warmUpSleep: { _ in },
                              screenWidth: { 160 },
                              marks: marks)
    }

    private let glyph = markedRowGlyph

    // MARK: -

    func testMOnAlbumRailMarks() {
        let marks = MarkedSetStore()
        let r = libraryRig(marks: marks)
        XCTAssertFalse(r.scene.render(frame: frame, snapshot: idle).contains(glyph))
        XCTAssertEqual(r.scene.handle(.char("m")), .redraw)
        XCTAssertEqual(marks.items, [.album(title: "Moon Safari", artist: "Air")])
        XCTAssertEqual(r.status.current()?.text, "Marked 1 \u{00B7} p plays them, Esc clears")
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("\(glyph) Moon Safari"),
                      "the marked row shows the mark")
        _ = r.scene.handle(.down)
        _ = r.scene.handle(.char("m"))
        XCTAssertEqual(marks.items, [.album(title: "Moon Safari", artist: "Air"),
                                     .album(title: "Mezzanine", artist: "Massive Attack")], "in mark order")
        XCTAssertEqual(r.status.current()?.text, "Marked 2 \u{00B7} p plays them, Esc clears")
        _ = r.scene.handle(.up)
        _ = r.scene.handle(.char("m"))
        XCTAssertEqual(marks.items, [.album(title: "Mezzanine", artist: "Massive Attack")], "m again unmarks")
        XCTAssertFalse(r.scene.render(frame: frame, snapshot: idle).contains("\(glyph) Moon Safari"))
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("\(glyph) Mezzanine"))
    }

    func testMOnPlaylistRailMarks() {
        let marks = MarkedSetStore()
        let status = StatusStore()
        let s = playlistsScene(marks: marks, status: status)
        _ = s.tick(snapshot: idle)
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        XCTAssertEqual(marks.items, [.playlist(id: Self.chillID, name: "Chill")])
        guard case .playlist(let id, let name)? = marks.items.first else { return XCTFail("\(marks.items)") }
        XCTAssertEqual(id, Self.chillID, "the mark records the row's own persistent ID")
        XCTAssertEqual(name, "Chill", "and keeps the name for display")
        XCTAssertEqual(status.current()?.text, "Marked 1 \u{00B7} p plays them, Esc clears")
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("\(glyph) Chill"))
        XCTAssertFalse(s.render(frame: frame, snapshot: idle).contains("\(glyph) Focus"))
    }

    func testMarksSurviveTabSwitch() {
        let marks = MarkedSetStore()
        let r = libraryRig(marks: marks)
        _ = r.scene.handle(.char("m"))
        // To Playlists: the same store, so the album mark is still there and
        // a playlist joins it after.
        let p = playlistsScene(marks: marks)
        p.becameActive()
        _ = p.tick(snapshot: idle)
        _ = p.handle(.char("m"))
        // And back to Library.
        r.scene.becameActive()
        _ = r.scene.tick(snapshot: idle)
        XCTAssertEqual(marks.items, [.album(title: "Moon Safari", artist: "Air"),
                                     .playlist(id: Self.chillID, name: "Chill")])
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("\(glyph) Moon Safari"))
        XCTAssertTrue(p.render(frame: frame, snapshot: idle).contains("\(glyph) Chill"))
    }

    func testEscClearsMarksBeforePop() {
        let marks = MarkedSetStore()
        let r = libraryRig(marks: marks)
        _ = r.scene.handle(.char("m"))
        XCTAssertEqual(r.scene.handle(.escape), .redraw, "Esc clears the marks first")
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(r.status.current()?.text, "Marks cleared")
        XCTAssertEqual(r.scene.handle(.escape), .pop, "then Esc means what it always did")

        let status = StatusStore()
        let p = playlistsScene(marks: marks, status: status)
        _ = p.tick(snapshot: idle)
        _ = p.handle(.char("m"))
        XCTAssertEqual(p.handle(.escape), .redraw)
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(p.handle(.escape), .pop)
    }

    func testPWithNoMarksUnchanged() {
        let marks = MarkedSetStore()
        let r = libraryRig(marks: marks)
        XCTAssertEqual(r.scene.handle(.char("p")), .push(.nowPlaying))
        r.actions.waitUntilIdle()
        XCTAssertEqual(r.resolved.all, ["Moon Safari"], "the highlighted album, as today")
        XCTAssertEqual(r.store.read()?.playlistName, "Library", "today's position-addressed album queue")
        XCTAssertTrue(r.fake.playScripts.allSatisfy { $0.contains("play track 41 of playlist \"Library\"") },
                      r.fake.playScripts.joined(separator: "\n---\n"))
        XCTAssertTrue(marks.isEmpty)
    }

    /// A rail row whose persistent ID was not read cannot be marked: `m` says
    /// why, and nothing is added. The rows that have one still mark.
    func testMOnARowWithNoIDSaysWhyAndMarksNothing() {
        let marks = MarkedSetStore()
        let status = StatusStore()
        let s = playlistsScene(marks: marks, status: status, ids: [Self.chillID, nil])
        _ = s.tick(snapshot: idle)
        _ = s.handle(.down)
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        XCTAssertTrue(marks.isEmpty, "a row with no ID was marked: \(marks.items)")
        XCTAssertEqual(status.current()?.text, "'Focus' can't be marked: its playlist ID wasn't read, so nothing was marked.")
        XCTAssertEqual(status.current()?.text, playlistUnmarkableLine("Focus"))
        XCTAssertFalse(s.render(frame: frame, snapshot: idle).contains("\(glyph) Focus"))
        _ = s.handle(.up)
        _ = s.handle(.char("m"))
        XCTAssertEqual(marks.items, [.playlist(id: Self.chillID, name: "Chill")])
    }

    func testMIsIgnoredOffTheRails() {
        let marks = MarkedSetStore()
        let r = libraryRig(marks: marks)
        // The Songs list is not a rail.
        goToSubView(r.scene, .songs)
        XCTAssertTrue(settleScene(r.scene) { r.scene.render(frame: self.frame, snapshot: self.idle).contains("Teardrop") })
        XCTAssertEqual(r.scene.handle(.char("m")), .none)
        // Nor is the Artists list.
        goToSubView(r.scene, .artists)
        XCTAssertEqual(r.scene.handle(.char("m")), .none)
        XCTAssertTrue(marks.isEmpty)

        // The Playlists tracks pane is not the rail.
        let p = playlistsScene(marks: marks)
        _ = p.tick(snapshot: idle)
        _ = p.handle(.enter)
        XCTAssertEqual(p.handle(.char("m")), .none)
        XCTAssertTrue(marks.isEmpty)
    }
}
