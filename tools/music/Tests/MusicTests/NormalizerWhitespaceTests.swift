// tools/music/Tests/MusicTests/NormalizerWhitespaceTests.swift
import XCTest
@testable import music

/// Whitespace folding across the three split-based normalizers.
///
/// Premise measured 2026-09-02: `normalizeCredit` and `normalizeAlbumTitle`
/// split on exactly `" "`, `"\t"`, `"\n"`, so any other Unicode space survives
/// internally; `normalizeArtist` only trimmed and never collapsed internal
/// runs at all. `QueueResume`'s private regex normalizer already used `\s+`
/// and is deliberately NOT touched here.
///
/// Anthony, 2026-09-03: treat every `Character.isWhitespace` character as
/// intentionally equivalent, not NBSP as a one-off repair. The implementation
/// delegates to `Character.isWhitespace`, so the whole class is covered by
/// construction; the cases below SAMPLE ten representatives of it rather than
/// enumerating every scalar, which is why the sweeping test is named for
/// representatives. (Codex, 2026-09-03: the earlier name and comment claimed
/// exhaustive coverage the cases do not provide.)
///
/// MEASURED BOUNDARY, so nobody "completes" this later by stripping format
/// characters. On this runtime `Character.isWhitespace` and
/// `NSRegularExpression`'s `\s` agree exactly, including that
/// U+200B ZERO WIDTH SPACE, U+2060 WORD JOINER, U+FEFF ZERO WIDTH NO-BREAK
/// SPACE and U+180E are whitespace in NEITHER. U+FEFF is the trap: its name
/// says space, Unicode does not classify it as one. Pinned negatively below.
final class NormalizerWhitespaceTests: XCTestCase {

    /// One representative per Unicode whitespace family that can realistically
    /// appear in music metadata, plus the three the old predicate already knew.
    private static let separators: [(String, String)] = [
        ("\u{0020}", "ASCII space"),
        ("\u{0009}", "tab"),
        ("\u{000A}", "newline"),
        ("\u{000D}", "carriage return"),
        ("\u{00A0}", "no-break space"),
        ("\u{2002}", "en space"),
        ("\u{2003}", "em space"),
        ("\u{2009}", "thin space"),
        ("\u{202F}", "narrow no-break space"),
        ("\u{3000}", "ideographic space"),
    ]

    /// Every sampled separator folds to a single ASCII space, in all three.
    /// Ten representatives, not the full White_Space list: the implementation
    /// delegates to `Character.isWhitespace`, so the class is covered by
    /// construction and this pins that the delegation is actually in place.
    func testRepresentativeUnicodeWhitespaceFoldsIdenticallyInAllThreeNormalizers() {
        for (sep, label) in Self.separators {
            XCTAssertEqual(normalizeCredit("Aphex\(sep)Twin"), "aphex twin",
                           "normalizeCredit did not fold \(label)")
            XCTAssertEqual(normalizeAlbumTitle("Selected\(sep)Ambient"), "selected ambient",
                           "normalizeAlbumTitle did not fold \(label)")
            XCTAssertEqual(normalizeArtist("Aphex\(sep)Twin"), "aphex twin",
                           "normalizeArtist did not fold \(label)")
        }
    }

    /// A run of MIXED separators collapses to one space, and leading/trailing
    /// runs vanish. This is the case that distinguishes "split on a wider set"
    /// from "replace one character".
    func testMixedWhitespaceRunsCollapseAndEdgesAreTrimmed() {
        let messy = "\u{00A0} \u{2003}A\u{00A0}\u{2003} Tribe\t\u{3000}Called\u{000D}\u{000A}Quest \u{00A0}"
        XCTAssertEqual(normalizeCredit(messy), "a tribe called quest")
        XCTAssertEqual(normalizeAlbumTitle(messy), "a tribe called quest")
        XCTAssertEqual(normalizeArtist(messy), "a tribe called quest")
    }

    /// AXIS 1 from the 2026-09-02 measurement: `normalizeArtist` alone did not
    /// collapse internal runs, so the double-spaced form failed to match the
    /// single-spaced one and the two grouped as different artists.
    func testNormalizeArtistCollapsesInternalRunsLikeTheOtherTwo() {
        XCTAssertEqual(normalizeArtist("A  Tribe  Called  Quest"), "a tribe called quest")
        XCTAssertEqual(normalizeArtist("A Tribe Called Quest"),
                       normalizeArtist("A  Tribe  Called  Quest"))
    }

