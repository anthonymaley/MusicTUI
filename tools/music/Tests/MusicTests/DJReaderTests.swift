// tools/music/Tests/MusicTests/DJReaderTests.swift
//
// The DJ reader: card validation, the defence-in-depth phrase guard, and the
// mapping of every unavailable state. Nothing here touches the real model:
// the Apple backend is replaced by a scripted one, so these tests prove the
// APP's handling of what a model might return, not what the model returns.
import XCTest
@testable import music

private final class ScriptedBackend: DJModelBackend, @unchecked Sendable {
    var availability: DJUnavailable?
    var result: Result<DJRawCard, DJBackendError>
    private(set) var promptsSeen: [String] = []

    init(availability: DJUnavailable? = nil, result: Result<DJRawCard, DJBackendError>) {
        self.availability = availability
        self.result = result
    }

    func currentAvailability() -> DJUnavailable? { availability }

    func classify(_ prompt: String) async throws -> DJRawCard {
        promptsSeen.append(prompt)
        return try result.get()
    }
}

final class DJReaderTests: XCTestCase {
    private func read(_ prompt: String, returning card: DJRawCard) async -> (DJReading, ScriptedBackend) {
        let backend = ScriptedBackend(result: .success(card))
        let reading = await DJBackedReader(backend: backend).read(prompt)
        return (reading, backend)
    }

    private func unsupported() -> DJReading { .card(DJCard(kind: .unsupported, artist: nil, genre: nil)) }

    // MARK: - validation of returned cards

    func testWellFormedArtistMixPasses() async {
        let (r, _) = await read("a mix of radiohead albums",
                                returning: DJRawCard(kind: "artistMix", artist: "Radiohead", genre: nil))
        XCTAssertEqual(r, .card(DJCard(kind: .artistMix, artist: "Radiohead", genre: nil)))
    }

    func testWellFormedGenreUnheardPasses() async {
        let (r, _) = await read("cool jazz i haven't heard in a while",
                                returning: DJRawCard(kind: "genreUnheard", artist: nil, genre: "Jazz"))
        XCTAssertEqual(r, .card(DJCard(kind: .genreUnheard, artist: nil, genre: "Jazz")))
    }

    func testFieldsAreTrimmed() async {
        let (r, _) = await read("radiohead albums",
                                returning: DJRawCard(kind: "artistMix", artist: "  Radiohead \n", genre: nil))
        XCTAssertEqual(r, .card(DJCard(kind: .artistMix, artist: "Radiohead", genre: nil)))
    }

    func testIrrelevantFieldIsDroppedFromAKindThatDoesNotUseIt() async {
        let (a, _) = await read("radiohead albums",
                                returning: DJRawCard(kind: "artistMix", artist: "Radiohead", genre: "Rock"))
        XCTAssertEqual(a, .card(DJCard(kind: .artistMix, artist: "Radiohead", genre: nil)))
        let (g, _) = await read("unheard jazz",
                                returning: DJRawCard(kind: "genreUnheard", artist: "Miles Davis", genre: "Jazz"))
        XCTAssertEqual(g, .card(DJCard(kind: .genreUnheard, artist: nil, genre: "Jazz")))
    }

    func testUnsupportedKindDropsEveryField() async {
        let (r, _) = await read("something odd",
                                returning: DJRawCard(kind: "unsupported", artist: "X", genre: "Y"))
        XCTAssertEqual(r, unsupported())
    }

    func testUnknownKindIsUnsupported() async {
        for kind in ["playlist", "ARTISTMIX", "", "similarArtists", " artistMix"] {
            let (r, _) = await read("radiohead albums",
                                    returning: DJRawCard(kind: kind, artist: "Radiohead", genre: "Rock"))
            XCTAssertEqual(r, unsupported(), "kind \(kind.debugDescription)")
        }
    }

    func testMissingOrEmptyArtistIsUnsupported() async {
        for artist in [nil, "", "   ", "\n\t"] as [String?] {
            let (r, _) = await read("radiohead albums",
                                    returning: DJRawCard(kind: "artistMix", artist: artist, genre: "Rock"))
            XCTAssertEqual(r, unsupported(), "artist \(String(describing: artist))")
        }
    }

