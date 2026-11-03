// tools/music/Tests/MusicTests/CatalogueSearchModelTests.swift
//
// The Discover catalogue search's pure model and pane (score S3): typing,
// editing vs results, grouping, the cursor that skips headers, the artist
// level, an intent per key per kind, and request ids that never let an older
// answer overwrite a newer one or revive a departed screen. Fakes only: the
// pane performs no I/O, so a recording host is the whole rig.
import XCTest
@testable import music

private final class RecordingHost: CatalogueSearchHost {
    var emitted: [(intent: CatalogueSearchIntent, id: Int)] = []
    func cataloguePane(_ pane: CatalogueSearchPane, emit intent: CatalogueSearchIntent, requestID: Int) {
        emitted.append((intent, requestID))
    }
    var intents: [CatalogueSearchIntent] { emitted.map(\.intent) }
    /// Never nil, so a red run fails an assertion instead of crashing the process.
    var lastOrNone: (intent: CatalogueSearchIntent, id: Int) {
        emitted.last ?? (.search("<nothing emitted>"), -1)
    }
}

private func artist(_ id: String, _ title: String) -> CatalogueHit {
    CatalogueHit(kind: .artist, id: id, title: title, subtitle: nil, album: nil)
}
private func album(_ id: String, _ title: String, _ by: String = "Someone") -> CatalogueHit {
    CatalogueHit(kind: .album, id: id, title: title, subtitle: by, album: nil)
}
private func song(_ id: String, _ title: String, _ by: String = "Someone", on: String? = "Some Album") -> CatalogueHit {
    CatalogueHit(kind: .song, id: id, title: title, subtitle: by, album: on)
}

private let A1 = artist("ar1", "Radiohead"), A2 = artist("ar2", "Radio Dept.")
private let B1 = album("al1", "Kid A", "Radiohead"), B2 = album("al2", "Amnesiac", "Radiohead"),
            B3 = album("al3", "Kid A Mnesia", "Radiohead")
private let S1 = song("so1", "Idioteque", "Radiohead", on: "Kid A")

private func fullResults(note: String? = nil, served: Bool = true) -> CatalogueSearchResults {
    CatalogueSearchResults(artists: [A1, A2], albums: [B1, B2, B3], songs: [S1],
                           artistsServed: served, artistsNote: note)
}

final class CatalogueSearchModelTests: XCTestCase {

    private var host: RecordingHost!
    private var pane: CatalogueSearchPane!

    override func setUp() {
        host = RecordingHost()
        pane = CatalogueSearchPane(host: host)
    }

    private func type(_ s: String) {
        for c in s { _ = pane.handle(c == " " ? .space : .char(c)) }
    }

    /// Types a term, presses Enter and returns the request id the host saw.
    @discardableResult
    private func search(_ term: String) -> Int {
        type(term)
        _ = pane.handle(.enter)
        return host.lastOrNone.id
    }

    /// A pane showing `fullResults` with the cursor on the first row.
    private func onResults(_ r: CatalogueSearchResults? = nil) {
        let id = search("kid a")
        XCTAssertTrue(pane.didReceive(results: r ?? fullResults(), requestID: id))
    }

    private func press(_ keys: KeyPress...) { for k in keys { _ = pane.handle(k) } }

    private var cursorHit: CatalogueHit? { pane.model.selectedHit }

    // MARK: typing

    func testItStartsEditingWithAnEmptyBoxAndNoIntent() {
        XCTAssertTrue(pane.isEditing)
        XCTAssertEqual(pane.model.text, "")
        XCTAssertTrue(host.emitted.isEmpty)
    }

    func testEveryPrintableCharacterIncludingCommandLettersAndSpaceGoesToTheText() {
        type("p r q j k /")
        XCTAssertEqual(pane.model.text, "p r q j k /")
        type("lhgG[]+-")
        XCTAssertEqual(pane.model.text, "p r q j k /lhgG[]+-")
        XCTAssertTrue(pane.isEditing)
        XCTAssertTrue(host.emitted.isEmpty, "typing never emits")
    }

