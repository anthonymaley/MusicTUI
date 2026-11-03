// tools/music/Tests/MusicTests/DiscoverFeedFetchTests.swift
//
// The Discover feed's real fetch had the timeout race Codex found in the
// station page fetcher (radio-art review r1, finding 3) and again here
// (2026-11-03 review of the catalogue fix): a timed-out request was left
// running and its late callback could write into a fetch that had already
// returned. Fake transports only: no real network, keychain or ~/.config/music.
import XCTest
@testable import music

final class DiscoverFeedFetchTests: XCTestCase {
    private let url = URL(string: "https://api.music.apple.com/v1/me/recommendations")!

    private func answer(status: Int) -> (Data?, URLResponse?) {
        (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    func testAnAnswerBeforeTheTimeoutIsReturnedWithBothTokensAndNotCancelled() {
        let transport = FakePageTransport()
        let fetch = makeDiscoverFeedFetch(transport: transport.start(answerAfter: 0, with: answer(status: 200)),
                                          timeout: 2, developerToken: { "dev" }, userToken: { "user" })
        XCTAssertEqual(fetch(url.absoluteString).map { String(decoding: $0, as: UTF8.self) }, "{}")
        XCTAssertEqual(transport.cancels, 0)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer dev")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Music-User-Token"), "user")
    }

    /// The feed reads the body whatever the status, as it always has.
    func testANonOKAnswerStillReturnsItsBody() {
        let transport = FakePageTransport()
        let fetch = makeDiscoverFeedFetch(transport: transport.start(answerAfter: 0, with: answer(status: 401)),
                                          timeout: 2, developerToken: { "dev" }, userToken: { "user" })
        XCTAssertEqual(fetch(url.absoluteString).map { String(decoding: $0, as: UTF8.self) }, "{}")
    }

    func testAMissingTokenSendsNothing() {
        let transport = FakePageTransport()
        let fetch = makeDiscoverFeedFetch(transport: transport.start(answerAfter: 0, with: answer(status: 200)),
                                          timeout: 2, developerToken: { "dev" }, userToken: { nil })
        XCTAssertNil(fetch(url.absoluteString))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// No answer within the timeout: nil, the request is cancelled rather than
    /// left running, and a callback arriving after that is dropped.
    func testATimeoutCancelsTheRequestAndDropsALateCallback() {
        let transport = FakePageTransport()
        let dropped = DispatchSemaphore(value: 0)
        let fetch = makeDiscoverFeedFetch(transport: transport.start(answerAfter: nil, with: answer(status: 200)),
                                          timeout: 0.05, onLateCallback: { dropped.signal() },
                                          developerToken: { "dev" }, userToken: { "user" })
        let started = Date()
        XCTAssertNil(fetch(url.absoluteString))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "waited well past the timeout")
        XCTAssertEqual(transport.cancels, 1, "a timed-out request was left running")

        XCTAssertTrue(transport.fireLate())
        XCTAssertEqual(dropped.wait(timeout: .now() + 1), .success, "a late callback was not dropped")
    }
}