    // MARK: - §19 must be otherwise unchanged

    /// PUNCTUATION ASYMMETRY, and it is deliberate. `normalizeCredit` folds
    /// `&` and `,` because a multi-artist credit string is punctuated
    /// inconsistently by the metadata; `normalizeAlbumTitle` does NOT, because
    /// an album title's punctuation ("Rock & Roll") is part of its identity.
    /// Widening the whitespace class must not disturb either half.
    func testPunctuationAsymmetrySurvives() {
        XCTAssertEqual(normalizeCredit("Floating Points, San Francisco Ballet Orchestra"),
                       normalizeCredit("Floating Points & San Francisco Ballet Orchestra"))
        XCTAssertNotEqual(normalizeAlbumTitle("Rock & Roll"), normalizeAlbumTitle("Rock Roll"))
        XCTAssertNotEqual(normalizeAlbumTitle("Rock, Roll"), normalizeAlbumTitle("Rock Roll"))
        XCTAssertEqual(normalizeAlbumTitle("Rock & Roll"), "rock & roll")
    }

    /// MULTIPLICITY, the §19.3 lesson. Set equality was proposed as the
    /// credit-compatibility rule and rejected because a set collapses
    /// repetition: "duran duran" and "duran" are set-equal, and Duran Duran,
    /// Xiu Xiu and Talk Talk are all real. The rule is literal string equality
    /// on the normalised forms, so repetition must survive normalisation.
    func testMultiplicityIsPreserved() {
        XCTAssertNotEqual(normalizeCredit("Duran Duran"), normalizeCredit("Duran"))
        XCTAssertEqual(normalizeCredit("Duran Duran"), "duran duran")
        XCTAssertNotEqual(normalizeCredit("Talk Talk"), normalizeCredit("Talk"))
        XCTAssertNotEqual(normalizeArtist("Xiu Xiu"), normalizeArtist("Xiu"))
    }

    /// CANONICAL EQUIVALENCE, measured 2026-09-02 and pinned here because the
    /// whitespace work sits next to it and could be mistaken for touching it.
    /// Swift's `String ==` is canonical-equivalence-aware, so NFC and NFD forms
    /// already compare equal and no decomposition step is needed or wanted.
    func testCanonicalUnicodeEquivalenceStillHolds() {
        let nfc = "Bj\u{00F6}rk"              // ö as one scalar
        let nfd = "Bjo\u{0308}rk"             // o + combining diaeresis
        XCTAssertEqual(normalizeCredit(nfc), normalizeCredit(nfd))
        XCTAssertEqual(normalizeAlbumTitle(nfc), normalizeAlbumTitle(nfd))
        XCTAssertEqual(normalizeArtist(nfc), normalizeArtist(nfd))
    }

    /// THE NEGATIVE BOUNDARY, and the one most likely to be "fixed" wrongly
    /// later. Zero-width characters are NOT whitespace in Unicode, so they are
    /// deliberately NOT folded: U+FEFF is named zero-width no-break SPACE and
    /// is still not one. Codex measured that `Character.isWhitespace` and the
    /// regex `\s` used by `QueueResume` agree on this, so widening the class
    /// introduced no new divergence between them.
    ///
    /// A name carrying one of these will still fail to match, and that is the
    /// documented state, not an oversight. Stripping format characters is a
    /// different decision with a different blast radius and is not this task.
    func testZeroWidthCharactersAreNotFolded() {
        for zw in ["\u{200B}", "\u{2060}", "\u{FEFF}"] {
            XCTAssertNotEqual(normalizeCredit("Aphex\(zw)Twin"), "aphex twin",
                              "zero-width U+\(String(zw.unicodeScalars.first!.value, radix: 16)) must not fold")
            XCTAssertEqual(normalizeCredit("Aphex\(zw)Twin"), "aphex\(zw)twin")
            XCTAssertNotEqual(normalizeArtist("Aphex\(zw)Twin"), "aphex twin")
            XCTAssertNotEqual(normalizeAlbumTitle("Selected\(zw)Ambient"), "selected ambient")
        }
    }

    /// A non-breaking space is NOT whitespace-adjacent punctuation: folding it
    /// must not also fold the `&` that `normalizeAlbumTitle` protects.
    func testFoldingWhitespaceDoesNotSmuggleInPunctuationFolding() {
        XCTAssertEqual(normalizeAlbumTitle("Rock\u{00A0}&\u{00A0}Roll"), "rock & roll")
    }
}