    func testBackspaceRemovesInBothEncodingsAndIsHarmlessOnEmpty() {
        press(.char("\u{7F}"), .char("\u{8}"))
        XCTAssertEqual(pane.model.text, "")
        type("abcd")
        press(.char("\u{7F}"))
        XCTAssertEqual(pane.model.text, "abc")
        press(.char("\u{8}"))
        XCTAssertEqual(pane.model.text, "ab")
    }

    func testControlCharactersAndNavigationKeysAreNotTyped() {
        type("ab")
        press(.char("\u{01}"), .up, .down, .left, .right, .home, .end, .pageUp, .pageDown)
        XCTAssertEqual(pane.model.text, "ab")
        XCTAssertTrue(pane.isEditing)
    }

    func testEnterOnAnEmptyOrBlankTermDoesNothing() {
        press(.enter)
        XCTAssertTrue(host.emitted.isEmpty)
        XCTAssertTrue(pane.isEditing)
        type("   ")
        press(.enter)
        XCTAssertTrue(host.emitted.isEmpty)
        XCTAssertTrue(pane.isEditing)
    }

    func testEnterSearchesOnceWithTheTrimmedTermAndLeavesEditing() {
        type("  kid a ")
        press(.enter)
        XCTAssertEqual(host.intents, [.search("kid a")])
        XCTAssertFalse(pane.isEditing)
        XCTAssertEqual(pane.model.note, "Searching “kid a”…")
        press(.enter)
        XCTAssertEqual(host.intents.count, 1, "Enter with nothing under the cursor emits nothing more")
    }

    func testSearchRequestIDsAreStrictlyIncreasing() {
        let first = search("a")
        press(.char("/"))
        press(.enter)   // same term re-searched
        let second = host.lastOrNone.id
        XCTAssertGreaterThan(second, first)
    }

    // MARK: Esc while editing

    func testEscWhileEditingWithNothingBehindItCloses() {
        type("kid")
        press(.escape)
        XCTAssertEqual(host.intents, [.close])
    }

    func testEscWhileEditingKeepsThePreviousResultsAndRestoresTheLastTerm() {
        onResults()
        press(.down)
        let before = pane.model.rows
        let cursorBefore = pane.model.cursor
        press(.char("/"))
        XCTAssertTrue(pane.isEditing)
        XCTAssertEqual(pane.model.text, "kid a", "/ reopens with the last term")
        type("zzz")
        press(.escape)
        XCTAssertFalse(pane.isEditing)
        XCTAssertEqual(pane.model.text, "kid a", "the abandoned edit is discarded")
        XCTAssertEqual(pane.model.rows, before)
        XCTAssertEqual(pane.model.cursor, cursorBefore)
        XCTAssertEqual(host.intents, [.search("kid a")], "Esc while editing never closes when results exist")
    }

    func testSlashOnResultsThenEnterSearchesAgainAndDropsTheOldResults() {
        onResults()
        press(.char("/"))
        type("e")
        press(.enter)
        XCTAssertEqual(host.intents, [.search("kid a"), .search("kid ae")])
        XCTAssertNil(pane.model.results)
        XCTAssertEqual(pane.model.note, "Searching “kid ae”…")
    }

    // MARK: grouping and cursor

    func testResultsAreGroupedArtistsAlbumsSongsWithHeaders() {
        onResults()
        XCTAssertEqual(pane.model.rows, [
            .header("Artists"), .hit(A1), .hit(A2),
            .header("Albums"), .hit(B1), .hit(B2), .hit(B3),
            .header("Songs"), .hit(S1),
        ])
        XCTAssertEqual(cursorHit, A1, "the cursor starts on the first hit, not on a header")
    }

