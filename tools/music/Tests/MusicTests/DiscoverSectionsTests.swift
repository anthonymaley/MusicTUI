// tools/music/Tests/MusicTests/DiscoverSectionsTests.swift
//
// Discover's self-named sections (TODO "Discover second pass"): Recently
// Added, Recent Stations, Top Songs, Top Albums, Top Playlists.
//
// They come from the web service only. With SpanDAC data every read is
// SpanDAC's and nothing falls back (Anthony, 2026-09-29), and SpanDAC serves
// no equivalent, so there the sections are absent.
//
// Fakes only: the web service is a closure answering by URL path, SpanDAC is
// `SceneDataRig`'s by-op transport. No network, no Music.app, no socket, no
// `~/.config/music`. The response bodies follow Apple's documented shapes
// (the 2026-08-25 probes recorded status codes, not bodies).
import XCTest
@testable import music

/// Answers by path prefix and records every URL asked, thread-safely (the
/// scene reads off the main thread).
final class SectionWebService {
    private let lock = NSLock()
    private var stored: [String] = []
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func asked(_ fragment: String) -> [String] { urls.filter { $0.contains(fragment) } }

    /// Path (no query) -> body. nil body: the fetch fails.
    var bodies: [String: String?]

    init(bodies: [String: String?] = SectionWebService.fullFeed) { self.bodies = bodies }

    func feed() -> DiscoverFeed {
        DiscoverFeed(storefront: "us", token: { "t" }, fetch: { [self] url in
            lock.lock(); stored.append(url); let bodies = self.bodies; lock.unlock()
            let path = url.replacingOccurrences(of: "https://api.music.apple.com", with: "")
                .components(separatedBy: "?")[0]
            guard let body = bodies[path] ?? nil else { return nil }
            return Data(body.utf8)
        })
    }

    static let recommendations = """
    {"data":[{"id":"6-27s5hU6azhJY","type":"personal-recommendation",
      "attributes":{"kind":"music-recommendations","resourceTypes":["playlists"],
        "title":{"stringForDisplay":"Playlists Made for You"}},
      "relationships":{"contents":{"data":[
        {"id":"pl.pm-1","type":"playlists","attributes":{"name":"Your Essentials","curatorName":"Apple Music"}}
      ]}}}]}
    """

    /// Apple's documented example shape: library resources, no catalogue id
    /// in an album's playParams.
    static let recentlyAdded = """
    {"next":"/v1/me/library/recently-added?offset=10","data":[
      {"id":"l.NWqWi1m","type":"library-albums","attributes":{"name":"Dopamine - Single",
        "artistName":"Elephante","playParams":{"id":"l.NWqWi1m","kind":"album","isLibrary":true}}},
      {"id":"p.mine","type":"library-playlists","attributes":{"name":"My Own Mix"}},
      {"id":"l.bare","type":"library-albums","attributes":{"name":"Bare Album","artistName":"Bare Artist",
        "artwork":{"url":"https://example.com/bare/{w}x{h}.jpg"}}},
      {"id":"p.apple","type":"library-playlists","attributes":{"name":"Deep House Lab"}},
      {"id":"x.video","type":"library-music-videos","attributes":{"name":"A Video"}}
    ]}
    """

    static let libraryAlbums = """
    {"data":[
      {"id":"l.NWqWi1m","type":"library-albums","attributes":{"name":"Dopamine - Single"},
       "relationships":{"catalog":{"data":[{"id":"1585000001","type":"albums",
         "attributes":{"name":"Dopamine - Single","artistName":"Elephante","trackCount":1,
           "releaseDate":"2021-10-01","genreNames":["Electronic"]}}]}}},
      {"id":"l.bare","type":"library-albums","attributes":{"name":"Bare Album","artistName":"Bare Artist",
        "artwork":{"url":"https://example.com/bare/{w}x{h}.jpg"}},
       "relationships":{"catalog":{"data":[{"id":"1585000002","type":"albums"}]}}}
    ]}
    """

    /// His own playlist has no catalogue counterpart (empty relationship).
    static let libraryPlaylists = """
    {"data":[
      {"id":"p.mine","type":"library-playlists","attributes":{"name":"My Own Mix"},
       "relationships":{"catalog":{"data":[]}}},
      {"id":"p.apple","type":"library-playlists","attributes":{"name":"Deep House Lab"},
       "relationships":{"catalog":{"data":[{"id":"pl.deephouse","type":"playlists",
         "attributes":{"name":"Deep House Lab","curatorName":"Apple Music Dance"}}]}}}
    ]}
    """

