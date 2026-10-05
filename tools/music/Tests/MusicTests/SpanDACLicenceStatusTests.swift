import XCTest
@testable import music

/// SpanDAC's licence as the public client reads it: the `licence` object on
/// `slice.status`, the `unlicensed` refusal, the readiness line, and the cache
/// that learns serving from replies already passing by. Fixture lines only: no
/// socket, no network, no files.
final class SpanDACLicenceStatusTests: XCTestCase {

    // MARK: fixtures

    private func statusLine(licence: String? = nil, authorization: String = "authorized",
                            contract: Int = 3, playback: String = "idle",
                            queue: String? = nil) -> String {
        var body = #""playback":"\#(playback)","contract":\#(contract),"authorization":"\#(authorization)""#
        if let licence { body += #","licence":\#(licence)"# }
        if let queue { body += #","queue":\#(queue)"# }
        return #"{"ok":true,"op":"slice.status","status":{\#(body)}}"#
    }

    private let notServing =
        #"{"serving":false,"state":"none","text":"No licence - enter your key in SpanDAC"}"#
    private let unlicensedError =
        #"{"ok":false,"op":"slice.search","error":{"kind":"unlicensed","detail":"No licence - enter your key in SpanDAC"}}"#

    private func control(_ line: String) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: { _, _ in line })
    }

    private func status(of line: String) throws -> SourceStatus {
        try control(line).status()
    }

    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: test 14: spanDACServing