    func testEmptyGroupsAreOmitted() {
        onResults(CatalogueSearchResults(artists: [], albums: [], songs: [S1],
                                         artistsServed: false, artistsNote: nil))
        XCTAssertEqual(pane.model.rows, [.header("Songs"), .hit(S1)])
        XCTAssertEqual(cursorHit, S1)
    }

    func testTheCursorSkipsHeadersBothWaysAndClampsAtTheEnds() {
        onResults()
        press(.up)
        XCTAssertEqual(cursorHit, A1, "clamped at the top")
        press(.down, .down)
        XCTAssertEqual(cursorHit, B1, "A2 then over the Albums header to B1")
        press(.char("j"), .char("j"), .char("j"))
        XCTAssertEqual(cursorHit, S1, "B2, B3, then over the Songs header")
        press(.down, .char("j"))
        XCTAssertEqual(cursorHit, S1, "clamped at the bottom")
        press(.char("k"))
        XCTAssertEqual(cursorHit, B3)
        press(.up, .up)
        XCTAssertEqual(cursorHit, B1)
        press(.char("k"))
        XCTAssertEqual(cursorHit, A2, "back over the Albums header")
    }

    func testHomeEndAndPagingLandOnHitsNeverOnHeaders() {
        onResults()
        press(.end)
        XCTAssertEqual(cursorHit, S1)
        press(.home)
        XCTAssertEqual(cursorHit, A1)
        press(.pageDown)
        XCTAssertNotNil(cursorHit)
        press(.pageUp)
        XCTAssertNotNil(cursorHit)
        XCTAssertNotNil(cursorHit, "cursor on a header or nowhere")
    }

    func testAnEmptyResultSetHasNoSelectionAndEnterDoesNothing() {
        onResults(CatalogueSearchResults(artists: [], albums: [], songs: [],
                                         artistsServed: true, artistsNote: nil))
        XCTAssertNil(cursorHit)
        press(.enter, .right, .char("p"), .down, .up)
        XCTAssertEqual(host.intents, [.search("kid a")])
        XCTAssertEqual(pane.model.note, "No results for “kid a”.")
    }

    // MARK: intents per key per kind

    func testEnterOnAnArtistOpensItAndStartsALevelWithItsOwnRequestID() {
        onResults()
        let searchID = host.lastOrNone.id
        press(.enter)
        XCTAssertEqual(host.lastOrNone.intent, .openArtist(A1))
        XCTAssertGreaterThan(host.lastOrNone.id, searchID)
        XCTAssertEqual(pane.model.artist, A1)
        XCTAssertEqual(pane.model.rows, [], "no albums until they arrive")
    }

    func testEnterOnAnAlbumOpensItAndKeepsTheCursor() {
        onResults()
        press(.down, .down)
        XCTAssertEqual(cursorHit, B1)
        let cursor = pane.model.cursor
        press(.enter)
        XCTAssertEqual(host.lastOrNone.intent, .openAlbum(B1))
        XCTAssertEqual(pane.model.cursor, cursor)
        XCTAssertNil(pane.model.artist, "an album drill is the host's level, not the pane's")
    }

    func testEnterOnASongPlaysIt() {
        onResults()
        press(.end, .enter)
        XCTAssertEqual(host.lastOrNone.intent, .playSong(S1))
    }

    func testPPlaysAnAlbumAndDoesNothingOnAnArtistOrASong() {
        onResults()
        press(.char("p"))
        XCTAssertEqual(host.intents, [.search("kid a")], "p on an artist emits nothing")
        press(.end, .char("p"))
        XCTAssertEqual(host.intents, [.search("kid a")], "p on a song emits nothing")
        press(.up)
        XCTAssertEqual(cursorHit, B3)
        press(.char("p"))
        XCTAssertEqual(host.lastOrNone.intent, .playAlbum(B3))
    }

