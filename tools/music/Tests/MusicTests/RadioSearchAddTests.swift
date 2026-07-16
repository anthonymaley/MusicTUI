// tools/music/Tests/MusicTests/RadioSearchAddTests.swift
//
// Coverage for the `/` = catalog search / `a` = add-by-URL split (the local
// filter was dropped: `/` used to filter the current sub-view's list, which
// on a short list like Live's 6 stations meant "/jazz" matched nothing and
// looked dead). These drive RadioScene.handle()/render() directly, exercising
// only the synchronous branches (no catalog, so no background thread lands) —
// the live network search/resolve path is verified by hand against the real
// TUI, not here.
import XCTest
@testable import music

final class RadioSearchAddTests: XCTestCase {
    private let frame = shellLayout(width: 80, height: 24)
    private let snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    private func makeScene(catalog: RadioCatalog? = nil) -> RadioScene {
        let tmpPath = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        return RadioScene(store: StationStore(path: tmpPath), catalog: catalog)
    }

    private func type(_ s: String, into handle: (KeyPress) -> SceneAction) {
        for c in s { _ = handle(.char(c)) }
    }

    // `/` no longer filters the sub-view list — it opens a search box that
    // only fires on Enter. With no catalog wired, committing surfaces the
    // "needs auth" message rather than silently narrowing `rows`, proving the
    // keystroke went to a search attempt and not a local filter.
    func testSlashCommitsAsSearchNotLocalFilter() {
        let scene = makeScene()
        _ = scene.handle(.char("/"))
        type("jazz", into: scene.handle)
        _ = scene.handle(.enter)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("Search needs auth"),
                       "expected Enter on `/` to attempt a catalog search, got: \(out)")
    }

    // `a` + a non-URL input must redirect to `/` rather than being treated as
    // a search term (that's the old `a` behavior, now retired).
    func testAddWithNonURLRedirectsToSearch() {
        let scene = makeScene()
        _ = scene.handle(.char("a"))
        type("jazz", into: scene.handle)
        _ = scene.handle(.enter)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("Not a station URL") && out.contains("press / to search"),
                       "expected a non-URL `a` input to redirect to /, got: \(out)")
    }

    // `a` + a real station URL still favorites synchronously from the slug —
    // unchanged from the old commitAdd URL branch, just renamed/relocated.
    func testAddWithURLFavorites() {
        let scene = makeScene()
        _ = scene.handle(.char("a"))
        type("https://music.apple.com/us/station/bbc-radio-1/ra.1460912634", into: scene.handle)
        _ = scene.handle(.enter)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("Bbc Radio 1"), "expected the URL add to favorite the station, got: \(out)")
    }
}
