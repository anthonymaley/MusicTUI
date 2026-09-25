import XCTest
@testable import music

/// The finished-plays feed at the transport seam: request shaping, the golden
/// reply, every contract check that refuses a page, the error kinds, and a
/// multi-page walk. Canned through the real `SourceAppControl(path:transport:)`,
/// so these exercise the framing and refusal decoding the app actually uses.
/// No socket is opened.
final class CompletedPlaysFeedTests: XCTestCase {

    /// A scripted Bridge: records every request line and answers in order.
    private final class Wire {
        private(set) var sent: [String] = []
        private var replies: [String]
        init(_ replies: [String]) { self.replies = replies }

        func transport(_ path: String, _ line: String) throws -> String {
            sent.append(line)
            return replies.isEmpty ? "{}" : replies.removeFirst()
        }
        func request(_ index: Int) -> [String: Any] {
            guard index < sent.count, let data = sent[index].data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return body
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.transport)
    }

    /// Section 2's golden reply, verbatim.
    private let golden = """
    {"ok":true,"op":"slice.completedPlays",
     "ledger_id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301",
     "latest_seq":3,"next_after":2,"more":true,
     "plays":[
      {"seq":1,"play_id":"7D444840-9DC0-11D1-B245-5FFDCE74FAD2","alias":"596357614188841472",
       "library_id":"i.LVbELSWJ1GmE","title":"Are You Awake? - Kevin Shields",
       "artist":"Lost In Translation OST","completed_at":"2026-09-25T01:36:27.496Z",
       "end":"advance","duration_s":95.268,"position_s":94.274},
      {"seq":2,"play_id":"B3A4F0D2-1C55-4E0B-9F57-0A1C2E3D4F50","alias":null,
       "library_id":"i.qlWqltep4qY5","title":"Spontaneous (feat. Little Dragon)",
       "artist":"Flying Lotus","completed_at":"2026-09-25T01:50:02.100Z",
       "end":"exhausted","duration_s":128.647,"position_s":128.101}
     ]}
    """

    /// One play record as Bridge writes it, every key present.
    private func play(_ seq: Int, alias: String = "\"15\"",
                      completedAt: String = "2026-09-25T01:36:27.496Z") -> String {
        """
        {"seq":\(seq),"play_id":"P-\(seq)","alias":\(alias),"library_id":"i.\(seq)",
         "title":"T\(seq)","artist":"A","completed_at":"\(completedAt)",
         "end":"advance","duration_s":100.0,"position_s":99.0}
        """
    }

    private func page(ledger: String = "L1", latest: Int, nextAfter: Int, more: Bool,
                      plays: [String]) -> String {
        """
        {"ok":true,"op":"slice.completedPlays","ledger_id":"\(ledger)",
         "latest_seq":\(latest),"next_after":\(nextAfter),"more":\(more),
         "plays":[\(plays.joined(separator: ","))]}
        """
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int,
                     millis: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let whole = calendar.date(from: DateComponents(year: y, month: mo, day: d,
                                                       hour: h, minute: mi, second: s))!
        return whole.addingTimeInterval(Double(millis) / 1000)
    }