    func testRightDrillsAnArtistOrAnAlbumAndNeverPlays() {
        onResults()
        press(.right)
        XCTAssertEqual(host.lastOrNone.intent, .openArtist(A1))
        press(.escape)           // pop the artist level
        press(.down, .down, .right)
        XCTAssertEqual(host.lastOrNone.intent, .openAlbum(B1))
        press(.end, .right, .char("l"))
        for i in host.intents {
            switch i {
            case .playSong, .playAlbum: XCTFail("→ played: \(i)")
            default: break
            }
        }
        XCTAssertEqual(host.lastOrNone.intent, .openAlbum(B1), "→ on a song emitted nothing")
    }

    func testRIsInertOnResultsAndOnTheArtistLevel() {
        onResults()
        let n = host.emitted.count
        XCTAssertEqual(pane.handle(.char("r")), .none)
        press(.enter)   // artist level
        let m = host.emitted.count
        XCTAssertEqual(m, n + 1)
        XCTAssertEqual(pane.handle(.char("r")), .none)
        XCTAssertEqual(host.emitted.count, m)
        XCTAssertFalse(pane.isEditing)
    }

    // MARK: back chain

    func testEscAndLeftOnResultsClose() {
        onResults()
        press(.escape)
        XCTAssertEqual(host.lastOrNone.intent, .close)
        host.emitted.removeAll()
        press(.left)
        XCTAssertEqual(host.lastOrNone.intent, .close)
        host.emitted.removeAll()
        press(.char("h"))
        XCTAssertEqual(host.lastOrNone.intent, .close)
    }

    func testEscOnTheArtistLevelPopsToResultsWithTheOldCursorAndEmitsNothing() {
        onResults()
        press(.down)
        XCTAssertEqual(cursorHit, A2)
        press(.enter)
        let id = host.lastOrNone.id
        pane.didReceive(albums: ArtistAlbums(albums: [B1, B2], more: false), requestID: id)
        press(.down)
        XCTAssertEqual(cursorHit, B2)
        let n = host.emitted.count
        press(.escape)
        XCTAssertEqual(host.emitted.count, n, "popping a level emits nothing")
        XCTAssertNil(pane.model.artist)
        XCTAssertEqual(cursorHit, A2, "the results level kept its own cursor")
        press(.left)
        XCTAssertEqual(host.lastOrNone.intent, .close, "← from results closes")
    }

    func testTheArtistLevelHasItsOwnCursorAndOpensAlbums() {
        onResults()
        press(.enter)
        pane.didReceive(albums: ArtistAlbums(albums: [B1, B2, B3], more: false), requestID: host.lastOrNone.id)
        XCTAssertEqual(pane.model.rows, [.hit(B1), .hit(B2), .hit(B3)])
        XCTAssertEqual(cursorHit, B1)
        press(.down, .down, .enter)
        XCTAssertEqual(host.lastOrNone.intent, .openAlbum(B3))
        press(.char("p"))
        XCTAssertEqual(host.lastOrNone.intent, .playAlbum(B3))
        press(.up, .right)
        XCTAssertEqual(host.lastOrNone.intent, .openAlbum(B2))
        XCTAssertEqual(pane.model.cursor, 1)
    }

    func testSlashIsInertOnTheArtistLevel() {
        onResults()
        press(.enter)
        press(.char("/"))
        XCTAssertFalse(pane.isEditing)
    }

    // MARK: request ids

    func testAnOlderSearchAnswerNeverOverwritesANewerOne() {
        let first = search("kid")
        press(.char("/"))            // search again before the first answer lands
        type(" a")
        press(.enter)
        let second = host.lastOrNone.id
        XCTAssertGreaterThan(second, first)

        XCTAssertFalse(pane.didReceive(results: fullResults(), requestID: first), "the older id is dropped")
        XCTAssertNil(pane.model.results)

        let newer = CatalogueSearchResults(artists: [], albums: [B1], songs: [],
                                           artistsServed: false, artistsNote: nil)
        XCTAssertTrue(pane.didReceive(results: newer, requestID: second))
        XCTAssertEqual(pane.model.rows, [.header("Albums"), .hit(B1)])

        XCTAssertFalse(pane.didReceive(results: fullResults(), requestID: first), "late and older: still dropped")
        XCTAssertFalse(pane.didReceive(results: fullResults(), requestID: second), "a duplicate answer is dropped")
        XCTAssertEqual(pane.model.rows, [.header("Albums"), .hit(B1)])
    }

