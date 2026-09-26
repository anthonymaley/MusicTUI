import XCTest
@testable import music

final class RadioCatalogTests: XCTestCase {
    /// Verbatim shape from the live probe (2026-07-15).
    private let stationsJSON = """
    {"data":[
      {"id":"ra.978194965","attributes":{
        "name":"Apple Music 1","isLive":true,
        "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965",
        "artwork":{"url":"https://example.com/{w}x{h}.jpg"}}},
      {"id":"ra.1498155548","attributes":{
        "name":"Apple Music Hits","isLive":true,
        "url":"https://music.apple.com/us/station/apple-music-hits/ra.1498155548",
        "artwork":{"url":"https://example.com/b/{w}x{h}.jpg"}}}
    ]}
    """

    private let searchJSON = """
    {"results":{"stations":{"data":[
      {"id":"ra.985484943","attributes":{
        "name":"Chill Station","isLive":false,
        "url":"https://music.apple.com/us/station/chill-station/ra.985484943",
        "artwork":{"url":"https://example.com/c/{w}x{h}.jpg"}}}
    ]}}}
    """

    private func catalog(_ body: String, status: Int = 200, capture: ((String) -> Void)? = nil,
                         hasUserToken: @escaping () -> Bool = { false }) -> RadioCatalog {
        RadioCatalog(storefront: "us", token: { "tok" }, fetch: { url in
            capture?(url)
            return RadioCatalogResponse(status: status, data: Data(body.utf8))
        }, hasUserToken: hasUserToken)
    }

    func testDecodesLiveLineup() throws {
        let out = try catalog(stationsJSON).liveStations()
        XCTAssertEqual(out.map(\.id), ["ra.978194965", "ra.1498155548"])
        XCTAssertEqual(out.first?.name, "Apple Music 1")
        XCTAssertEqual(out.first?.isLive, true)
        XCTAssertEqual(out.first?.url, "https://music.apple.com/us/station/apple-music-1/ra.978194965")
        XCTAssertEqual(out.first?.artworkURL, "https://example.com/{w}x{h}.jpg")
    }

    func testLiveLineupHitsTheFeaturedFilter() throws {
        var seen = ""
        _ = try catalog(stationsJSON, capture: { seen = $0 }).liveStations()
        XCTAssertTrue(seen.contains("/v1/catalog/us/stations"))
        XCTAssertTrue(seen.contains("filter%5Bfeatured%5D=apple-music-live-radio")
                      || seen.contains("filter[featured]=apple-music-live-radio"))
    }

    func testPersonalHitsTheIdentityFilter() throws {
        var seen = ""
        _ = try catalog(stationsJSON, capture: { seen = $0 }).personalStation()
        XCTAssertTrue(seen.contains("filter%5Bidentity%5D=personal")
                      || seen.contains("filter[identity]=personal"))
    }

    func testDecodesSearchResults() throws {
        let out = try catalog(searchJSON).search(term: "chill")
        XCTAssertEqual(out.map(\.id), ["ra.985484943"])
        XCTAssertEqual(out.first?.isLive, false)
    }

    func testSearchEncodesTheTerm() throws {
        var seen = ""
        _ = try catalog(searchJSON, capture: { seen = $0 }).search(term: "hip hop")
        XCTAssertTrue(seen.contains("hip%20hop") || seen.contains("hip+hop"))
        XCTAssertTrue(seen.contains("types=stations"))
    }

    /// BBC Radio 1: 200 with an empty data array. NOT an error.
    func testResolveReturnsNilOnEmptyData() throws {
        let c = catalog(#"{"data":[]}"#)
        XCTAssertNil(try c.resolve(id: "ra.1460912634"))
    }

    func testResolveReturnsStation() throws {
        XCTAssertEqual(try catalog(stationsJSON).resolve(id: "ra.978194965")?.name, "Apple Music 1")
    }

    func testFetchFailureThrows() {
        let c = RadioCatalog(storefront: "us", token: { "tok" }, fetch: { _ in nil })
        XCTAssertThrowsError(try c.liveStations())
    }

    func testMissingTokenThrows() {
        let c = RadioCatalog(storefront: "us", token: { nil }, fetch: { _ in RadioCatalogResponse(status: 200, data: Data()) })
        XCTAssertThrowsError(try c.liveStations())
    }

    // MARK: - HTTP status (personal-radio defect: a 403 used to decode as an
    // empty station list because `get` never looked at the status).

    /// The 2026-09-25 gate's live finding: a developer-token-only Personal
    /// read gets 403, and that must throw rather than decode as `[]`.
    func testNon2xxStatusThrowsTypedError() {
        let c = catalog(#"{"errors":[{"title":"Forbidden"}]}"#, status: 403)
        XCTAssertThrowsError(try c.personalStation()) { error in
            guard case RadioCatalogError.httpStatus(let status, let title) = error else {
                return XCTFail("expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(title, "Forbidden")
        }
    }

    func testNon2xxStatusWithNoAppleBodyStillThrows() {
        let c = catalog("not json", status: 500)
        XCTAssertThrowsError(try c.liveStations()) { error in
            guard case RadioCatalogError.httpStatus(let status, let title) = error else {
                return XCTFail("expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertNil(title)
        }
    }

    func test2xxStatusStillDecodesNormally() throws {
        let out = try catalog(stationsJSON, status: 200).liveStations()
        XCTAssertEqual(out.count, 2)
    }

    // MARK: - Music-User-Token header (personal-radio defect)
    //
    // `radioCatalogRequest` is the pure function `makeCatalog()`'s fetch
    // builds the live request from — testing it directly, rather than
    // through `makeCatalog()` itself, keeps this off the real AuthManager
    // and ~/.config/music.

    func testRequestCarriesUserTokenHeaderWhenPresent() {
        let req = radioCatalogRequest(url: URL(string: "https://api.music.apple.com/v1/catalog/us/stations")!,
                                      developerToken: "dev", userToken: "user123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer dev")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Music-User-Token"), "user123")
    }

    func testRequestOmitsUserTokenHeaderWhenAbsent() {
        let req = radioCatalogRequest(url: URL(string: "https://api.music.apple.com/v1/catalog/us/stations")!,
                                      developerToken: "dev", userToken: nil)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer dev")
        XCTAssertNil(req.value(forHTTPHeaderField: "Music-User-Token"))
    }

    /// `hasUserToken` is the seam `RadioScene`'s failure message reads to
    /// tell "no token" from "token present but rejected".
    func testHasUserTokenReflectsInjectedValue() {
        XCTAssertTrue(RadioCatalog(storefront: "us", token: { "tok" }, fetch: { _ in nil }, hasUserToken: { true }).hasUserToken())
        XCTAssertFalse(RadioCatalog(storefront: "us", token: { "tok" }, fetch: { _ in nil }).hasUserToken())
    }
}