    static let recentStations = """
    {"data":[
      {"id":"ra.978194965","type":"stations","attributes":{"name":"Apple Music 1","isLive":true,
        "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965"}},
      {"id":"ra.u-01e4","type":"stations","attributes":{"name":"Anthony Maley’s Station",
        "url":"https://music.apple.com/us/station/anthony-maleys-station/ra.u-01e4"}}
    ]}
    """

    /// results: type -> ARRAY of charts. Albums' first chart is empty, so the
    /// second is the one shown.
    static let charts = """
    {"results":{
      "songs":[{"chart":"most-played","name":"Top Songs","data":[
        {"id":"s1","type":"songs","attributes":{"name":"Song One","artistName":"A1"}},
        {"id":"s2","type":"songs","attributes":{"name":"Song Two","artistName":"A2"}},
        {"id":"s3","type":"songs","attributes":{"name":"Song Three","artistName":"A3"}},
        {"id":"s4","type":"songs","attributes":{"name":"Song Four","artistName":"A4"}},
        {"id":"s5","type":"songs","attributes":{"name":"Song Five","artistName":"A5"}}]}],
      "albums":[{"chart":"empty","name":"Nothing","data":[]},
                {"chart":"most-played","name":"Top Albums","data":[
        {"id":"a1","type":"albums","attributes":{"name":"Album One","artistName":"B1"}}]}],
      "playlists":[{"chart":"most-played","name":"Top Playlists","data":[
        {"id":"pl.t1","type":"playlists","attributes":{"name":"Today's Hits","curatorName":"Apple Music"}}]}]
    }}
    """

    static let fullFeed: [String: String?] = [
        "/v1/me/recommendations": recommendations,
        "/v1/me/library/recently-added": recentlyAdded,
        "/v1/me/library/albums": libraryAlbums,
        "/v1/me/library/playlists": libraryPlaylists,
        "/v1/me/recent/radio-stations": recentStations,
        "/v1/catalog/us/charts": charts,
    ]
}