    func testBackDuringAPendingSearchDropsTheLateResult() {
        let id = search("kid a")
        press(.escape)
        XCTAssertEqual(host.lastOrNone.intent, .close)
        XCTAssertFalse(pane.didReceive(results: fullResults(), requestID: id))
        XCTAssertNil(pane.model.results)
        XCTAssertFalse(pane.didFail("boom", requestID: id))
        XCTAssertNil(pane.model.failure)
    }

    func testBackDuringAPendingArtistReadDropsTheLateAlbums() {
        onResults()
        press(.enter)
        let id = host.lastOrNone.id
        press(.escape)
        XCTAssertNil(pane.model.artist)
        XCTAssertFalse(pane.didReceive(albums: ArtistAlbums(albums: [B1], more: false), requestID: id))
        XCTAssertNil(pane.model.artistAlbums)
        XCTAssertEqual(pane.model.rows.count, 9, "still the results level")
        // A different artist opened afterwards is answered by its own id only.
        press(.down, .enter)
        let id2 = host.lastOrNone.id
        XCTAssertGreaterThan(id2, id)
        XCTAssertFalse(pane.didReceive(albums: ArtistAlbums(albums: [B1], more: false), requestID: id))
        XCTAssertTrue(pane.didReceive(albums: ArtistAlbums(albums: [B2], more: false), requestID: id2))
        XCTAssertEqual(pane.model.rows, [.hit(B2)])
    }

    func testAnArtistAnswerForALevelThatIsNotOnScreenIsDropped() {
        onResults()
        press(.enter)
        let id = host.lastOrNone.id
        press(.escape)
        press(.char("/"))
        type("x")
        press(.enter)
        XCTAssertFalse(pane.didReceive(albums: ArtistAlbums(albums: [B1], more: false), requestID: id))
        XCTAssertNil(pane.model.artist)
    }

    func testASearchFailureShowsItsMessageAndAStaleOneIsDropped() {
        let first = search("a")
        press(.char("/"))
        press(.enter)
        let second = host.lastOrNone.id
        XCTAssertFalse(pane.didFail("old failure", requestID: first))
        XCTAssertNil(pane.model.failure)
        XCTAssertTrue(pane.didFail("Search needs SpanDAC on this Mac.", requestID: second))
        XCTAssertEqual(pane.model.note, "Search needs SpanDAC on this Mac.")
        XCTAssertEqual(pane.model.rows, [])
        // The box stays usable: / reopens, Esc comes back to the failure, Esc again closes.
        press(.char("/"))
        XCTAssertTrue(pane.isEditing)
        press(.escape)
        XCTAssertFalse(pane.isEditing)
        XCTAssertEqual(pane.model.note, "Search needs SpanDAC on this Mac.")
        press(.escape)
        XCTAssertEqual(host.lastOrNone.intent, .close)
    }

    func testAnArtistReadFailureShowsItsMessageOnThatLevelOnly() {
        onResults()
        press(.enter)
        XCTAssertTrue(pane.didFail("That artist isn't in Apple Music's catalogue.", requestID: host.lastOrNone.id))
        XCTAssertEqual(pane.model.note, "That artist isn't in Apple Music's catalogue.")
        press(.escape)
        XCTAssertEqual(pane.model.rows.count, 9, "the results level is untouched")
        XCTAssertNotEqual(pane.model.note, "That artist isn't in Apple Music's catalogue.")
    }

    // MARK: notes