    func testMissingOrEmptyGenreIsUnsupported() async {
        for genre in [nil, "", "   "] as [String?] {
            let (r, _) = await read("unheard jazz",
                                    returning: DJRawCard(kind: "genreUnheard", artist: "Miles Davis", genre: genre))
            XCTAssertEqual(r, unsupported(), "genre \(String(describing: genre))")
        }
    }

    func testOverlongFieldsAreUnsupportedAndTheBoundIsInclusive() async {
        let atBound = String(repeating: "a", count: DJCard.maxFieldLength)
        let over = String(repeating: "a", count: DJCard.maxFieldLength + 1)
        let (ok, _) = await read("x albums", returning: DJRawCard(kind: "artistMix", artist: atBound, genre: nil))
        XCTAssertEqual(ok, .card(DJCard(kind: .artistMix, artist: atBound, genre: nil)))
        let (a, _) = await read("x albums", returning: DJRawCard(kind: "artistMix", artist: over, genre: nil))
        XCTAssertEqual(a, unsupported())
        let (g, _) = await read("unheard x", returning: DJRawCard(kind: "genreUnheard", artist: nil, genre: over))
        XCTAssertEqual(g, unsupported())
    }

    func testTheBoundIsMeasuredAfterTrimming() async {
        let padded = "  " + String(repeating: "a", count: DJCard.maxFieldLength) + "  "
        let (r, _) = await read("x albums", returning: DJRawCard(kind: "artistMix", artist: padded, genre: nil))
        XCTAssertEqual(r, .card(DJCard(kind: .artistMix,
                                       artist: String(repeating: "a", count: DJCard.maxFieldLength), genre: nil)))
    }

    func testFieldsWithControlCharactersAreUnsupported() async {
        let (r, _) = await read("radiohead albums",
                                returning: DJRawCard(kind: "artistMix", artist: "Radio\u{1B}[31mhead", genre: nil))
        XCTAssertEqual(r, unsupported(), "an escape sequence in a field must never reach the screen")
    }

    // MARK: - prompt guard (before the model is asked)

    func testEmptyAndBlankPromptsAreUnsupportedWithoutAskingTheModel() async {
        for prompt in ["", "   ", "\n\t "] {
            let (r, backend) = await read(prompt,
                                          returning: DJRawCard(kind: "artistMix", artist: "Radiohead", genre: nil))
            XCTAssertEqual(r, unsupported(), "prompt \(prompt.debugDescription)")
            XCTAssertTrue(backend.promptsSeen.isEmpty)
        }
    }

    func testOverlongPromptIsUnsupportedWithoutAskingTheModel() async {
        let long = String(repeating: "jazz ", count: 200)
        let (r, backend) = await read(long, returning: DJRawCard(kind: "genreUnheard", artist: nil, genre: "Jazz"))
        XCTAssertEqual(r, unsupported())
        XCTAssertTrue(backend.promptsSeen.isEmpty)
    }

    func testThePromptReachesTheModelTrimmed() async {
        let (_, backend) = await read("  play radiohead albums \n",
                                      returning: DJRawCard(kind: "artistMix", artist: "Radiohead", genre: nil))
        XCTAssertEqual(backend.promptsSeen, ["play radiohead albums"])
    }

    // MARK: - defence in depth: similarity and negation never become an artist mix

    func testSimilarityRequestsReturnedAsACardAreUnsupported() async {
        let prompts = [
            "play music like tribe called quest",
            "something similar to Radiohead",
            "Songs like Karma Police",
            "play stuff that sounds like Daft Punk",
            "more like Massive Attack please",
            "reminds me of Portishead",
            "in the style of Bonobo",
        ]
        for p in prompts {
            let (r, backend) = await read(p, returning: DJRawCard(kind: "artistMix", artist: "Whoever", genre: nil))
            XCTAssertEqual(r, unsupported(), p)
            XCTAssertEqual(backend.promptsSeen.count, 1, "the model is still asked; the guard is after it")
        }
    }

