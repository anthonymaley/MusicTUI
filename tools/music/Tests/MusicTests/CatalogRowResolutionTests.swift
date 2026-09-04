import XCTest
@testable import music

/// Re-resolving the row a catalog add just created.
///
/// Anthony, 2026-09-03: "the retry must identify the newly added catalog song
/// using every stable attribute available, not merely its name, and fail closed
/// if multiple library rows remain plausible. Once resolved, carry that
/// persistent ID forward without another name lookup."
final class CatalogRowResolutionTests: XCTestCase {

    private func row(_ pid: String, _ name: String, _ artist: String, _ album: String = "A",
                     _ cloud: String = "subscribed") -> LibraryRowIdentity {
        LibraryRowIdentity(persistentID: pid, name: name, artist: artist, album: album,
                           cloudStatus: cloud)
    }

    private var existing: LibraryRowIdentity {
        row("OLD1", "Teardrop", "Massive Attack")
    }

    // MARK: - Identity beats name

    /// The user already owns a track with the same name and artist. The add
    /// created a second one. Matching on attributes alone would see two rows
    /// and refuse; the set difference sees only the new one.
    func testAPreExistingCopyOfTheSameSongIsNotAmbiguity() {
        var waits = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "A",
            idsBefore: ["OLD1"],
            readRows: { [self.existing, self.row("NEW1", "Teardrop", "Massive Attack")] },
            wait: { _ in waits += 1 })
        XCTAssertEqual(out, .resolved(persistentID: "NEW1", viaPreExisting: false))
        // Two consecutive sightings are required now, so exactly one wait.
        XCTAssertEqual(waits, 1, "one wait between the two confirming observations, no more")
    }

    // MARK: - Name alone is not enough

    /// Two NEW rows share the title. Only the artist separates them, which is
    /// the case a name-only match would get wrong rather than refuse.
    func testArtistSeparatesTwoNewRowsSharingATitle() {
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "A",
            idsBefore: [],
            readRows: { [self.row("N1", "Teardrop", "Newton Faulkner"),
                         self.row("N2", "Teardrop", "Massive Attack")] },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "N2", viaPreExisting: false))
    }

    func testAlbumSeparatesTwoNewRowsSharingTitleAndArtist() {
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [],
            readRows: { [self.row("N1", "Teardrop", "Massive Attack", "Singles"),
                         self.row("N2", "Teardrop", "Massive Attack", "Mezzanine")] },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "N2", viaPreExisting: false))
    }

    // MARK: - Fail closed on real ambiguity

    func testTwoIndistinguishableNewRowsRefuseRatherThanGuess() {
        var waits = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [],
            readRows: { [self.row("N1", "Teardrop", "Massive Attack", "Mezzanine"),
                         self.row("N2", "Teardrop", "Massive Attack", "Mezzanine")] },
            wait: { _ in waits += 1 })
        XCTAssertEqual(out, .ambiguous(count: 2, amongPreExisting: false))
        XCTAssertEqual(waits, 0, "waiting cannot disambiguate what is already ambiguous")
    }

    // MARK: - The retry, and what replaced the fixed sleep

    /// The measured shape: nothing at all for the first few looks, then the row
    /// appears. A fixed sleep either wastes time or gives up too early; the
    /// retry returns the moment it can.
    func testItPollsUntilTheRowAppearsAndThenStopsImmediately() {
        var look = 0
        var waits = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "A",
            idsBefore: [],
            readRows: {
                look += 1
                return look < 4 ? [] : [self.row("NEW1", "Teardrop", "Massive Attack")]
            },
            wait: { _ in waits += 1 })
        XCTAssertEqual(out, .resolved(persistentID: "NEW1", viaPreExisting: false))
        XCTAssertEqual(look, 5, "the fourth look sees it, the fifth confirms it")
        XCTAssertEqual(waits, 4)
    }

    func testItGivesUpHonestlyRatherThanPlayingSomethingElse() {
        var waits = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "A",
            idsBefore: [], attempts: 5,
            readRows: { [] },
            wait: { _ in waits += 1 })
        XCTAssertEqual(out, .notYetVisible(attempts: 5))
        XCTAssertEqual(waits, 4)
    }

    // MARK: - Messages

    func testEachUnresolvedStateSaysWhatHappenedToTheLibrary() {
        XCTAssertNil(catalogRowResolutionMessage(.resolved(persistentID: "X", viaPreExisting: false), title: "T"))
        let notYet = catalogRowResolutionMessage(.notYetVisible(attempts: 20), title: "T") ?? ""
        let ambiguous = catalogRowResolutionMessage(.ambiguous(count: 2, amongPreExisting: false), title: "T") ?? ""
        XCTAssertNotEqual(notYet, ambiguous)
        // The add already happened, so both must say so rather than implying
        // nothing changed.
        XCTAssertTrue(notYet.contains("Added"))
        XCTAssertTrue(ambiguous.contains("Added"))
        XCTAssertTrue(notYet.contains("nothing was played"))
        XCTAssertTrue(ambiguous.contains("nothing was played"))
    }
}