    func testTheArtistsNoteShowsWhenArtistsWereNotServed() {
        onResults(CatalogueSearchResults(artists: [], albums: [B1], songs: [S1], artistsServed: false,
                                         artistsNote: CatalogueSearchResults.artistsNeedNewerSpanDAC))
        XCTAssertEqual(pane.model.note, "Artists need a newer SpanDAC on this Mac.")
        XCTAssertEqual(pane.model.rows, [.header("Albums"), .hit(B1), .header("Songs"), .hit(S1)])
    }

    func testNoResultsAndTheArtistsNoteBothShow() {
        onResults(CatalogueSearchResults(artists: [], albums: [], songs: [], artistsServed: false,
                                         artistsNote: CatalogueSearchResults.artistsCouldNotCheck))
        XCTAssertEqual(pane.model.note,
                       "No results for “kid a”. Couldn't check SpanDAC for artist search.")
    }

    func testNoNoteWhenResultsAreFullAndArtistsServed() {
        onResults()
        XCTAssertNil(pane.model.note)
    }

    func testTheArtistLevelSaysFirst25AlbumsWhenThereAreMore() {
        onResults()
        press(.enter)
        XCTAssertEqual(pane.model.note, "Loading albums…")
        pane.didReceive(albums: ArtistAlbums(albums: [B1], more: true), requestID: host.lastOrNone.id)
        XCTAssertEqual(pane.model.note, "First 25 albums.")
    }

    func testTheArtistLevelSaysNoAlbumsForAnEmptyArtist() {
        onResults()
        press(.enter)
        pane.didReceive(albums: ArtistAlbums(albums: [], more: false), requestID: host.lastOrNone.id)
        XCTAssertEqual(pane.model.note, "No albums for Radiohead.")
        XCTAssertNil(cursorHit)
        press(.enter, .char("p"), .right)
        XCTAssertEqual(host.lastOrNone.intent, .openArtist(A1), "nothing more was emitted")
    }

    func testAFullArtistPageHasNoNote() {
        onResults()
        press(.enter)
        pane.didReceive(albums: ArtistAlbums(albums: [B1, B2], more: false), requestID: host.lastOrNone.id)
        XCTAssertNil(pane.model.note)
    }

    // MARK: isEditing mirrors the host's capturesAllInput

    func testIsEditingIsTrueOnlyWhileTheBoxIsOpen() {
        XCTAssertTrue(pane.isEditing)
        search("kid a")
        XCTAssertFalse(pane.isEditing, "searching is not editing")
        pane.didReceive(results: fullResults(), requestID: host.lastOrNone.id)
        XCTAssertFalse(pane.isEditing)
        press(.char("/"))
        XCTAssertTrue(pane.isEditing)
        press(.escape)
        XCTAssertFalse(pane.isEditing)
        press(.enter)   // artist level
        XCTAssertFalse(pane.isEditing)
        press(.escape, .escape)
        XCTAssertFalse(pane.isEditing, "closing leaves editing false")
    }

    func testOnResultsLettersAreNotTypedIntoTheBox() {
        onResults()
        press(.char("q"), .char("x"), .space)
        XCTAssertEqual(pane.model.text, "kid a")
        XCTAssertFalse(pane.isEditing)
    }

    // MARK: render

    /// Padded so a short or empty layout fails an assertion instead of trapping.
    private func padded(_ lines: [CatalogueSearchPane.Line]) -> [CatalogueSearchPane.Line] {
        lines + Array(repeating: .init(text: "<missing line>", style: .row), count: max(0, 14 - lines.count))
    }
    private func plain(_ w: Int, _ h: Int) -> [String] { padded(pane.layout(width: w, height: h)).map(\.text) }

    func testTheBoxIsOneLineAtTheTopWithACaretWhileEditing() {
        type("kid a")
        let lines = plain(60, 12)
        XCTAssertEqual(lines[0], "Search Apple Music: kid a▏")
        XCTAssertEqual(padded(pane.layout(width: 60, height: 12))[0].style, .box)
    }

