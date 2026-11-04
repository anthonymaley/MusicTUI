// tools/music/Tests/MusicTests/DJBoxModelTests.swift
//
// The DJ box as a pure model: raw text entry, one request id per ask (a newer
// prompt wins, and an answer for any other id is dropped, errors included),
// the card that Enter plays exactly once and Esc drops, the artist picker, and
// the plain message states. No I/O, no clock, no host.
import XCTest
@testable import music

final class DJBoxModelTests: XCTestCase {

    private func type(_ model: inout DJBoxModel, _ text: String) {
        for c in text { _ = model.handle(c == " " ? .space : .char(c)) }
    }

    private func plan(_ line: String = "Radiohead \u{00B7} 2 songs from 1 album") -> DJPlan {
        DJPlan(payload: .artistMix(DJArtistMix(artistName: "Radiohead", artistID: "a", ids: ["1", "2"],
                                               albumCount: 1, moreAlbums: false, unavailable: 0)),
               line: line, stamp: DJStamp(epoch: 1, dataEpoch: 1, playSerial: 0))
    }

    // MARK: - Typing and asking

    func testTypingBuildsTheTextAndEnterAsksOnce() {
        var m = DJBoxModel()
        type(&m, "play some jazz")
        XCTAssertEqual(m.text, "play some jazz")
        XCTAssertEqual(m.stage, .typing)
        let out = m.handle(.enter)
        XCTAssertEqual(out.emission, .ask(prompt: "play some jazz", requestID: 1))
        XCTAssertEqual(m.stage, .reading)
        XCTAssertEqual(m.requestID, 1)
    }

    func testEveryLetterIsText() {
        var m = DJBoxModel()
        type(&m, "p r q j k / d")
        XCTAssertEqual(m.text, "p r q j k / d", "a letter the shell or Discover uses was not taken as text")
    }

    func testBlankTextAsksNothing() {
        var m = DJBoxModel()
        XCTAssertNil(m.handle(.enter).emission)
        type(&m, "   ")
        XCTAssertNil(m.handle(.enter).emission)
        XCTAssertEqual(m.requestID, 0)
    }

    func testBackspaceAndControlCharacters() {
        var m = DJBoxModel()
        type(&m, "jazzz")
        _ = m.handle(.char("\u{7F}"))
        XCTAssertEqual(m.text, "jazz")
        XCTAssertFalse(m.handle(.char("\u{1B}")).changed, "a control character became text")
        XCTAssertEqual(m.text, "jazz")
    }

    func testTheTextIsBounded() {
        var m = DJBoxModel()
        for _ in 0..<(DJBoxModel.maxTextLength + 50) { _ = m.handle(.char("x")) }
        XCTAssertEqual(m.text.count, DJBoxModel.maxTextLength)
    }

    func testTheAskedPromptIsTrimmed() {
        var m = DJBoxModel()
        type(&m, "  jazz  ")
        XCTAssertEqual(m.handle(.enter).emission, .ask(prompt: "jazz", requestID: 1))
    }

    // MARK: - A newer prompt wins