    private func assertMalformed(_ reply: String, after: Int = 0, ledgerID: String? = nil,
                                 limit: Int = 200,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let wire = Wire([reply])
        XCTAssertThrowsError(try control(wire).completedPlays(ledgerID: ledgerID, after: after,
                                                              limit: limit),
                             file: file, line: line) { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Request shaping

    func testAFirstRequestSendsAnExplicitNullLedgerID() throws {
        let wire = Wire([page(latest: 0, nextAfter: 0, more: false, plays: [])])
        _ = try control(wire).completedPlays(ledgerID: nil, after: 0, limit: 200)
        let body = wire.request(0)
        XCTAssertEqual(body["op"] as? String, "slice.completedPlays")
        XCTAssertTrue(body["ledger_id"] is NSNull, "a missing cursor is sent as JSON null, not omitted")
        XCTAssertEqual(body["after"] as? Int, 0)
        XCTAssertEqual(body["limit"] as? Int, 200)
        XCTAssertEqual(Set(body.keys), ["op", "ledger_id", "after", "limit"])
    }

    func testAKnownLedgerIDIsSentAsItsString() throws {
        let wire = Wire([page(ledger: "L1", latest: 7, nextAfter: 7, more: false, plays: [])])
        _ = try control(wire).completedPlays(ledgerID: "L1", after: 7, limit: 50)
        let body = wire.request(0)
        XCTAssertEqual(body["ledger_id"] as? String, "L1")
        XCTAssertEqual(body["after"] as? Int, 7)
        XCTAssertEqual(body["limit"] as? Int, 50)
    }

    // MARK: - The golden reply

    func testTheGoldenReplyDecodesToThePage() throws {
        let wire = Wire([golden])
        let result = try control(wire).completedPlays(ledgerID: nil, after: 0, limit: 200)
        XCTAssertEqual(result.ledgerID, "3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        XCTAssertEqual(result.latestSeq, 3)
        XCTAssertEqual(result.nextAfter, 2)
        XCTAssertTrue(result.more)
        XCTAssertEqual(result.plays.count, 2)

        let first = result.plays[0]
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(first.playID, "7D444840-9DC0-11D1-B245-5FFDCE74FAD2")
        XCTAssertEqual(first.alias, "596357614188841472")
        XCTAssertEqual(first.libraryID, "i.LVbELSWJ1GmE")
        XCTAssertEqual(first.title, "Are You Awake? - Kevin Shields")
        XCTAssertEqual(first.artist, "Lost In Translation OST")
        XCTAssertEqual(first.end, "advance")
        XCTAssertEqual(first.completedAt.timeIntervalSince1970,
                       utc(2026, 9, 25, 1, 36, 27, millis: 496).timeIntervalSince1970,
                       accuracy: 0.0005)

        let second = result.plays[1]
        XCTAssertEqual(second.seq, 2)
        XCTAssertNil(second.alias, "an explicit null alias becomes nil")
        XCTAssertEqual(second.libraryID, "i.qlWqltep4qY5")
        XCTAssertEqual(second.title, "Spontaneous (feat. Little Dragon)")
        XCTAssertEqual(second.artist, "Flying Lotus")
        XCTAssertEqual(second.end, "exhausted")
        XCTAssertEqual(second.completedAt.timeIntervalSince1970,
                       utc(2026, 9, 25, 1, 50, 2, millis: 100).timeIntervalSince1970,
                       accuracy: 0.0005)
    }

    func testAnEmptyPageAtTheEndIsNotMalformed() throws {
        let wire = Wire([page(latest: 3, nextAfter: 3, more: false, plays: [])])
        let result = try control(wire).completedPlays(ledgerID: "L1", after: 3, limit: 200)
        XCTAssertEqual(result, CompletedPlaysPage(ledgerID: "L1", latestSeq: 3, nextAfter: 3,
                                                  more: false, plays: []))
    }

    // MARK: - Malformed replies

    func testAMissingPlaysIsMalformed() {
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","latest_seq":0,"next_after":0,"more":false}
        """)
    }

    func testAMissingLedgerIDIsMalformed() {
        assertMalformed("""
        {"ok":true,"latest_seq":0,"next_after":0,"more":false,"plays":[]}
        """)
    }

    func testAMissingLatestSeqNextAfterOrMoreIsMalformed() {
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","next_after":0,"more":false,"plays":[]}
        """)
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","latest_seq":0,"more":false,"plays":[]}
        """)
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","latest_seq":0,"next_after":0,"plays":[]}
        """)
    }

    func testAPlayMissingItsAliasKeyIsMalformed() {
        let noAlias = """
        {"seq":1,"play_id":"P-1","library_id":"i.1","title":"T1","artist":"A",
         "completed_at":"2026-09-25T01:36:27.496Z","end":"advance","duration_s":1.0,"position_s":1.0}
        """
        assertMalformed(page(latest: 1, nextAfter: 1, more: false, plays: [noAlias]))
    }

    func testAPlayWithANonTextAliasIsMalformed() {
        assertMalformed(page(latest: 1, nextAfter: 1, more: false, plays: [play(1, alias: "15")]))
    }

    func testAPlayMissingARequiredFieldIsMalformed() {
        for key in ["seq", "play_id", "library_id", "title", "artist", "completed_at", "end"] {
            var fields: [String: Any] = [
                "seq": 1, "play_id": "P-1", "alias": NSNull(), "library_id": "i.1",
                "title": "T1", "artist": "A", "completed_at": "2026-09-25T01:36:27.496Z",
                "end": "advance", "duration_s": 1.0, "position_s": 1.0,
            ]
            fields.removeValue(forKey: key)
            let data = try! JSONSerialization.data(withJSONObject: fields)
            let record = String(data: data, encoding: .utf8)!
            assertMalformed(page(latest: 1, nextAfter: 1, more: false, plays: [record]))
        }
    }

    func testASeqAtOrBelowAfterIsMalformed() {
        // Asked after 5; a play at 5 was already consumed.
        assertMalformed(page(latest: 6, nextAfter: 6, more: false, plays: [play(5), play(6)]),
                        after: 5, ledgerID: "L1")
        assertMalformed(page(latest: 5, nextAfter: 5, more: false, plays: [play(5)]),
                        after: 5, ledgerID: "L1")
    }

    func testANonContiguousSeqIsMalformed() {
        // A gap.
        assertMalformed(page(latest: 3, nextAfter: 3, more: false, plays: [play(1), play(3)]))
        // A repeat.
        assertMalformed(page(latest: 2, nextAfter: 2, more: false, plays: [play(1), play(1), play(2)]))
        // Not starting right after the cursor.
        assertMalformed(page(latest: 3, nextAfter: 3, more: false, plays: [play(2), play(3)]))
    }

    func testNextAfterThatIsNotTheLastSeqIsMalformed() {
        assertMalformed(page(latest: 5, nextAfter: 3, more: true, plays: [play(1), play(2)]))
        // An empty page must leave the cursor where it was.
        assertMalformed(page(latest: 4, nextAfter: 4, more: false, plays: []), after: 3, ledgerID: "L1")
    }

    func testAnInconsistentMoreIsMalformed() {
        // More claimed with nothing left.
        assertMalformed(page(latest: 2, nextAfter: 2, more: true, plays: [play(1), play(2)]))
        // No more claimed with plays left.
        assertMalformed(page(latest: 5, nextAfter: 2, more: false, plays: [play(1), play(2)]))
        // An empty page while more is true.
        assertMalformed(page(latest: 5, nextAfter: 2, more: true, plays: []), after: 2, ledgerID: "L1")
    }

    func testALatestSeqBelowNextAfterIsMalformed() {
        assertMalformed(page(latest: 1, nextAfter: 2, more: false, plays: [play(1), play(2)]))
    }

    func testMorePlaysThanTheLimitIsMalformed() {
        assertMalformed(page(latest: 3, nextAfter: 3, more: false, plays: [play(1), play(2), play(3)]),
                        limit: 2)
    }

    func testAReplyForADifferentLedgerThanTheCursorIsMalformed() {
        assertMalformed(page(ledger: "L2", latest: 1, nextAfter: 1, more: false, plays: [play(1)]),
                        ledgerID: "L1")
    }

    func testAnUnparseableCompletedAtIsMalformed() {
        for stamp in ["yesterday", "2026-09-25 01:36:27", "", "2026-13-45T99:00:00.000Z"] {
            assertMalformed(page(latest: 1, nextAfter: 1, more: false,
                                 plays: [play(1, completedAt: stamp)]))
        }
    }

    func testBooleansAreNotReadAsCountsAndCountsAreNotReadAsBooleans() {
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","latest_seq":true,"next_after":0,"more":false,"plays":[]}
        """)
        assertMalformed("""
        {"ok":true,"ledger_id":"L1","latest_seq":0,"next_after":0,"more":0,"plays":[]}
        """)
    }

    // MARK: - Error kinds

    private func refusal(_ kind: String, _ detail: String) -> String {
        """
        {"ok":false,"op":"slice.completedPlays","error":{"kind":"\(kind)","detail":"\(detail)"}}
        """
    }

    func testLedgerChangedIsItsOwnCase() {
        let detail = "Bridge's play record was replaced; read it again from the start."
        let wire = Wire([refusal("ledger_changed", detail)])
        XCTAssertThrowsError(try control(wire).completedPlays(ledgerID: "OLD", after: 9, limit: 200)) {
            XCTAssertEqual($0 as? SourceAppError, .ledgerChanged(detail))
        }
    }

    func testAnOlderBridgeIsUnsupported() {
        let wire = Wire([refusal("unknown_op", "no such op")])
        XCTAssertThrowsError(try control(wire).completedPlays(ledgerID: nil, after: 0, limit: 200)) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported("slice.completedPlays"))
        }
    }

    func testLedgerUnavailableIsARefusalCarryingItsDetail() {
        let detail = "Bridge could not open its play record: disk full"
        let wire = Wire([refusal("ledger_unavailable", detail)])
        XCTAssertThrowsError(try control(wire).completedPlays(ledgerID: nil, after: 0, limit: 200)) {
            XCTAssertEqual($0 as? SourceAppError, .refused(detail))
        }
    }

    // MARK: - Transports

    func testTransportFailuresPassThrough() {
        for failure in [SourceAppError.notRunning, .timedOut] {
            let control = SourceAppControl(path: "/nonexistent",
                                           transport: { _, _ in throw failure })
            XCTAssertThrowsError(try control.completedPlays(ledgerID: nil, after: 0, limit: 200)) {
                XCTAssertEqual($0 as? SourceAppError, failure)
            }
        }
    }

    func testAThreePageWalkAsksFromEachPagesNextAfter() throws {
        let latest = 450
        func pageOf(_ range: ClosedRange<Int>) -> String {
            page(latest: latest, nextAfter: range.upperBound, more: range.upperBound < latest,
                 plays: range.map { play($0) })
        }
        let wire = Wire([pageOf(1...200), pageOf(201...400), pageOf(401...450)])
        let feed: CompletedPlaysReading = control(wire)

        var ledger: String? = nil
        var after = 0
        var seen: [Int] = []
        while true {
            let result = try feed.completedPlays(ledgerID: ledger, after: after, limit: 200)
            seen += result.plays.map(\.seq)
            ledger = result.ledgerID
            after = result.nextAfter
            if !result.more { break }
        }

        XCTAssertEqual(wire.sent.count, 3)
        XCTAssertEqual((0..<3).map { wire.request($0)["after"] as? Int }, [0, 200, 400])
        XCTAssertTrue(wire.request(0)["ledger_id"] is NSNull)
        XCTAssertEqual(wire.request(1)["ledger_id"] as? String, "L1")
        XCTAssertEqual(wire.request(2)["ledger_id"] as? String, "L1")
        XCTAssertEqual(seen, Array(1...450))
        XCTAssertEqual(after, 450)
    }
}
