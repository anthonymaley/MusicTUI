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
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, shuffle: Bool, title: String) throws -> HandoffPlayReport
}

/// Refuses every call. The seeded default until a later step wires the real
/// hand-off through the undocumented persistent-ID alias.
struct RefusingHandoff: MusicTUIHandoff {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { pickASpanDACOutput }
    }
    @discardableResult
    func playLibrary(rows: [MusicRow], startAt: Int, shuffle: Bool, title: String) throws -> HandoffPlayReport {
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
