// tools/music/Tests/MusicTests/RadioCatalogFetchTests.swift
//
// The catalogue's real fetch had the timeout race Codex found in the station
// page fetcher (radio-art review r1, finding 3): a timed-out request was left
// running and its late callback could write into a fetch that had already
// returned. Fake transports only: no real network, keychain or ~/.config/music.
import XCTest
@testable import music

final class RadioCatalogFetchTests: XCTestCase {
    private let url = URL(string: "https://api.music.apple.com/v1/catalog/us/stations?ids=ra.1")!

    private func ok() -> (Data?, URLResponse?) {
        (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    func testAnAnswerBeforeTheTimeoutIsReturnedWithBothTokensAndNotCancelled() {
        let transport = FakePageTransport()
        let fetch = makeRadioCatalogFetch(transport: transport.start(answerAfter: 0, with: ok()), timeout: 2,
                                          developerToken: { "dev" }, userToken: { "user" })
        let response = fetch(url.absoluteString)
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(transport.cancels, 0)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer dev")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Music-User-Token"), "user")
    }

    func testNoDeveloperTokenSendsNothing() {
        let transport = FakePageTransport()
        let fetch = makeRadioCatalogFetch(transport: transport.start(answerAfter: 0, with: ok()), timeout: 2,
                                          developerToken: { nil }, userToken: { nil })
        XCTAssertNil(fetch(url.absoluteString))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// No answer within the timeout: nil, the request is cancelled rather than
    /// left running, and a callback arriving after that is dropped.
    func testATimeoutCancelsTheRequestAndDropsALateCallback() {
        let transport = FakePageTransport()
        let dropped = DispatchSemaphore(value: 0)
        let fetch = makeRadioCatalogFetch(transport: transport.start(answerAfter: nil, with: ok()), timeout: 0.05,
                                          onLateCallback: { dropped.signal() },
                                          developerToken: { "dev" }, userToken: { nil })
        let started = Date()
        XCTAssertNil(fetch(url.absoluteString))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "waited well past the timeout")
        XCTAssertEqual(transport.cancels, 1, "a timed-out request was left running")

        XCTAssertTrue(transport.fireLate())
        XCTAssertEqual(dropped.wait(timeout: .now() + 1), .success, "a late callback was not dropped")
    }
}
