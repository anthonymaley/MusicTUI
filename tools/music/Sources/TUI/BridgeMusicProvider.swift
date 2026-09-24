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

    /// Ids here are Bridge's own LIBRARY ids, from a page this provider served.
    func play(ids: [String]) throws -> BridgeNow.Queue {
        do { try control.queue(libraryIDs: ids) }
        catch let error as SourceAppError { throw Self.translate(error) }
        return try bridgeNow(from: nowPlaying()).queue
    }

    func nowPlaying() throws -> SourceStatus {
        do { return try control.status() }
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
            return .unavailable("Bridge sent a library page this build cannot read")
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
    private static func unsupportedSentence(forWireOp op: String) -> String {
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
        default:
            return "Bridge doesn't serve that yet — update Bridge"
        }
    }
}