    func testTheCaretGoesWhenNotEditingAndTheLastTermStays() {
        onResults()
        XCTAssertEqual(plain(60, 12)[0], "Search Apple Music: kid a")
    }

    func testGroupedRowsRenderBelowTheNoteLineWithAMarkerOnTheCursorRow() {
        onResults()
        let l = padded(pane.layout(width: 60, height: 12))
        XCTAssertEqual(l[1].style, .note)
        XCTAssertEqual(l[1].text, "")
        XCTAssertEqual(l[2], .init(text: "Artists", style: .header))
        XCTAssertEqual(l[3].style, .selected)
        XCTAssertTrue(l[3].text.hasPrefix("▸ Radiohead"))
        XCTAssertEqual(l[4].style, .row)
        XCTAssertTrue(l[4].text.hasPrefix("  Radio Dept."))
        XCTAssertEqual(l[5], .init(text: "Albums", style: .header))
        XCTAssertTrue(l[6].text.contains("Kid A"))
        XCTAssertTrue(l[6].text.contains("Radiohead"), "an album row carries its credit line")
        XCTAssertTrue(l.contains { $0.text.contains("Idioteque") })
    }

    func testAnEmptyGroupLeavesNoHeader() {
        onResults(CatalogueSearchResults(artists: [], albums: [B1], songs: [], artistsServed: false,
                                         artistsNote: nil))
        let texts = plain(60, 12)
        XCTAssertFalse(texts.contains("Artists"))
        XCTAssertFalse(texts.contains("Songs"))
        XCTAssertTrue(texts.contains("Albums"))
    }

    func testTheNoteRendersOnTheSecondLine() {
        search("kid a")
        XCTAssertEqual(plain(60, 12)[1], "Searching “kid a”…")
    }

    func testNoLineIsWiderThanTheWidthAndLongTitlesGetAnEllipsis() {
        let long = album("alx", String(repeating: "Very Long Album Title ", count: 6), "Radiohead")
        onResults(CatalogueSearchResults(artists: [A1], albums: [long], songs: [S1],
                                         artistsServed: true, artistsNote: nil))
        for w in [12, 20, 40] {
            let lines = pane.layout(width: w, height: 12).map(\.text)
            XCTAssertFalse(lines.isEmpty)
            for line in lines { XCTAssertLessThanOrEqual(line.count, w, "width \(w): \(line)") }
        }
        XCTAssertTrue(plain(30, 12).contains { $0.hasSuffix("…") })
    }

    func testALongQueryKeepsTheCaretVisibleByDroppingTheFront() {
        type(String(repeating: "abcdefghij", count: 6))
        let box = plain(30, 12)[0]
        XCTAssertLessThanOrEqual(box.count, 30)
        XCTAssertTrue(box.hasSuffix("ghij▏"))
        XCTAssertTrue(box.hasPrefix("Search Apple Music: "))
    }

    func testTheListNeverExceedsTheHeightAndKeepsTheCursorRowVisible() {
        onResults()
        press(.end)
        let lines = pane.layout(width: 60, height: 5)
        XCTAssertLessThanOrEqual(lines.count, 5)
        XCTAssertTrue(lines.contains { $0.style == .selected && $0.text.contains("Idioteque") })
        XCTAssertEqual(lines.first?.style, .box, "the box stays on top")
    }

    func testRenderPlacesTheBoxOnTheBodysFirstRow() {
        type("kid")
        let frame = shellLayout(width: 80, height: 30)
        let out = pane.render(frame: frame)
        XCTAssertTrue(out.contains(ANSICode.moveTo(row: frame.bodyY, col: 1)))
        XCTAssertTrue(out.contains("Search Apple Music: "))
        XCTAssertTrue(out.contains("kid"))
        XCTAssertTrue(out.contains("▏"))
    }
}
