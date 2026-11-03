// How a SpanDAC-sourced row plays on the MusicTUI output (score: data route
// and output, C-HANDOFF and C-ADD).
//
// This step seeds the two protocols and refusing stubs only; nothing calls
// them yet. Owned songs (C-HANDOFF) and not-owned songs plus Discover
// containers (C-ADD) each get a real implementation in a later step, which
// replaces only the stub, not these protocols.
import Foundation

/// Plays a SpanDAC LIBRARY row (song, album, artist's songs, playlist) on the
/// MusicTUI output by resolving each track to the exact track already owned,
/// never by a title search.
protocol MusicTUIHandoff {
    /// Plays the rows, or refuses. The report says what was left out.
    /// `startRequired` is true only when the person picked the start row
    /// (the SpanDAC output's `start_required`): an unavailable pick refuses
    /// by name, while a whole play skips unavailable songs anywhere.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String) throws -> HandoffPlayReport
    /// The same play, for rows whose read also left `skippedVideos` playlist
    /// videos out: they are part of what the play reports, and of what its
    /// confirmation says if Music does not confirm the start.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String, skippedVideos: Int) throws -> HandoffPlayReport
    /// The same play, for rows from which `repeatedSongs` entries were already
    /// removed because the song was in the set before: the report says so, and
    /// so does what its confirmation says if Music does not confirm the start.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String, skippedVideos: Int, repeatedSongs: Int) throws -> HandoffPlayReport
}

extension MusicTUIHandoff {
    /// A hand-off with no confirmation of its own (a stub, a test spy): the
    /// videos join the report it returns.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String, skippedVideos: Int) throws -> HandoffPlayReport {
        var report = try playLibrary(rows: rows, startAt: startAt, startRequired: startRequired, shuffle: shuffle,
                                     title: title)
        report.skippedVideos = skippedVideos
        return report
    }

    /// A hand-off with no confirmation of its own: the repeated songs join the
    /// report it returns.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String, skippedVideos: Int, repeatedSongs: Int) throws -> HandoffPlayReport {
        var report = try playLibrary(rows: rows, startAt: startAt, startRequired: startRequired, shuffle: shuffle,
                                     title: title, skippedVideos: skippedVideos)
        report.repeatedSongs = repeatedSongs
        return report
    }

    /// A whole play: no row was picked.
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, shuffle: Bool, title: String) throws -> HandoffPlayReport {
        try playLibrary(rows: rows, startAt: startAt, startRequired: false, shuffle: shuffle, title: title)
    }
}

/// Refuses every call. The seeded default until a later step wires the real
/// hand-off through the undocumented persistent-ID alias.
struct RefusingHandoff: MusicTUIHandoff {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { pickASpanDACOutput }
    }
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String) throws -> HandoffPlayReport {
        throw Refused()
    }
}

/// Adds a SpanDAC CATALOGUE row (search result, link, history row, Discover
/// track) to the library so it can play on the MusicTUI output, and makes or
/// finds a library playlist for a Discover container's tracks.
protocol SpanDACLibraryAdding {
    var canAdd: Bool { get }
    func add(catalogueIDs: [String]) throws
    func lookup(catalogueIDs: [String]) throws -> [String: String?]
    func ensurePlaylist(name: String, catalogueIDs: [String]) throws -> (created: Bool, id: String, alias: String?)
}

/// Refuses every call and reports no capability to add. The seeded default
/// until a later step wires the real `slice.libraryAdd` / `libraryLookup` /
/// `libraryEnsurePlaylist` ops.
struct RefusingLibraryAdding: SpanDACLibraryAdding {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { pickASpanDACOutput }
    }
    var canAdd: Bool { false }
    func add(catalogueIDs: [String]) throws { throw Refused() }
    func lookup(catalogueIDs: [String]) throws -> [String: String?] { throw Refused() }
    func ensurePlaylist(name: String, catalogueIDs: [String]) throws -> (created: Bool, id: String, alias: String?) {
        throw Refused()
    }
}
