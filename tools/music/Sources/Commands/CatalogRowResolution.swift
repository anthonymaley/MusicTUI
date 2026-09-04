// tools/music/Sources/Commands/CatalogRowResolution.swift
import Foundation

/// One row the library reports, reduced to what identifies it.
struct LibraryRowIdentity: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
}

/// The result of trying to find the row a catalog add just created.
enum CatalogRowResolution: Equatable {
    /// Exactly one new row is plausible. Its identifier is carried forward and
    /// no further name lookup happens.
    case resolved(persistentID: String)
    /// The budget ran out and no new plausible row ever appeared.
    case notYetVisible(attempts: Int)
    /// More than one new row is plausible, so we do not know which one was
    /// asked for. Fail closed: playing a coin flip is worse than not playing.
    case ambiguous(count: Int)
}

/// Find the library row a catalog add just created.
///
/// Identity first, attributes second (Anthony, 2026-09-03: "identify the newly
/// added catalog song using every stable attribute available, not merely its
/// name, and fail closed if multiple library rows remain plausible").
///
/// The primary signal is a set difference over `persistent ID`: whatever is in
/// the library now and was not there before the add is a candidate. That is
/// stronger than any attribute match, because it does not care what the row is
/// called. Attributes then narrow the candidates, using normalised title,
/// artist and album rather than the title alone, which is what makes a
/// same-titled track by a different artist fall out.
///
/// Ambiguity is decided over CANDIDATES, not over the whole library, so the
/// user's own pre-existing copy of the same song is not a source of ambiguity:
/// it was there before, so it is not new.
///
/// Polling exists because the row is not there immediately. Measured
/// 2026-09-03: an added track was not resolvable at t+0, t+1 or t+2 and
/// appeared at t+3, one second inside the fixed four-second sleep this
/// replaces. A fixed sleep tuned to one machine on one connection is exactly
/// the wrong shape; a bounded retry that reports honestly when it gives up is
/// the right one.
func resolveAddedCatalogRow(title: String,
                            artist: String,
                            album: String,
                            idsBefore: Set<String>,
                            attempts: Int = 20,
                            readRows: () -> [LibraryRowIdentity],
                            wait: (Double) -> Void,
                            interval: Double = 0.5) -> CatalogRowResolution {
    let wantTitle = normalizeAlbumTitle(title)
    let wantArtist = normalizeCredit(artist)
    let wantAlbum = normalizeAlbumTitle(album)

    for attempt in 1...max(1, attempts) {
        let candidates = readRows().filter { !idsBefore.contains($0.persistentID) }

        // Narrow by every attribute we have. Album is only used when the
        // catalog gave us one AND the row carries one, so a row with a blank
        // album is not excluded by a comparison it cannot win.
        let plausible = candidates.filter { row in
            guard normalizeAlbumTitle(row.name) == wantTitle else { return false }
            guard wantArtist.isEmpty || normalizeCredit(row.artist) == wantArtist else { return false }
            guard wantAlbum.isEmpty || row.album.isEmpty
                    || normalizeAlbumTitle(row.album) == wantAlbum else { return false }
            return true
        }

        if plausible.count == 1, let only = plausible.first {
            return .resolved(persistentID: only.persistentID)
        }
        if plausible.count > 1 {
            // Do not keep polling: more candidates can only make this worse,
            // and waiting cannot disambiguate what is already ambiguous.
            return .ambiguous(count: plausible.count)
        }
        if attempt < max(1, attempts) { wait(interval) }
    }
    return .notYetVisible(attempts: max(1, attempts))
}

/// User facing text for a resolution that did not resolve.
func catalogRowResolutionMessage(_ resolution: CatalogRowResolution, title: String) -> String? {
    switch resolution {
    case .resolved:
        return nil
    case .notYetVisible(let attempts):
        return "Added '\(title)' to your library, but it had not appeared there after \(attempts) checks, "
            + "so nothing was played. It should be there shortly; try playing it again."
    case .ambiguous(let count):
        return "Added '\(title)' to your library, but \(count) new tracks match it, "
            + "so it is not clear which one you meant and nothing was played."
    }
}