/// Reproductions of the two Important findings from Codex's review of
/// fcda0cf..d157c53. Written to FAIL against the code as reviewed, so the
/// defects are demonstrated rather than argued.
extension CatalogRowResolutionTests {

    /// Important 1, fixed (Anthony, 2026-09-04): an idempotent add. The song is
    /// already in the library, so `addToLibrary` creates no new row and the set
    /// difference stays empty. After the budget, a unique PLAYABLE metadata
    /// match is played, and the caller says out loud that this was metadata
    /// resolution rather than catalog identity.
    func testAnIdempotentAddPlaysTheRowTheUserAlreadyOwns() {
        let owned = row("OWNED", "Teardrop", "Massive Attack", "Mezzanine")
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["OWNED"], attempts: 3,
            readRows: { [owned] },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "OWNED", viaPreExisting: true))
        XCTAssertTrue(preExistingResolutionNote(title: "Teardrop").contains("rather than"),
                      "the weaker claim must be stated, not implied")
    }

    func testAnUnplayablePreExistingRowIsNotPlayed() {
        let owned = row("OWNED", "Teardrop", "Massive Attack", "Mezzanine", "prerelease")
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["OWNED"], attempts: 2,
            readRows: { [owned] },
            wait: { _ in })
        XCTAssertEqual(out, .notYetVisible(attempts: 2),
                       "a pre-release row satisfies every metadata check and then silently no-ops")
    }

    func testTwoIndistinguishablePreExistingRowsRefuse() {
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["O1", "O2"], attempts: 2,
            readRows: { [self.row("O1", "Teardrop", "Massive Attack", "Mezzanine"),
                         self.row("O2", "Teardrop", "Massive Attack", "Mezzanine")] },
            wait: { _ in })
        XCTAssertEqual(out, .ambiguous(count: 2, amongPreExisting: true))
    }

    /// The two-observation rule, and what it does and does not buy. A candidate
    /// that appears once and is gone on the next look is not played.
    func testACandidateThatDoesNotSurviveASecondLookIsNotPlayed() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [], attempts: 3,
            readRows: {
                look += 1
                return look == 1 ? [self.row("GHOST", "Teardrop", "Massive Attack", "Mezzanine")] : []
            },
            wait: { _ in })
        XCTAssertEqual(out, .notYetVisible(attempts: 3))
    }

    /// Important 2, fixed: an unreadable library is its own state, never an
    /// empty one. The repo's recorded "unknown is never nothing" class
    /// (CONTEXT, §20.6), which Codex found this code had reproduced.
    ///
    /// The caller-side half of the same fix is that a baseline which cannot be
    /// read refuses BEFORE the irreversible add, so the empty-set case this
    /// test used to exercise can no longer be constructed by the live path.
    func testAnUnreadableLibraryIsNotAnEmptyOne() {
        var waits = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["OWNED"], attempts: 3,
            readRows: { nil },
            wait: { _ in waits += 1 })
        XCTAssertEqual(out, .unreadable)
        XCTAssertNotEqual(out, .notYetVisible(attempts: 3),
                          "not knowing what is there is not the same as knowing nothing arrived")
        XCTAssertEqual(waits, 2, "it keeps looking rather than giving up on the first failure")
    }

    /// A read that fails once and then succeeds must still resolve. A transient
    /// AppleScript failure is not a verdict.
    func testATransientReadFailureDoesNotEndTheSearch() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["OWNED"], attempts: 5,
            readRows: {
                look += 1
                if look < 3 { return nil }
                return [self.row("OWNED", "Teardrop", "Massive Attack", "Mezzanine"),
                        self.row("NEW1", "Teardrop", "Massive Attack", "Mezzanine")]
            },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "NEW1", viaPreExisting: false))
    }
}
