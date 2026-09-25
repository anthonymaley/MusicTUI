// tools/music/Sources/TUI/BridgeMusicProvider.swift
import Foundation

/// The Bridge half of the provider seam: rows and playback from the app's own
/// MusicKit library, with MusicKit ids.
///
/// **No join, and that is the point.** Until 2026-09-23 a Bridge play started
/// from an AppleScript row and Bridge looked it up by `(title, artist, album)`,
/// which left 338 of this library's rows unresolvable — 328 ambiguous, 10
/// absent (spec 5.1) — so albums and playlists refused. Rows now arrive from
/// Bridge carrying the id a queue takes, and the whole class disappears.
struct BridgeMusicProvider: MusicDataProvider {

    private let control: SourceControlling

    /// `SourceAppControl` owns the framing, the size limit and the refusal
    /// vocabulary, so this type adds no second copy of any of them: it turns
    /// Bridge's answers into the seam's words and nothing else.
    init(control: SourceControlling) { self.control = control }

    func librarySongs(cursor: String?, limit: Int = 100) throws -> MusicPage {
        do { return try control.librarySongs(cursor: cursor, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D1.
    func libraryAlbums(cursor: String?, limit: Int = 100) throws -> MusicPage {
        do { return try control.libraryAlbums(cursor: cursor, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D1.
    func libraryArtists(cursor: String?, limit: Int = 100) throws -> MusicPage {
        do { return try control.libraryArtists(cursor: cursor, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D2. Complete or refused — see `MusicList`.
    func albumTracks(albumID: String) throws -> MusicList {
        do { return try control.libraryAlbumTracks(albumID: albumID) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D2. A browse view, distinct from `artistSongs` (D1: an artist PLAYS its
    /// songs, not the tracks of the albums shown here).
    func artistAlbums(artistID: String) throws -> MusicList {
        do { return try control.libraryArtistAlbums(artistID: artistID) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D2.
    func artistSongs(artistID: String) throws -> MusicList {
        do { return try control.libraryArtistSongs(artistID: artistID) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D1.
    func libraryPlaylists(cursor: String?, limit: Int = 100) throws -> MusicPage {
        do { return try control.libraryPlaylists(cursor: cursor, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D4. Stateless: each page re-reads and re-validates the whole
    /// playlist, so a `stale_generation` can come back on any page.
    func playlistTracks(playlistID: String, cursor: String?, limit: Int = 500) throws -> MusicPage {
        do { return try control.libraryPlaylistTracks(playlistID: playlistID, cursor: cursor, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// Ids here are Bridge's own LIBRARY ids, from a page this provider served.
    /// Its one remaining caller (`playSong`, a single specific song) always
    /// picked that exact song, so `startRequired` is hardcoded true here —
    /// see `playReportingSkips`'s doc comment.
    func play(ids: [String]) throws -> BridgeNow.Queue {
        try playReportingSkips(ids: ids, startRequired: true).queue
    }

    /// Addendum U: the real implementation — `play(ids:)` above is now just
    /// this, minus the skip count, kept for callers that don't need it.
    ///
    /// `startRequired` (Bridge-as-built): true only when the person picked a
    /// SPECIFIC row to start from (Enter on a track row / track-k) — never
    /// for a whole-collection `p`/`s`, which starts wherever the list starts
    /// and has no "the person chose this exact song" claim to make. Each
    /// caller (`LibraryScene`, `PlaylistsScene`) computes it at the keypress,
    /// the same way `startAt` itself already is.
    func playReportingSkips(ids: [String], startRequired: Bool) throws -> (queue: BridgeNow.Queue, skippedUnavailable: Int) {
        let skipped: Int
        do { skipped = try control.queue(libraryIDs: ids, startRequired: startRequired) }
        catch let error as SourceAppError { throw Self.translate(error) }
        let queue = try bridgeNow(from: nowPlaying()).queue
        return (queue, skipped)
    }

    func nowPlaying() throws -> SourceStatus {
        do { return try control.status() }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    // MARK: - Part 2 surfaces (D1)
    //
    // **D2: the five members that replace an existing `SourceAppClient` member
    // (rails, tracks, station search, station play, catalogue queue) are NOT
    // translated.** They delegate to the shipped decoders and rethrow their
    // `SourceAppError` unchanged, so when a scene is folded onto this seam
    // every sentence it shows today stays byte-identical. The new reads (Live,
    // Personal, lookup, catalogue search, history) go through `translate`.

    /// Bridge needs no developer key and no web sign-in (D4).
    var feedAvailable: Bool { true }
    var catalogueAvailable: Bool { true }

    /// D2: `BridgeDiscoverFeed`'s rails, errors unchanged.
    func discoverRails(limit: Int) throws -> [DiscoverRail] {
        try control.recommendations(limit: limit)
    }

    /// D2: `BridgeDiscoverFeed`'s tracks, errors unchanged.
    func containerTracks(for item: DiscoverItem) throws -> [DiscoverItem] {
        try control.containerTracks(for: item)
    }

    /// D2: `SourceAppStationSearch`'s bytes and refusal decoding, unchanged.
    func searchStations(term: String, limit: Int) throws -> [Station] {
        try control.searchStations(term: term, limit: limit)
    }

    /// D2: `slice.playStation`, errors unchanged. Bridge plays by id; `url` is
    /// open mode's play handle and is not sent.
    func playStation(id: String, name: String, url: String?) throws {
        _ = url
        try control.playStation(id: id, named: name)
    }

    /// D2: the shipped `slice.queue {"ids"}`, errors unchanged, returning
    /// `skipped_unavailable`.
    func playCatalogue(ids: [String]) throws -> Int {
        try control.queueReportingSkips(catalogIDs: ids)
    }

    /// D5, translated.
    func liveStations() throws -> [Station] {
        do { return try control.liveStations() }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D5, translated.
    func personalStations() throws -> [Station] {
        do { return try control.personalStations() }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D5, translated. nil is Apple not carrying the station, not a failure.
    func station(id: String) throws -> Station? {
        do { return try control.station(id: id) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D5, translated.
    func searchCatalogue(term: String, limit: Int) throws -> [CatalogueRecord] {
        do { return try control.searchCatalogue(term: term, limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D5, translated.
    func recentTracks(limit: Int) throws -> [HistoryItem] {
        do { return try control.recentTracks(limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// D5, translated.
    func heavyRotation(limit: Int) throws -> [HistoryItem] {
        do { return try control.heavyRotation(limit: limit) }
        catch let error as SourceAppError { throw Self.translate(error) }
    }

    /// Bridge's refusals, in the seam's words.
    ///
    /// **Every outcome that drives behaviour is decided on the wire's KIND, and
    /// none on its prose.** `stale_generation` used to be recovered by matching
    /// the sentence "the library changed while you were reading it" inside a
    /// refusal detail, because the transport flattened every refusal to a
    /// string. A list has to tell "start again" apart from "this will never
    /// work", and deciding that by reading a sentence meant a wording change in
    /// the Bridge app would silently turn a restart into a hard error — a person
    /// shown a failure where they should have been shown their library. The
    /// sentence still travels; nothing branches on it.
    static func translate(_ error: SourceAppError) -> MusicProviderError {
        switch error {
        case .notAuthorized:
            return .unavailable("Bridge has not been granted Apple Music access")
        case .warming(let why, let retryAfter):
            // Carried through with its hint intact. Flattening it into
            // `unavailable` would turn "ask again in a second" into "your
            // library cannot be read", which is how a cold open showed 0 songs.
            return .warming(why, retryAfter: retryAfter)
        case .staleGeneration(let detail):
            return .staleGeneration(detail)
        case .refused(let detail):
            return .refused(detail)
        case .malformedReply(let what):
            // The fault travels. "Bridge sent something this build cannot read"
            // is not something a person can act on or report; naming the missing
            // field is.
            return .unavailable(what)
        case .unreadable:
            return .unavailable("Bridge sent a reply this build cannot read")
        case .unsupported(let op):
            // D6: an OLDER Bridge that predates this op. Additive, not a
            // contract mismatch — the op name (the wire string `send` carried
            // through) picks which capability the person is told is missing.
            return .notImplemented(Self.unsupportedSentence(forWireOp: op))
        default:
            return .unavailable(error.message)
        }
    }

    /// One sentence per slice-2 op, keyed by the wire op name. The protocol
    /// extension's defaults in `MusicProvider.swift` use the same five
    /// sentences, so a provider that never reaches Bridge at all (an absent
    /// method) and a provider that reaches an old Bridge (`unknown_op`) read
    /// identically to a person.
    ///
    /// Part 2 (P1) adds one per new read op; the seam's defaults for those
    /// reads call this function rather than repeating the text.
    static func unsupportedSentence(forWireOp op: String) -> String {
        switch op {
        case "slice.libraryAlbums":
            return "This Bridge build can't list your albums — update Bridge"
        case "slice.libraryArtists":
            return "This Bridge build can't list your artists — update Bridge"
        case "slice.libraryAlbumTracks":
            return "This Bridge build can't list an album's tracks — update Bridge"
        case "slice.libraryArtistAlbums":
            return "This Bridge build can't list an artist's albums — update Bridge"
        case "slice.libraryArtistSongs":
            return "This Bridge build can't play an artist — update Bridge"
        case "slice.libraryPlaylists":
            return "This Bridge build can't list your playlists — update Bridge"
        case "slice.libraryPlaylistTracks":
            return "This Bridge build can't list a playlist's tracks — update Bridge"
        case "slice.search":
            return "This Bridge build can't search the catalogue — update Bridge"
        case "slice.liveStations":
            return "This Bridge build can't list live stations — update Bridge"
        case "slice.personalStations":
            return "This Bridge build can't show your personal station — update Bridge"
        case "slice.station":
            return "This Bridge build can't look up a station — update Bridge"
        case "slice.recentTracks":
            return "This Bridge build can't show your listening history — update Bridge"
        case "slice.heavyRotation":
            return "This Bridge build can't show heavy rotation — update Bridge"
        default:
            return "Bridge doesn't serve that yet — update Bridge"
        }
    }
}