    func testNegationsReturnedAsACardAreUnsupported() async {
        let prompts = [
            "anything but jazz",
            "everything except radiohead",
            "play music but not jazz",
            "I don't want any jazz",
            "no jazz tonight",
            "without the jazz",
        ]
        for p in prompts {
            let (r, _) = await read(p, returning: DJRawCard(kind: "genreUnheard", artist: nil, genre: "Jazz"))
            XCTAssertEqual(r, unsupported(), p)
        }
    }

    func testOrdinaryPromptsWithNegationLikeWordsInANameAreNotCaught() async {
        // Artist and genre names carry "no", "not", "like" and "but": the guard
        // is phrase-based and must not eat these.
        let cases: [(String, DJRawCard)] = [
            ("a mix of No Doubt albums", DJRawCard(kind: "artistMix", artist: "No Doubt", genre: nil)),
            ("play Nothing But Thieves albums", DJRawCard(kind: "artistMix", artist: "Nothing But Thieves", genre: nil)),
            ("a mix of Kings of Leon albums", DJRawCard(kind: "artistMix", artist: "Kings of Leon", genre: nil)),
            ("play Like a Prayer era Madonna albums", DJRawCard(kind: "artistMix", artist: "Madonna", genre: nil)),
        ]
        for (p, raw) in cases {
            let (r, _) = await read(p, returning: raw)
            guard case .card(let c) = r else { return XCTFail("\(p) -> \(r)") }
            XCTAssertEqual(c.kind, .artistMix, p)
        }
    }

    func testAnUnsupportedCardIsNeverUpgraded() async {
        let (r, _) = await read("play radiohead albums",
                                returning: DJRawCard(kind: "unsupported", artist: nil, genre: nil))
        XCTAssertEqual(r, unsupported())
    }

    // MARK: - unavailable states surface as themselves

    func testEveryUnavailableStateSurfacesAsItself() async {
        for state in DJUnavailable.allCases {
            let backend = ScriptedBackend(availability: state,
                                          result: .success(DJRawCard(kind: "artistMix", artist: "R", genre: nil)))
            let r = await DJBackedReader(backend: backend).read("radiohead albums")
            XCTAssertEqual(r, .unavailable(state))
            XCTAssertTrue(backend.promptsSeen.isEmpty, "an unavailable model is never asked (\(state))")
        }
    }

    func testBackendErrorsSurfaceAsTheirStates() async {
        let table: [(DJBackendError, DJReading)] = [
            (.unavailable(.unsupportedLanguage), .unavailable(.unsupportedLanguage)),
            (.unavailable(.modelNotReady), .unavailable(.modelNotReady)),
            (.unavailable(.appleIntelligenceOff), .unavailable(.appleIntelligenceOff)),
            (.unavailable(.notThisMac), .unavailable(.notThisMac)),
            (.unsupportedPrompt, .card(DJCard(kind: .unsupported, artist: nil, genre: nil))),
            (.failed("boom"), .failed("boom")),
        ]
        for (error, expected) in table {
            let backend = ScriptedBackend(result: .failure(error))
            let r = await DJBackedReader(backend: backend).read("radiohead albums")
            XCTAssertEqual(r, expected, "\(error)")
        }
    }

    func testTheFiveUnavailableStatesAreDistinct() {
        XCTAssertEqual(Set(DJUnavailable.allCases).count, 5)
        XCTAssertEqual(Set(DJUnavailable.allCases.map { $0.message }).count, 5, "each state has its own words")
        for s in DJUnavailable.allCases { XCTAssertFalse(s.message.isEmpty) }
    }

    // MARK: - the factory and the compiled-out reader

    func testTheBuiltWithoutDJReaderReportsItselfAndNeverReturnsACard() async {
        let r = await DJUnavailableReader(.builtWithoutDJ).read("play radiohead albums")
        XCTAssertEqual(r, .unavailable(.builtWithoutDJ))
    }

    func testTheFactoryBuildsAReaderWithoutAskingTheModel() {
        // Construction only: no read, so no model call, on any machine.
        _ = DJReaders.makeDefault()
    }

    #if !canImport(FoundationModels)
    func testWithoutFoundationModelsTheFactoryReportsBuiltWithoutDJ() async {
        let r = await DJReaders.makeDefault().read("play radiohead albums")
        XCTAssertEqual(r, .unavailable(.builtWithoutDJ))
    }
    #endif
}