final class DiscoverSectionsTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - The feed

    /// Apple's rails first, then every section in its fixed order.
    func testRailsAreTheRecommendationsThenTheSectionsInOrder() throws {
        let rails = try SectionWebService().feed().rails()
        XCTAssertEqual(rails.map(\.title), ["Playlists Made for You", "Recently Added", "Recent Stations",
                                            "Top Songs", "Top Albums", "Top Playlists"])
        XCTAssertEqual(rails.map(\.section), [nil, .recentlyAdded, .recentStations,
                                              .topSongs, .topAlbums, .topPlaylists])
        XCTAssertEqual(Set(rails.map(\.id)).count, rails.count, "rail ids are distinct")
        XCTAssertTrue(rails.allSatisfy { !$0.isRecentlyPlayed })
    }

    /// Recently Added rows become CATALOGUE items through the catalog
    /// relationship, in the endpoint's order. No counterpart: dropped, never
    /// guessed. A counterpart that is only an identifier takes the library
    /// row's name and artwork under the catalogue id.
    func testRecentlyAddedResolvesToCatalogueItemsAndDropsTheUnresolvable() throws {
        let items = try SectionWebService().feed().recentlyAdded()
        XCTAssertEqual(items.map(\.id), ["1585000001", "1585000002", "pl.deephouse"])
        XCTAssertEqual(items.map(\.kind), [.album, .album, .playlist])
        XCTAssertEqual(items[0].detail, .album(trackCount: 1, year: 2021, genre: "Electronic"))
        XCTAssertEqual(items[1].name, "Bare Album")
        XCTAssertEqual(items[1].subtitle, "Bare Artist")
        XCTAssertEqual(items[1].artworkURL, "https://example.com/bare/{w}x{h}.jpg")
        XCTAssertEqual(items[2].subtitle, "Apple Music Dance")
        XCTAssertFalse(items.contains { $0.id.hasPrefix("l.") || $0.id.hasPrefix("p.") },
                       "no library id reaches a catalogue drill-in or play")
    }

    /// One batched request per library type, asking for the catalog
    /// relationship by the library ids.
    func testRecentlyAddedBatchesOneResolveRequestPerType() throws {
        let web = SectionWebService()
        _ = try web.feed().recentlyAdded()
        let albums = web.asked("/v1/me/library/albums")
        let playlists = web.asked("/v1/me/library/playlists")
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(playlists.count, 1)
        XCTAssertTrue(albums[0].contains("ids=l.NWqWi1m,l.bare"), albums[0])
        XCTAssertTrue(albums[0].contains("include=catalog"), albums[0])
        XCTAssertTrue(playlists[0].contains("ids=p.mine,p.apple"), playlists[0])
    }

    /// Nothing of a type to resolve spends no request for it.
    func testRecentlyAddedSpendsNoResolveRequestForAnAbsentType() throws {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/me/library/recently-added"] = """
        {"data":[{"id":"l.NWqWi1m","type":"library-albums","attributes":{"name":"Dopamine - Single"}}]}
        """
        let web = SectionWebService(bodies: bodies)
        XCTAssertEqual(try web.feed().recentlyAdded().map(\.id), ["1585000001"])
        XCTAssertEqual(web.asked("/v1/me/library/playlists"), [])
    }

    /// A failed resolve drops those rows (they cannot be opened), not the feed.
    func testAFailedResolveDropsOnlyThoseRows() throws {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/me/library/albums"] = .some(nil)
        let items = try SectionWebService(bodies: bodies).feed().recentlyAdded()
        XCTAssertEqual(items.map(\.id), ["pl.deephouse"])
    }

    func testRecentStationsAreCatalogueStationsWithTheirPlayURL() throws {
        let web = SectionWebService()
        let items = try web.feed().recentStations()
        XCTAssertEqual(items.map(\.name), ["Apple Music 1", "Anthony Maley’s Station"])
        XCTAssertEqual(items.map(\.kind), [.station, .station])
        XCTAssertEqual(items[0].url, "https://music.apple.com/us/station/apple-music-1/ra.978194965")
        XCTAssertEqual(items[0].detail, .station(isLive: true))
        XCTAssertTrue(web.asked("/v1/me/recent/radio-stations")[0].hasSuffix("?limit=10"))
    }

    /// One request for all three charts, in this storefront; the first chart
    /// of each type with anything in it is the one shown.
    func testChartsAreOneRequestAndTakeTheFirstNonEmptyChart() throws {
        let web = SectionWebService()
        let charts = try web.feed().charts()
        XCTAssertEqual(charts.songs.map(\.id), ["s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(charts.albums.map(\.id), ["a1"])
        XCTAssertEqual(charts.playlists.map(\.id), ["pl.t1"])
        let asked = web.asked("/charts")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].contains("/v1/catalog/us/charts?types=songs,albums,playlists&limit=20"), asked[0])
    }

    /// A row of the wrong kind inside a chart is not shown under it.
    func testAChartKeepsOnlyItsOwnKind() throws {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/catalog/us/charts"] = """
        {"results":{"songs":[{"data":[
          {"id":"a9","type":"albums","attributes":{"name":"Stray Album"}},
          {"id":"s9","type":"songs","attributes":{"name":"Real Song"}}]}]}}
        """
        let charts = try SectionWebService(bodies: bodies).feed().charts()
        XCTAssertEqual(charts.songs.map(\.id), ["s9"])
        XCTAssertEqual(charts.albums, [])
        XCTAssertEqual(charts.playlists, [])
    }

    /// A section whose read fails is absent; the rest of Discover is not.
    func testAFailedSectionReadDropsOnlyThatSection() throws {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/catalog/us/charts"] = .some(nil)
        bodies["/v1/me/recent/radio-stations"] = "not json"
        let rails = try SectionWebService(bodies: bodies).feed().rails()
        XCTAssertEqual(rails.map(\.title), ["Playlists Made for You", "Recently Added"])
    }

    /// An empty section is no heading at all.
    func testAnEmptySectionIsAbsent() throws {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/me/recent/radio-stations"] = #"{"data":[]}"#
        let rails = try SectionWebService(bodies: bodies).feed().rails()
        XCTAssertFalse(rails.contains { $0.section == .recentStations })
    }

    /// The recommendations read is still the feed: if it fails the whole read
    /// fails, and no section is asked for.
    func testAFailedRecommendationsReadFailsTheFeedAndAsksNoSection() {
        var bodies = SectionWebService.fullFeed
        bodies["/v1/me/recommendations"] = .some(nil)
        let web = SectionWebService(bodies: bodies)
        XCTAssertThrowsError(try web.feed().rails())
        XCTAssertEqual(web.urls.count, 1, "\(web.urls)")
    }

    // MARK: - Resolution

    private func rail(_ id: String, _ types: [String], items: Int = 2,
                      section: DiscoverSection? = nil) -> DiscoverRail {
        DiscoverRail(id: id, title: id,
                     items: (0..<items).map {
                         DiscoverItem(id: "\(id)-\($0)", name: "\(id) \($0)", subtitle: nil, url: nil,
                                      artworkURL: nil, detail: .playlist(description: nil))
                     },
                     isRecentlyPlayed: false, resourceTypes: types, section: section)
    }

    /// Sections follow the curated five in their own order, whatever order
    /// they arrived in, and never take a curated slot.
    func testSectionsFollowTheCuratedFiveInTheirOwnOrder() {
        let apple = (1...7).map { rail("apple\($0)", ["playlists"]) }
        let sections = [rail("charts", ["songs"], section: .topSongs),
                        rail("added", ["albums", "playlists"], section: .recentlyAdded),
                        rail("stations", ["stations"], section: .recentStations)]
        let resolved = resolvedDiscoverRails(sections + apple, currentYear: 2026)
        XCTAssertEqual(resolved.map(\.id), ["apple1", "apple2", "apple3", "apple4", "apple5",
                                            "added", "stations", "charts"])
    }

    /// A thin For You feed is NOT backfilled with sections: a "Top Albums"
    /// chart is not one of Apple's rails for him.
    func testAThinFeedIsNotBackfilledWithSections() {
        let resolved = resolvedDiscoverRails([rail("apple1", ["stations"]),
                                              rail("top", ["albums"], section: .topAlbums)],
                                             currentYear: 2026)
        XCTAssertEqual(resolved.map(\.id), ["apple1", "top"])
        XCTAssertEqual(resolvedDiscoverRails([rail("top", ["albums"], section: .topAlbums)],
                                             currentYear: 2026).map(\.id), ["top"])
    }

    /// One rail per section, even if a feed sent two.
    func testOneRailPerSection() {
        let resolved = resolvedDiscoverRails([rail("first", ["songs"], section: .topSongs),
                                              rail("second", ["songs"], section: .topSongs)],
                                             currentYear: 2026)
        XCTAssertEqual(resolved.map(\.id), ["first"])
    }

    /// A section shows four at the root, like every rail, with View all when
    /// there is more.
    func testASectionCapsAtFourWithViewAll() throws {
        let rails = try SectionWebService().feed().rails()
        let rows = discoverDisplayRows(rails: resolvedDiscoverRails(rails, currentYear: 2026), perRail: 4)
        guard let header = rows.firstIndex(of: .header("Top Songs")) else { return XCTFail("no Top Songs") }
        let after = Array(rows[(header + 1)...].prefix(5))
        XCTAssertEqual(after.prefix(4).map { row -> String in
            if case .item(let item) = row { return item.id }; return "?"
        }, ["s1", "s2", "s3", "s4"])
        guard case .viewAll(let all) = after[4] else { return XCTFail("no View all: \(after)") }
        XCTAssertEqual(all.items.count, 5)
    }

    // MARK: - The scene, on both data sources

    private func lifecycle() -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, _ in throw Stop.stop }, readCount: { _ in 0 },
            play: { _ in }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private func scene(_ rig: SceneDataRig, web: SectionWebService) -> DiscoverScene {
        let status = StatusStore()
        return DiscoverScene(feed: web.feed(), status: status, actions: ActionRunner(status: status),
                             api: nil, lifecycle: lifecycle(), routing: rig.coordinator(),
                             opener: SceneRecordingOpener())
    }

    private func loadRails(_ s: DiscoverScene) {
        let deadline = Date().addingTimeInterval(5)
        while s.rails.isEmpty && s.loadFailure == nil && Date() < deadline {
            _ = s.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    /// MusicTUI's own data: the sections render after Apple's rails.
    func testWebServiceDataShowsTheSections() {
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let web = SectionWebService()
        let s = scene(rig, web: web)
        loadRails(s)

        XCTAssertEqual(s.rails.compactMap(\.section), DiscoverSection.allCases)
        let out = s.render(frame: shellLayout(width: 120, height: 80), snapshot: idle)
        for title in ["Recently Added", "Recent Stations", "Top Songs", "Top Albums", "Top Playlists"] {
            XCTAssertTrue(out.contains(title), "\(title) missing")
        }
        XCTAssertTrue(rig.sent.isEmpty, "open data asks SpanDAC nothing")
    }

    /// SpanDAC data, every output: SpanDAC's rails only. Not one web-service
    /// request (no fallback on either axis), and so no section.
    func testSpanDACDataShowsNoSectionAndNeverAsksTheWebService() {
        for output in [PlaybackMode.musicApp, .source, .networkSource(SceneDataRig.ipad)] {
            let rig = SceneDataRig(output: output, accepted: true)
            let web = SectionWebService()
            let s = scene(rig, web: web)
            loadRails(s)

            XCTAssertEqual(s.rails.map(\.title), ["Stations For You"], "\(output)")
            XCTAssertTrue(s.rails.allSatisfy { $0.section == nil }, "\(output)")
            XCTAssertEqual(web.urls, [], "SpanDAC data reached the web service (\(output))")
            let out = s.render(frame: shellLayout(width: 120, height: 80), snapshot: idle)
            XCTAssertFalse(out.contains("Top Songs"), "\(output)")
            XCTAssertFalse(out.contains("Recently Added"), "\(output)")
        }
    }
}
