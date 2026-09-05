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
        XCTAssertEqual(waits, 5, "four between the scheduled looks, one before the final read")
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
        XCTAssertEqual(waits, 3, "it keeps looking rather than giving up on the first failure")
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

/// Codex's scoped re-review of e4f4bc5..9773068 found three orderings in the
/// fallback that select the wrong track. Each test below reproduced its finding
/// against 9773068 (failing) before the fix landed.
extension CatalogRowResolutionTests {

    /// Important 1: "pre-existing" is an identity fact the function already
    /// holds (`idsBefore`), not a metadata description. A new row seen only by
    /// the read after the budget must not be played as if it were already
    /// owned, and must not be described to the user that way.
    func testANewRowSeenOnlyByTheFinalReadIsNotPlayedAsPreExisting() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [], attempts: 2,
            readRows: {
                look += 1
                return look <= 2 ? [] : [self.row("NEW", "Teardrop", "Massive Attack", "Mezzanine")]
            },
            wait: { _ in })
        XCTAssertEqual(out, .notYetVisible(attempts: 2),
                       "one sighting is not two, and a new row is not a pre-existing one")
    }

    /// The same boundary, the legitimate way round: a row first seen on the
    /// final scheduled attempt gets exactly one confirming read rather than
    /// being starved by the budget.
    func testANewRowFirstSeenOnTheFinalAttemptGetsOneConfirmingRead() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [], attempts: 3,
            readRows: {
                look += 1
                return look < 3 ? [] : [self.row("NEW", "Teardrop", "Massive Attack", "Mezzanine")]
            },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "NEW", viaPreExisting: false))
        XCTAssertEqual(look, 4, "three scheduled looks, then one confirming read")
    }

    /// Important 2: the fallback must read the library NOW, not reuse the last
    /// read that happened to succeed. A success followed by nothing but
    /// failures is an unreadable library, and an unreadable library is not a
    /// positive selection.
    func testAStaleSuccessfulReadIsNotUsedOnceLaterReadsFail() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: ["OWNED"], attempts: 3,
            readRows: {
                look += 1
                return look == 1 ? [self.row("OWNED", "Teardrop", "Massive Attack", "Mezzanine")] : nil
            },
            wait: { _ in })
        XCTAssertEqual(out, .unreadable,
                       "the one good read is stale by the time the fallback runs")
    }

    /// Important 3: an unreadable observation is no evidence the candidate
    /// survived, so it breaks the consecutive run. Seen, unknown, seen is one
    /// sighting followed by one sighting, not two in a row.
    func testAnUnreadableObservationBreaksTheConsecutiveRun() {
        var look = 0
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [], attempts: 3,
            readRows: {
                look += 1
                switch look {
                case 1, 3: return [self.row("C", "Teardrop", "Massive Attack", "Mezzanine")]
                case 2: return nil
                default: return []
                }
            },
            wait: { _ in })
        XCTAssertEqual(out, .notYetVisible(attempts: 3),
                       "look 3 must start a new run, and the confirming read is empty")
    }

    /// The `.unreadable` message may only state what the code knows.
    func testTheUnreadableMessageClaimsOnlyWhatIsKnown() {
        let m = catalogRowResolutionMessage(.unreadable, title: "T") ?? ""
        XCTAssertFalse(m.contains("Nothing else was changed"),
                       "the add already ran; the code cannot know what it changed")
        XCTAssertTrue(m.contains("nothing was played"))
    }
}
