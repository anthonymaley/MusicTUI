import XCTest
@testable import music

/// Re-resolving the row a catalog add just created.
///
/// Anthony, 2026-09-03: "the retry must identify the newly added catalog song
/// using every stable attribute available, not merely its name, and fail closed
/// if multiple library rows remain plausible. Once resolved, carry that
/// persistent ID forward without another name lookup."
final class CatalogRowResolutionTests: XCTestCase {

    private func row(_ pid: String, _ name: String, _ artist: String, _ album: String = "A")
        -> LibraryRowIdentity {
        LibraryRowIdentity(persistentID: pid, name: name, artist: artist, album: album)
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
        XCTAssertEqual(out, .resolved(persistentID: "NEW1"))
        XCTAssertEqual(waits, 0, "it resolved on the first look, so it must not sleep")
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
        XCTAssertEqual(out, .resolved(persistentID: "N2"))
    }

    func testAlbumSeparatesTwoNewRowsSharingTitleAndArtist() {
        let out = resolveAddedCatalogRow(
            title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
            idsBefore: [],
            readRows: { [self.row("N1", "Teardrop", "Massive Attack", "Singles"),
                         self.row("N2", "Teardrop", "Massive Attack", "Mezzanine")] },
            wait: { _ in })
        XCTAssertEqual(out, .resolved(persistentID: "N2"))
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
        XCTAssertEqual(out, .ambiguous(count: 2))
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
        XCTAssertEqual(out, .resolved(persistentID: "NEW1"))
        XCTAssertEqual(look, 4)
        XCTAssertEqual(waits, 3, "one wait between each look, none after the last")
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
        XCTAssertNil(catalogRowResolutionMessage(.resolved(persistentID: "X"), title: "T"))
        let notYet = catalogRowResolutionMessage(.notYetVisible(attempts: 20), title: "T") ?? ""
        let ambiguous = catalogRowResolutionMessage(.ambiguous(count: 2), title: "T") ?? ""
        XCTAssertNotEqual(notYet, ambiguous)
        // The add already happened, so both must say so rather than implying
        // nothing changed.
        XCTAssertTrue(notYet.contains("Added"))
        XCTAssertTrue(ambiguous.contains("Added"))
        XCTAssertTrue(notYet.contains("nothing was played"))
        XCTAssertTrue(ambiguous.contains("nothing was played"))
    }
}