    func testServingIsTrueWhenLicenceIsAbsentOrNull() {
        XCTAssertTrue(spanDACServing(object(#"{"playback":"idle"}"#)))
        XCTAssertTrue(spanDACServing(object(#"{"playback":"idle","licence":null}"#)))
    }

    func testServingFollowsTheBoolWhenPresent() {
        XCTAssertTrue(spanDACServing(object(#"{"licence":{"serving":true,"state":"licensed","text":"ok"}}"#)))
        XCTAssertFalse(spanDACServing(object(#"{"licence":\#(notServing)}"#)))
    }

    func testServingFailsClosedWhenLicenceIsPresentAndMalformed() {
        for bad in [#"{"licence":"yes"}"#, #"{"licence":true}"#, #"{"licence":[]}"#,
                    #"{"licence":{}}"#, #"{"licence":{"state":"licensed"}}"#,
                    #"{"licence":{"serving":"true"}}"#, #"{"licence":{"serving":1}}"#,
                    #"{"licence":{"serving":null}}"#] {
            XCTAssertFalse(spanDACServing(object(bad)), bad)
        }
    }

    func testStatusDecodesTheLicenceObject() throws {
        let s = try status(of: statusLine(licence: notServing))
        XCTAssertEqual(s.licence, SpanDACLicenceInfo(serving: false, state: "none",
                                                     text: "No licence - enter your key in SpanDAC"))
    }

    func testAMalformedLicenceDecodesAsNotServingWithAFixedSentence() throws {
        let s = try status(of: statusLine(licence: #""broken""#))
        XCTAssertEqual(s.licence, SpanDACLicenceInfo(serving: false, state: "unreadable",
                                                     text: SpanDACLicenceInfo.unreadableText))
        XCTAssertEqual(s.readiness,
                       .unavailable(spanDACNotLicensedLine(SpanDACLicenceInfo.unreadableText)))
    }

    func testANotServingLicenceWithNoTextStillReadsAsASentence() throws {
        let s = try status(of: statusLine(licence: #"{"serving":false,"state":"none"}"#))
        XCTAssertEqual(s.licence?.text, SpanDACLicenceInfo.unreadableText)
    }

    // MARK: pre-licence status decodes exactly as before

    func testAPreLicenceStatusHasNoLicenceAndIsReady() throws {
        let s = try status(of: statusLine(playback: "playing",
                                          queue: #"{"phase":"complete","requested":3,"present":3,"index":1}"#))
        XCTAssertNil(s.licence)
        XCTAssertEqual(s.readiness, .ready)
        XCTAssertEqual(s.playback, "playing")
        XCTAssertEqual(s.queuePhase, "complete")
        XCTAssertEqual(s.queueIndex, 1)
        XCTAssertNil(s.output)
    }

    func testANullLicenceIsReadyToo() throws {
        let s = try status(of: statusLine(licence: "null"))
        XCTAssertNil(s.licence)
        XCTAssertEqual(s.readiness, .ready)
    }

    func testAServingLicenceIsReadyAndCarried() throws {
        let s = try status(of: statusLine(licence: #"{"serving":true,"state":"licensed","text":"Licensed"}"#))
        XCTAssertEqual(s.licence, SpanDACLicenceInfo(serving: true, state: "licensed", text: "Licensed"))
        XCTAssertEqual(s.readiness, .ready)
    }

    // MARK: readiness order

    func testNotServingReadsTheLicenceLineAndIsNotSelectable() throws {
        let s = try status(of: statusLine(licence: notServing))
        let line = spanDACNotLicensedLine("No licence - enter your key in SpanDAC")
        XCTAssertEqual(s.readiness, .unavailable(line))
        XCTAssertFalse(s.readiness.canSelect)
        XCTAssertFalse(outputModeSelectable(.source, readiness: s.readiness))
        let client = SourceAppClient(path: "/nonexistent", transport: { _, _ in self.statusLine(licence: self.notServing) })
        XCTAssertEqual(client.readiness(), .unavailable(line))
    }

    func testTheLicenceLineBeatsAuthorization() throws {
        let line = statusLine(licence: notServing, authorization: "not_determined")
        XCTAssertEqual(try status(of: line).readiness,
                       .unavailable(spanDACNotLicensedLine("No licence - enter your key in SpanDAC")))
    }

    func testTheContractCheckComesBeforeTheLicenceCheck() throws {
        let line = statusLine(licence: notServing, contract: 99)
        XCTAssertEqual(try status(of: line).readiness,
                       .unavailable(sourceContractMismatchReason(99)))
    }

    func testAServingLicenceDoesNotMaskAuthorization() throws {
        let line = statusLine(licence: #"{"serving":true,"state":"licensed","text":"Licensed"}"#,
                              authorization: "not_determined")
        XCTAssertEqual(try status(of: line).readiness,
                       .unavailable("SpanDAC has not been granted Apple Music access yet"))
    }

    func testDataReadinessIsNotMadeReadyByANotServingLicence() throws {
        let s = try status(of: statusLine(licence: notServing))
        XCTAssertNotEqual(s.dataReadiness, .ready)
    }

    // MARK: the error and its words

    func testAnUnlicensedReplyThrowsTheDetail() {
        let c = control(unlicensedError)
        XCTAssertThrowsError(try c.send(["op": "slice.search"])) { error in
            XCTAssertEqual(error as? SourceAppError,
                           .unlicensed("No licence - enter your key in SpanDAC"))
        }
    }

    func testTheUnlicensedMessageIsTheDetailVerbatim() {
        XCTAssertEqual(SourceAppError.unlicensed("No licence - enter your key in SpanDAC").message,
                       "No licence - enter your key in SpanDAC")
    }

    func testAnUnlicensedErrorMapsToTheLicenceLineAsReadiness() {
        XCTAssertEqual(SourceReadiness.from(SourceAppError.unlicensed("Licence expired")),
                       .unavailable(spanDACNotLicensedLine("Licence expired")))
    }

    func testOtherRefusalsAreUnchanged() {
        let busy = #"{"ok":false,"error":{"kind":"busy","detail":"x"}}"#
        XCTAssertThrowsError(try control(busy).send(["op": "slice.search"])) {
            XCTAssertEqual($0 as? SourceAppError, .busy)
        }
        let other = #"{"ok":false,"error":{"kind":"nope","detail":"because"}}"#
        XCTAssertThrowsError(try control(other).send(["op": "slice.search"])) {
            XCTAssertEqual($0 as? SourceAppError, .refused("because"))
        }
    }

    func testTheNotLicensedLineNamesTheOutputAndNotMusicApp() {
        XCTAssertEqual(spanDACNotLicensedLine("No licence - enter your key in SpanDAC"),
                       "SpanDAC is installed but not licensed - using the MusicTUI output instead. "
                       + "No licence - enter your key in SpanDAC")
        XCTAssertEqual(spanDACNotLicensedLine(""),
                       "SpanDAC is installed but not licensed - using the MusicTUI output instead.")
    }

    func testNoLicenceSentenceMentionsTheAppleMusicVocabulary() {
        let sentences = [spanDACNotLicensedLine("No licence - enter your key in SpanDAC"),
                         spanDACNotLicensedLine(""), iPhoneIPadNeedsLicensedMac,
                         SpanDACLicenceInfo.unreadableText,
                         SpanDACLicenceInfo(status: object(#"{"licence":7}"#))!.text]
        for sentence in sentences {
            for word in ["Music.app", "Apple Music", "catalogue", "catalog", "library"] {
                XCTAssertFalse(sentence.localizedCaseInsensitiveContains(word), "\(word) in: \(sentence)")
            }
        }
    }

    func testTheIPhoneIPadSentence() {
        XCTAssertEqual(iPhoneIPadNeedsLicensedMac, "iPhone/iPad SpanDAC needs SpanDAC for Mac, licensed.")
    }

    // MARK: the cache

    func testACacheStartsUnknown() {
        let snap = SpanDACServingCache().snapshot()
        XCTAssertNil(snap.serving)
        XCTAssertEqual(snap.changes, 0)
        XCTAssertFalse(snap.bridgeLoaded)
    }

    func testAStatusWithoutLicenceIsServingAndNotAChangeOnRepeat() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine())
        XCTAssertEqual(cache.snapshot().serving, true)
        XCTAssertEqual(cache.snapshot().changes, 1)
        cache.observe(replyLine: statusLine())
        cache.observe(replyLine: statusLine(licence: "null"))
        XCTAssertEqual(cache.snapshot().changes, 1)
    }

    func testANotServingStatusFlipsAndServingAgainFlipsBack() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine())
        cache.observe(replyLine: statusLine(licence: notServing))
        XCTAssertEqual(cache.snapshot().serving, false)
        XCTAssertEqual(cache.snapshot().changes, 2)
        cache.observe(replyLine: statusLine(licence: notServing))
        XCTAssertEqual(cache.snapshot().changes, 2)
        cache.observe(replyLine: statusLine(licence: #"{"serving":true,"state":"licensed","text":"Licensed"}"#))
        XCTAssertEqual(cache.snapshot().serving, true)
        XCTAssertEqual(cache.snapshot().changes, 3)
    }

    func testAnUnlicensedErrorMeansNotServingUntilTheNextStatus() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine())
        cache.observe(replyLine: unlicensedError)
        XCTAssertEqual(cache.snapshot().serving, false)
        XCTAssertEqual(cache.snapshot().changes, 2)
        cache.observe(replyLine: statusLine())
        XCTAssertEqual(cache.snapshot().serving, true)
        XCTAssertEqual(cache.snapshot().changes, 3)
    }

    func testAMalformedLicenceInAStatusIsNotServing() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine(licence: #"{"serving":"yes"}"#))
        XCTAssertEqual(cache.snapshot().serving, false)
    }

    func testOtherRepliesChangeNothing() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine())
        let before = cache.snapshot()
        for line in ["", "not json", "[]", #"{"ok":true,"op":"slice.search","stations":[]}"#,
                     #"{"ok":true,"status":{"title":"x"}}"#,
                     #"{"ok":false,"error":{"kind":"busy","detail":"x"}}"#,
                     #"{"ok":false,"error":{"kind":"unauthorized","detail":"x"}}"#,
                     #"{"ok":false}"#, #"{"ok":"yes"}"#] {
            cache.observe(replyLine: line)
        }
        let after = cache.snapshot()
        XCTAssertEqual(after.serving, before.serving)
        XCTAssertEqual(after.changes, before.changes)
        XCTAssertEqual(after.bridgeLoaded, before.bridgeLoaded)
    }

    func testBridgeLoadedFollowsTheQueueAndPlayback() {
        let cache = SpanDACServingCache()
        cache.observe(replyLine: statusLine(playback: "playing", queue: #"{"phase":"complete","requested":2}"#))
        XCTAssertTrue(cache.snapshot().bridgeLoaded)
        cache.observe(replyLine: unlicensedError)
        XCTAssertTrue(cache.snapshot().bridgeLoaded, "an unlicensed error does not unload the queue")
        cache.observe(replyLine: statusLine(licence: notServing, playback: "paused",
                                            queue: #"{"phase":"building","requested":2}"#))
        XCTAssertTrue(cache.snapshot().bridgeLoaded)
        cache.observe(replyLine: statusLine(licence: notServing, playback: "stopped",
                                            queue: #"{"phase":"complete","requested":2}"#))
        XCTAssertFalse(cache.snapshot().bridgeLoaded)
        cache.observe(replyLine: statusLine(playback: "playing", queue: #"{"phase":"complete","requested":2}"#))
        cache.observe(replyLine: statusLine(playback: "playing", queue: #"{"phase":"none"}"#))
        XCTAssertFalse(cache.snapshot().bridgeLoaded)
        cache.observe(replyLine: statusLine(playback: "playing", queue: #"{"phase":"invalid","requested":2}"#))
        XCTAssertFalse(cache.snapshot().bridgeLoaded)
        cache.observe(replyLine: statusLine(playback: "playing"))
        XCTAssertFalse(cache.snapshot().bridgeLoaded)
    }

    // MARK: the transport wrapper

    func testTheWrapperReturnsTheBytesUnchangedAndObservesThem() throws {
        let cache = SpanDACServingCache()
        let reply = statusLine(licence: notServing) + "\n"
        var seen: [(String, String)] = []
        let wrapped = observingLicence({ path, line in seen.append((path, line)); return reply }, cache: cache)
        XCTAssertEqual(try wrapped("/p", "{\"op\":\"slice.status\"}"), reply)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "/p")
        XCTAssertEqual(seen.first?.1, "{\"op\":\"slice.status\"}")
        XCTAssertEqual(cache.snapshot().serving, false)
    }

    func testTheWrapperPassesAnUnlicensedReplyThroughAndLearnsFromIt() throws {
        let cache = SpanDACServingCache()
        let wrapped = observingLicence({ _, _ in self.unlicensedError }, cache: cache)
        XCTAssertEqual(try wrapped("/p", "x"), unlicensedError)
        XCTAssertEqual(cache.snapshot().serving, false)
    }

    func testTheWrapperRethrowsTheSameErrorAndObservesNothing() {
        let cache = SpanDACServingCache()
        let wrapped = observingLicence({ _, _ in throw SourceAppError.timedOut }, cache: cache)
        XCTAssertThrowsError(try wrapped("/p", "x")) {
            XCTAssertEqual($0 as? SourceAppError, .timedOut)
        }
        XCTAssertNil(cache.snapshot().serving)
        XCTAssertEqual(cache.snapshot().changes, 0)
    }

    func testAClientBuiltOnAWrappedTransportFeedsTheCache() throws {
        let cache = SpanDACServingCache()
        let client = SourceAppClient(path: "/nonexistent",
                                     transport: observingLicence({ _, _ in self.statusLine(licence: self.notServing) },
                                                                 cache: cache))
        XCTAssertEqual(client.readiness(), .unavailable(spanDACNotLicensedLine("No licence - enter your key in SpanDAC")))
        XCTAssertEqual(cache.snapshot().serving, false)
    }

    // MARK: freshness: a late reply never overwrites newer evidence (Codex review 100, finding 2)

    /// Runs `older` on another thread until its transport has been entered and
    /// is held, then runs `newer` to completion, then lets `older` finish: the
    /// older request completes LAST. `between` runs after `newer`, while
    /// `older` is still in flight.
    private func reverseCompletion(older: @escaping (@escaping () -> Void) throws -> Void,
                                   newer: () throws -> Void,
                                   between: () -> Void = {}) rethrows {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "the older request finished")
        DispatchQueue.global().async {
            try? older({ entered.signal(); _ = release.wait(timeout: .now() + 10) })
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "the older request was sent")
        try newer()
        between()
        release.signal()
        wait(for: [finished], timeout: 10)
    }

    private let playingLoaded = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2}}}"#

    /// Request A is sent while SpanDAC serves with a queue loaded and stalls;
    /// request B, sent after, says not serving and idle and is observed; A's
    /// late reply must not restore serving or the loaded queue.
    func testALateOlderStatusDoesNotOverwriteANewerOne() {
        let cache = SpanDACServingCache()
        try? reverseCompletion(older: { hold in
            _ = try observingLicence({ _, _ in hold(); return self.playingLoaded }, cache: cache)("/nonexistent", #"{"op":"slice.status"}"#)
        }, newer: {
            _ = try observingLicence({ _, _ in self.statusLine(licence: self.notServing) }, cache: cache)("/nonexistent", #"{"op":"slice.status"}"#)
        })
        XCTAssertEqual(cache.snapshot().serving, false, "the older reply restored serving")
        XCTAssertFalse(cache.snapshot().bridgeLoaded, "the older reply restored the loaded queue")
        XCTAssertEqual(cache.snapshot().changes, 1, "only the newer answer was a change")
    }

    /// The same with an `unlicensed` refusal as the newer reply.
    func testALateOlderStatusDoesNotUndoANewerUnlicensedRefusal() {
        let cache = SpanDACServingCache()
        try? reverseCompletion(older: { hold in
            _ = try observingLicence({ _, _ in hold(); return self.statusLine() }, cache: cache)("/nonexistent", #"{"op":"slice.status"}"#)
        }, newer: {
            _ = try observingLicence({ _, _ in self.unlicensedError }, cache: cache)("/nonexistent", #"{"op":"slice.search"}"#)
        })
        XCTAssertEqual(cache.snapshot().serving, false, "the older reply undid the refusal")
    }

    /// An iPhone/iPad output's queue evidence: an older request that saw the
    /// queue playing completes after a newer one that saw it idle.
    func testALateOlderReplyDoesNotRepopulateAnOutputsQueue() {
        let queues = SpanDACOutputQueues(), id = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
        try? reverseCompletion(older: { hold in
            _ = try observingOutputQueue({ _, _ in hold(); return self.playingLoaded }, sourceID: id, queues: queues)("spandac:x", #"{"op":"slice.status"}"#)
        }, newer: {
            _ = try observingOutputQueue({ _, _ in self.statusLine(playback: "idle") }, sourceID: id, queues: queues)("spandac:x", #"{"op":"slice.status"}"#)
        })
        XCTAssertFalse(queues.isLoaded(id), "the older reply repopulated the output's queue")
    }

    /// A reply already in flight when `forget` runs cannot repopulate that
    /// output; a request sent after `forget` still can.
    func testAReplyInFlightAcrossForgetDoesNotRepopulateTheOutput() throws {
        let queues = SpanDACOutputQueues(), id = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
        try? reverseCompletion(older: { hold in
            _ = try observingOutputQueue({ _, _ in hold(); return self.playingLoaded }, sourceID: id, queues: queues)("spandac:x", #"{"op":"slice.status"}"#)
        }, newer: {}, between: { queues.forget(id) })
        XCTAssertFalse(queues.isLoaded(id), "a reply sent before forget repopulated the output")
        _ = try observingOutputQueue({ _, _ in self.playingLoaded }, sourceID: id, queues: queues)("spandac:x", #"{"op":"slice.status"}"#)
        XCTAssertTrue(queues.isLoaded(id), "a request sent after forget is evidence")
    }

    /// Freshness is per output: a newer reply from one output never discards
    /// an older one's evidence about another.
    func testFreshnessIsPerOutput() {
        let queues = SpanDACOutputQueues(), a = "A-OUTPUT", b = "B-OUTPUT"
        try? reverseCompletion(older: { hold in
            _ = try observingOutputQueue({ _, _ in hold(); return self.playingLoaded }, sourceID: a, queues: queues)("spandac:a", #"{"op":"slice.status"}"#)
        }, newer: {
            _ = try observingOutputQueue({ _, _ in self.statusLine(playback: "idle") }, sourceID: b, queues: queues)("spandac:b", #"{"op":"slice.status"}"#)
        })
        XCTAssertTrue(queues.isLoaded(a))
        XCTAssertFalse(queues.isLoaded(b))
    }

    // MARK: the simple reply paths decode `unlicensed` (review finding 9)

    private let unlicensedDetail = "No licence - enter your key in SpanDAC"

    func testStationSearchDecodesAnUnlicensedReplyAsUnlicensed() {
        let search = SourceAppStationSearch(path: "/nonexistent", transport: { _, _ in
            #"{"ok":false,"op":"slice.searchStations","error":{"kind":"unlicensed","detail":"\#(self.unlicensedDetail)"}}"#
        })
        XCTAssertThrowsError(try search.searchStations(term: "jazz")) {
            XCTAssertEqual($0 as? SourceAppError, .unlicensed(self.unlicensedDetail))
        }
    }

    func testDirectPlayDecodesAnUnlicensedReplyAsUnlicensed() {
        let play = SourceAppPlayback(path: "/nonexistent", transport: { _, _ in
            #"{"ok":false,"op":"slice.play","error":{"kind":"unlicensed","detail":"\#(self.unlicensedDetail)"}}"#
        })
        XCTAssertThrowsError(try play.play(catalogID: "1234")) {
            XCTAssertEqual($0 as? SourceAppError, .unlicensed(self.unlicensedDetail))
        }
    }
}
