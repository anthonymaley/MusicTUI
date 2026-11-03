// tools/music/Sources/TUI/CatalogueSearch.swift
//
// STUB for the red commit: the API surface the tests compile against, with
// inert bodies. The implementation commit replaces every body.
import Foundation

enum CatalogueSearchIntent: Equatable {
    case search(String)
    case openArtist(CatalogueHit)
    case openAlbum(CatalogueHit)
    case playAlbum(CatalogueHit)
    case playSong(CatalogueHit)
    case close
}

struct CatalogueSearchEmission: Equatable {
    let intent: CatalogueSearchIntent
    let requestID: Int
}

struct CatalogueSearchOutcome: Equatable {
    var changed = false
    var emission: CatalogueSearchEmission?
}

struct CatalogueSearchModel {
    enum Row: Equatable {
        case header(String)
        case hit(CatalogueHit)
    }

    private(set) var text = ""
    private(set) var isEditing = true
    private(set) var lastTerm = ""
    private(set) var results: CatalogueSearchResults?
    private(set) var failure: String?
    private(set) var artist: CatalogueHit?
    private(set) var artistAlbums: ArtistAlbums?
    var rows: [Row] { [] }
    var cursor: Int { 0 }
    var selectedHit: CatalogueHit? { nil }
    var note: String? { nil }

    mutating func handle(_ key: KeyPress) -> CatalogueSearchOutcome { CatalogueSearchOutcome() }
    @discardableResult
    mutating func receive(results: CatalogueSearchResults, requestID: Int) -> Bool { false }
    @discardableResult
    mutating func receive(albums: ArtistAlbums, requestID: Int) -> Bool { false }
    @discardableResult
    mutating func receive(failure message: String, requestID: Int) -> Bool { false }
}