    func testASecondEnterWhileReadingAsksAgainWithTheNextID() {
        var m = DJBoxModel()
        type(&m, "one")
        _ = m.handle(.enter)
        _ = m.handle(.char("\u{7F}")); _ = m.handle(.char("\u{7F}")); _ = m.handle(.char("\u{7F}"))
        type(&m, "two")
        XCTAssertEqual(m.handle(.enter).emission, .ask(prompt: "two", requestID: 2))
        XCTAssertFalse(m.receive(.message("late one"), requestID: 1), "the older answer was applied")
        XCTAssertEqual(m.stage, .reading)
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 2))
        XCTAssertEqual(m.stage, .card(plan()))
    }

    func testALateErrorForAnOlderRequestIsDroppedToo() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        type(&m, "b"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 2))
        XCTAssertFalse(m.receive(.message("The DJ couldn't read that: boom"), requestID: 1))
        XCTAssertEqual(m.stage, .card(plan()))
    }

    func testAnAnswerAfterEscFindsNothingToLandOn() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        XCTAssertEqual(m.handle(.escape).emission, .close)
        XCTAssertFalse(m.receive(.plan(plan()), requestID: 1), "an answer landed after the box closed")
    }

    func testTheSameAnswerCannotLandTwice() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 1))
        XCTAssertFalse(m.receive(.plan(plan("second")), requestID: 1))
        XCTAssertEqual(m.stage, .card(plan()))
    }

    // MARK: - Editing a pending prompt invalidates the request that is out

    func testEditingWhileReadingDropsTheRequestSoItsLateSuccessNeverLands() {
        var m = DJBoxModel()
        type(&m, "one"); _ = m.handle(.enter)
        XCTAssertEqual(m.stage, .reading)
        type(&m, "x")
        XCTAssertEqual(m.stage, .typing, "an edit left the old request waiting")
        XCTAssertFalse(m.receive(.plan(plan()), requestID: 1), "the edited-away request landed a card")
        XCTAssertEqual(m.stage, .typing)
    }

    func testEditingWhileReadingDropsTheRequestSoItsLateFailureNeverLands() {
        var m = DJBoxModel()
        type(&m, "one"); _ = m.handle(.enter)
        _ = m.handle(.char("\u{7F}"))
        XCTAssertFalse(m.receive(.message("The DJ couldn't read that: boom"), requestID: 1))
        XCTAssertEqual(m.stage, .typing)
    }

    func testEditingWhileLookingUpDropsTheRequestToo() {
        var m = DJBoxModel()
        type(&m, "one"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.working("Radiohead"), requestID: 1))
        type(&m, "x")
        XCTAssertEqual(m.stage, .typing)
        XCTAssertFalse(m.receive(.plan(plan()), requestID: 1))
        XCTAssertFalse(m.receive(.message("late"), requestID: 1))
        XCTAssertEqual(m.stage, .typing)
    }

    func testTheEnterAfterAnEditAsksTheNewTextUnderANewID() {
        var m = DJBoxModel()
        type(&m, "one"); _ = m.handle(.enter)
        type(&m, "x")
        let out = m.handle(.enter)
        XCTAssertEqual(out.emission, .ask(prompt: "onex", requestID: 2))
        XCTAssertFalse(m.receive(.message("old"), requestID: 1))
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 2))
    }

    // MARK: - The card

    func testEnterOnTheCardPlaysThatPlanOnceAndNeverAgain() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        _ = m.receive(.plan(plan()), requestID: 1)
        let first = m.handle(.enter)
        XCTAssertEqual(first.emission, .play(plan()))
        XCTAssertEqual(m.stage, .sent(plan().line))
        XCTAssertNil(m.handle(.enter).emission, "a second Enter played again")
        XCTAssertNil(m.handle(.enter).emission)
    }

    func testNothingIsEmittedUntilEnter() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        _ = m.receive(.plan(plan()), requestID: 1)
        XCTAssertEqual(m.stage, .card(plan()), "a card appeared as played")
    }

    func testEscDropsTheCardAndClosesTheBox() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        _ = m.receive(.plan(plan()), requestID: 1)
        XCTAssertEqual(m.handle(.escape).emission, .close)
        XCTAssertNil(m.handle(.enter).emission, "the dropped card still played")
    }

    func testTypingOnTheCardDropsItAndEditsThePrompt() {
        var m = DJBoxModel()
        type(&m, "jazz"); _ = m.handle(.enter)
        _ = m.receive(.plan(plan()), requestID: 1)
        _ = m.handle(.char("!"))
        XCTAssertEqual(m.stage, .typing)
        XCTAssertEqual(m.text, "jazz!")
        XCTAssertEqual(m.handle(.enter).emission, .ask(prompt: "jazz!", requestID: 2),
                       "Enter after an edit must ask again, not play the old card")
    }

    func testDroppingTheCardForAChange() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        _ = m.receive(.plan(plan()), requestID: 1)
        m.drop(saying: "The output changed.")
        XCTAssertEqual(m.stage, .message("The output changed."))
        XCTAssertNil(m.handle(.enter).emission.flatMap { if case .play = $0 { return $0 } else { return nil } })
    }

    // MARK: - Messages

    func testAMessageShowsAndEnterAsksAgain() {
        var m = DJBoxModel()
        type(&m, "jazz"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.message("nope"), requestID: 1))
        XCTAssertEqual(m.stage, .message("nope"))
        XCTAssertEqual(m.handle(.enter).emission, .ask(prompt: "jazz", requestID: 2))
    }

    func testAMessageLosesControlCharacters() {
        var m = DJBoxModel()
        type(&m, "a"); _ = m.handle(.enter)
        _ = m.receive(.message("bad\u{1B}[2Jtext"), requestID: 1)
        XCTAssertEqual(m.stage, .message("bad[2Jtext"))
    }

    // MARK: - The picker

    private let nirvana = [djArtistHit("n1", "Nirvana"), djArtistHit("n2", "Nirvana")]

    func testThePickerMovesAndEnterChoosesTheCatalogueHit() {
        var m = DJBoxModel()
        type(&m, "nirvana mix"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.pick(artist: "Nirvana", hits: nirvana), requestID: 1))
        guard case .pick(let picker) = m.stage else { return XCTFail("\(m.stage)") }
        XCTAssertEqual(picker.cursor, 0)
        _ = m.handle(.down)
        _ = m.handle(.down)
        guard case .pick(let moved) = m.stage else { return XCTFail() }
        XCTAssertEqual(moved.cursor, 1, "the cursor ran past the last artist")
        _ = m.handle(.up)
        _ = m.handle(.down)
        let out = m.handle(.enter)
        XCTAssertEqual(out.emission, .choose(nirvana[1], requestID: 2))
        XCTAssertEqual(m.stage, .working("Nirvana"))
        XCTAssertEqual(m.requestID, 2)
    }

    func testThePickersLateAnswerForTheOldRequestIsDropped() {
        var m = DJBoxModel()
        type(&m, "nirvana mix"); _ = m.handle(.enter)
        _ = m.receive(.pick(artist: "Nirvana", hits: nirvana), requestID: 1)
        _ = m.handle(.enter)
        XCTAssertFalse(m.receive(.plan(plan()), requestID: 1))
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 2))
    }

    func testTypingInThePickerDropsIt() {
        var m = DJBoxModel()
        type(&m, "nirvana"); _ = m.handle(.enter)
        _ = m.receive(.pick(artist: "Nirvana", hits: nirvana), requestID: 1)
        _ = m.handle(.char("x"))
        XCTAssertEqual(m.stage, .typing)
    }

    // MARK: - Working

    func testTheDJUnderstoodAndIsLookingUp() {
        var m = DJBoxModel()
        type(&m, "radiohead mix"); _ = m.handle(.enter)
        XCTAssertTrue(m.receive(.working("Radiohead"), requestID: 1))
        XCTAssertEqual(m.stage, .working("Radiohead"))
        XCTAssertTrue(m.receive(.plan(plan()), requestID: 1), "the plan that follows `working` is the same request's")
    }

    // MARK: - The words shown

    func testEachStageHasALineToShow() {
        var m = DJBoxModel()
        XCTAssertNil(m.statusLine)
        type(&m, "x"); _ = m.handle(.enter)
        XCTAssertEqual(m.statusLine, "Asking the DJ\u{2026}")
        _ = m.receive(.working("Radiohead"), requestID: 1)
        XCTAssertEqual(m.statusLine, "Looking up Radiohead\u{2026}")
        _ = m.receive(.plan(plan("The line")), requestID: 1)
        XCTAssertEqual(m.statusLine, "The line \u{2014} Enter plays, Esc drops it")
    }
}
