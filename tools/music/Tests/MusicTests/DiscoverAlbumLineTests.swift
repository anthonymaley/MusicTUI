import XCTest
@testable import music

/// A song played from a Discover playlist or rail carries its own album, so
/// Now's album line is drawn for it as it is for search and album plays
/// (follow-up to Codex c671ec0a, 2026-11-06).
final class DiscoverAlbumLineTests: XCTestCase {

    // MusicTUI data: Apple's track reply carries `albumName` on each song.
    func testAppleTrackRowsKeepTheirAlbum() throws {
        let body = """
        {"data":[{"relationships":{"tracks":{"data":[
          {"id":"1","type":"songs","attributes":{"name":"Andromeda","artistName":"Gorillaz","albumName":"Humanz (Deluxe)"}},
          {"id":"2","type":"songs","attributes":{"name":"No Album","artistName":"X"}}
        ]}}}]}
        """
        let feed = DiscoverFeed(storefront: "us", token: { "t" }, fetch: { _ in Data(body.utf8) })
        let playlist = DiscoverItem(id: "pl.1", name: "P", subtitle: nil, url: nil, artworkURL: nil,
                                    detail: .playlist(description: nil))
        let tracks = try feed.tracks(for: playlist)
        XCTAssertEqual(tracks.map(\.album), ["Humanz (Deluxe)", nil])
    }

    // SpanDAC data: a song wire row may carry an optional `album`.
    func testSpanDACSongRowsKeepTheirAlbum() throws {
        let rows: [[String: Any]] = [
            ["kind": "song", "id": "1", "name": "Andromeda", "subtitle": "Gorillaz", "album": "Humanz (Deluxe)"],
            ["kind": "song", "id": "2", "name": "Older SpanDAC", "subtitle": "X"],
            ["kind": "album", "id": "3", "name": "Aja", "subtitle": "Steely Dan", "album": "ignored"],
        ]
        let items = try BridgeDiscoverFeed.items(rows)
        XCTAssertEqual(items.map(\.album), ["Humanz (Deluxe)", nil, nil])
    }

    // Now's rows: a song's own album wins; the container's album fills the rest.
    func testNowRowsUseTheSongsOwnAlbumFirst() {
        var withAlbum = DiscoverItem(id: "1", name: "Andromeda", subtitle: "Gorillaz", url: nil,
                                     artworkURL: nil, detail: .song)
        withAlbum.album = "Humanz (Deluxe)"
        let without = DiscoverItem(id: "2", name: "S", subtitle: "A", url: nil, artworkURL: nil, detail: .song)
        XCTAssertEqual(DiscoverScene.nowRows([withAlbum, without], album: nil).map(\.album),
                       ["Humanz (Deluxe)", nil])
        XCTAssertEqual(DiscoverScene.nowRows([without], album: "An Album").map(\.album), ["An Album"])
    }
}
