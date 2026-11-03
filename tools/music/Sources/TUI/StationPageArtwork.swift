// Station artwork from the station's public web page — the fallback for
// favourites the catalog API cannot resolve (BBC Radio 1/2/…, VRT Studio
// Brussel: `/v1/catalog/{us,gb}/stations/<id>` answers 404 for them, so
// `RadioCatalog.resolve` never fills `artworkURL`).
//
// RED STUB: the shapes the tests drive, with no behaviour yet.
import Foundation

/// One page fetch: nil is a transport failure, otherwise the status and body.
typealias StationPageFetch = (URL) -> RadioCatalogResponse?

enum StationPageArtwork {
    static func pageURLs(for station: Station) -> [URL] { [] }

    static func template(inPage html: Data, stationID: String) -> String? { nil }

    static func lookup(_ station: Station, fetch: StationPageFetch) -> String? { nil }
}

final class StationArtworkBackfill {
    private let store: StationStore
    private let fetch: StationPageFetch

    init(store: StationStore, fetch: @escaping StationPageFetch) {
        self.store = store
        self.fetch = fetch
    }

    @discardableResult
    func fillMissing() -> [String] { [] }

    @discardableResult
    func fill(id: String) -> Bool { false }
}
